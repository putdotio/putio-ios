import Foundation
import Testing

@testable import PutioHarnessKit

private enum TestStartupError: Error {
  case failed
}

private final class StopCounter: @unchecked Sendable {
  private let lock = NSLock()
  private var count = 0

  func increment() {
    lock.lock()
    count += 1
    lock.unlock()
  }

  func value() -> Int {
    lock.lock()
    defer { lock.unlock() }
    return count
  }
}

@Test func harnessMediaServerStopsOnceWhenStartupFails() throws {
  let directory = FileManager.default.temporaryDirectory.appending(
    path: "putio-harness-media-\(UUID().uuidString)"
  )
  let stopCounter = StopCounter()
  let server = try HarnessMediaServer(
    mediaDirectory: directory,
    onStop: { stopCounter.increment() },
    startListener: { listener, queue in
      listener.start(queue: queue)
      throw TestStartupError.failed
    }
  )

  #expect(throws: TestStartupError.self) {
    try server.start()
  }
  server.stop()
  #expect(stopCounter.value() == 1)
}

@Test func harnessMediaServerServesOnlyAllowlistedMediaAndByteRanges() async throws {
  let directory = FileManager.default.temporaryDirectory.appending(
    path: "putio-harness-media-\(UUID().uuidString)"
  )
  try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: directory) }
  let playlist = Data("#EXTM3U\nruntime-proof-000.ts\n".utf8)
  let segment = Data([0, 1, 2, 3, 4, 5])
  try playlist.write(to: directory.appending(path: "runtime-proof.m3u8"))
  try segment.write(to: directory.appending(path: "runtime-proof-000.ts"))

  let stopCounter = StopCounter()
  let server = try HarnessMediaServer(
    mediaDirectory: directory,
    onStop: { stopCounter.increment() }
  )
  let baseURL = try server.start()
  defer {
    server.stop()
    server.stop()
    #expect(stopCounter.value() == 1)
  }

  let (playlistData, playlistResponse) = try await URLSession.shared.data(
    from: baseURL.appending(path: "runtime-proof.m3u8")
  )
  #expect(playlistData == playlist)
  #expect((playlistResponse as? HTTPURLResponse)?.statusCode == 200)
  #expect(
    (playlistResponse as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Type")
      == "application/vnd.apple.mpegurl"
  )

  var rangeRequest = URLRequest(
    url: baseURL.appending(path: "runtime-proof-000.ts")
  )
  rangeRequest.setValue("bytes=2-4", forHTTPHeaderField: "Range")
  let (rangeData, rangeResponse) = try await URLSession.shared.data(for: rangeRequest)
  #expect(rangeData == Data([2, 3, 4]))
  #expect((rangeResponse as? HTTPURLResponse)?.statusCode == 206)
  #expect(
    (rangeResponse as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Range")
      == "bytes 2-4/6"
  )

  let image = Data([0x89, 0x50, 0x4E, 0x47])
  try image.write(to: directory.appending(path: "runtime-proof-image.png"))
  let document = Data("%PDF-1.4".utf8)
  try document.write(to: directory.appending(path: "runtime-proof-document.pdf"))
  let subtitles = Data("1\n00:00:02,000 --> 00:00:05,000\n".utf8)
  try subtitles.write(to: directory.appending(path: "runtime-proof-subtitles.srt"))
  try subtitles.write(to: directory.appending(path: "runtime-proof-long.srt"))
  for (name, contentType, expected) in [
    ("runtime-proof-image.png", "image/png", image),
    ("runtime-proof-document.pdf", "application/pdf", document),
    ("runtime-proof-subtitles.srt", "application/x-subrip", subtitles),
    ("runtime-proof-long.srt", "application/x-subrip", subtitles),
  ] {
    let (data, response) = try await URLSession.shared.data(from: baseURL.appending(path: name))
    #expect(data == expected)
    #expect(
      (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Type") == contentType)
  }

  try FileManager.default.createDirectory(
    at: directory.appending(path: "multi-audio"), withIntermediateDirectories: true)
  let master = Data("#EXTM3U\nmulti-video.m3u8\n".utf8)
  try master.write(to: directory.appending(path: "multi-audio/runtime-proof-multi.m3u8"))
  let (masterData, masterResponse) = try await URLSession.shared.data(
    from: baseURL.appending(path: "multi-audio/runtime-proof-multi.m3u8"))
  #expect(masterData == master)
  #expect(
    (masterResponse as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Type")
      == "application/vnd.apple.mpegurl")
  #expect(HarnessMediaServer.multiAudioResource(path: "/multi-audio/../queue.json") == nil)
  #expect(HarnessMediaServer.multiAudioResource(path: "/multi-audio/other.ts") == nil)
  #expect(
    HarnessMediaServer.multiAudioResource(path: "/multi-audio/multi-English-000.ts")?.contentType
      == "video/mp2t")
  #expect(
    HarnessMediaServer.multiAudioResource(path: "/multi-audio/multi-subtitle-Turkish.vtt")?
      .contentType == "text/vtt")
  #expect(HarnessMediaServer.multiAudioResource(path: "/multi-audio/other.vtt") == nil)

  let (_, missingResponse) = try await URLSession.shared.data(
    from: baseURL.appending(path: "../not-allowlisted")
  )
  #expect((missingResponse as? HTTPURLResponse)?.statusCode == 404)

  let (_, forbiddenResponse) = try await URLSession.shared.data(
    from: baseURL.appending(path: "forbidden/runtime-proof.m3u8")
  )
  #expect((forbiddenResponse as? HTTPURLResponse)?.statusCode == 403)
}

