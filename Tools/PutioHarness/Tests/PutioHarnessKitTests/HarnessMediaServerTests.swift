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

  let (_, missingResponse) = try await URLSession.shared.data(
    from: baseURL.appending(path: "../not-allowlisted")
  )
  #expect((missingResponse as? HTTPURLResponse)?.statusCode == 404)
}