@Test func harnessMediaServerFailsFastWhenTheListenerIsCancelledBeforeReady() throws {
  let directory = FileManager.default.temporaryDirectory.appending(
    path: "putio-harness-media-\(UUID().uuidString)"
  )
  let started = Date()
  let server = try HarnessMediaServer(
    mediaDirectory: directory,
    startListener: { listener, _ in
      // A real listener cancelled before start does not reliably deliver a state update.
      listener.stateUpdateHandler?(.cancelled)
    }
  )

  #expect(throws: HarnessMediaServer.ServerError.cancelledBeforeReady) {
    try server.start(timeout: 5)
  }
  #expect(Date().timeIntervalSince(started) < 4)
}

@Test func harnessMediaServerFailsFastWhenTheListenerIsWaiting() throws {
  let directory = FileManager.default.temporaryDirectory.appending(
    path: "putio-harness-media-\(UUID().uuidString)"
  )
  let started = Date()
  let server = try HarnessMediaServer(
    mediaDirectory: directory,
    startListener: { listener, _ in
      // Drive the state handler directly: a listener bound to a fixed
      // loopback port cannot be made to wait deterministically.
      listener.stateUpdateHandler?(.waiting(.posix(.EADDRINUSE)))
    }
  )

  #expect(throws: HarnessMediaServer.ServerError.self) {
    try server.start(timeout: 5)
  }
  #expect(Date().timeIntervalSince(started) < 4)
}

private final class Completion: @unchecked Sendable {
  private let lock = NSLock()
  private var data: Data?

  func finish(_ data: Data?) {
    lock.lock()
    self.data = data
    lock.unlock()
  }

  func value() -> Data? {
    lock.lock()
    defer { lock.unlock() }
    return data
  }
}

@Test func harnessMediaServerHoldsTheChosenSegmentUntilItsTokenIsReleased() async throws {
  let directory = FileManager.default.temporaryDirectory.appending(
    path: "putio-harness-media-\(UUID().uuidString)"
  )
  let held = directory.appending(path: "held")
  try FileManager.default.createDirectory(at: held, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: directory) }
  let segment = Data((0..<1_000).map { UInt8($0 % 256) })
  for index in 0..<10 {
    try segment.write(to: held.appending(path: "held-00\(index).ts"))
  }
  let server = try HarnessMediaServer(
    mediaDirectory: directory, holdTrickleInterval: .milliseconds(20))
  let baseURL = try server.start()
  defer { server.stop() }

  let (served, _) = try await URLSession.shared.data(
    from: baseURL.appending(path: "held/token-1/middle/held-004.ts"))
  #expect(served == segment)

  let completion = Completion()
  let request = Task {
    let (data, _) = try await URLSession.shared.data(
      from: baseURL.appending(path: "held/token-1/middle/held-005.ts"))
    completion.finish(data)
  }
  try await Task.sleep(for: .milliseconds(600))
  #expect(completion.value() == nil, "the held segment finished before its release")

  let (_, other) = try await URLSession.shared.data(
    from: baseURL.appending(path: "release/token-2"))
  #expect((other as? HTTPURLResponse)?.statusCode == 204)
  try await Task.sleep(for: .milliseconds(300))
  #expect(completion.value() == nil, "another token released the held segment")

  let (_, released) = try await URLSession.shared.data(
    from: baseURL.appending(path: "release/token-1"))
  #expect((released as? HTTPURLResponse)?.statusCode == 204)
  try await request.value
  #expect(completion.value() == segment)

  #expect(HarnessMediaServer.heldResource(path: "/held/t/later/held-000.ts") == nil)
  #expect(HarnessMediaServer.heldResource(path: "/held/t/start/../queue.json") == nil)
  #expect(HarnessMediaServer.heldResource(path: "/held/t/start/held-000.ts")?.holdToken == "t")
  #expect(HarnessMediaServer.heldResource(path: "/held/t/start/held-005.ts")?.holdToken == nil)
  #expect(HarnessMediaServer.heldResource(path: "/held/t/start/held-010.ts") == nil)
}
