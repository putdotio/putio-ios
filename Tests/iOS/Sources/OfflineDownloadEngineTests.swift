import AVFoundation
import Foundation
import PutioCore
import Testing

@testable import Putio

@MainActor
struct OfflineDownloadEngineTests {
  private let fileID = PutioFileID(rawValue: 7)
  private let url = URL(string: "https://download.test/video.m3u8")!

  private final class Gate {
    private(set) var entered = false
    private var isOpen = false
    private var continuation: CheckedContinuation<Void, Never>?

    func wait() async {
      entered = true
      if isOpen { return }
      await withCheckedContinuation { continuation = $0 }
    }

    func waitUntilEntered() async throws {
      let deadline = ContinuousClock.now + .seconds(5)
      while !entered {
        guard ContinuousClock.now < deadline else { throw GateTimeout() }
        try await Task.sleep(for: .milliseconds(1))
      }
    }

    func open() {
      isOpen = true
      continuation?.resume()
      continuation = nil
    }

    private struct GateTimeout: Error {}
  }

  private final class Tasks {
    private let session: URLSession
    private(set) var configurations: [AVAssetDownloadConfiguration] = []

    init() {
      let configuration = URLSessionConfiguration.ephemeral
      configuration.protocolClasses = [DownloadEngineStubProtocol.self]
      session = URLSession(configuration: configuration)
    }

    func make(_ configuration: AVAssetDownloadConfiguration) -> URLSessionTask {
      configurations.append(configuration)
      return session.dataTask(with: URL(string: "https://download.test/task")!)
    }

    func close() { session.invalidateAndCancel() }
  }

  @Test(arguments: [true, false])
  func supersededStartCannotDisplaceItsReplacement(replacementFinishesFirst: Bool) async throws {
    let gate = Gate()
    let replacementGate = Gate()
    let tasks = Tasks()
    let oldConfiguration = AVAssetDownloadConfiguration(asset: AVURLAsset(url: url), title: "old")
    let replacement = AVAssetDownloadConfiguration(asset: AVURLAsset(url: url), title: "new")
    let engine = PutioSystemOfflineDownloadEngine(
      accountID: 1,
      prepareConfiguration: { _, title, _ in
        if title == "old" {
          await gate.wait()
          return oldConfiguration
        }
        await replacementGate.wait()
        return replacement
      }, makeTask: tasks.make)
    defer {
      gate.open()
      replacementGate.open()
      engine.stop()
      tasks.close()
    }
    let old = Task {
      try await engine.start(fileID: fileID, url: url, title: "old", audioLanguages: ["en"])
    }
    defer { old.cancel() }
    try await gate.waitUntilEntered()
    let newer = Task {
      try await engine.start(fileID: fileID, url: url, title: "new", audioLanguages: [])
    }
    defer { newer.cancel() }
    try await replacementGate.waitUntilEntered()
    if replacementFinishesFirst {
      replacementGate.open()
      try await newer.value
      gate.open()
      await expectCancellation(of: old)
    } else {
      gate.open()
      await expectCancellation(of: old)
      replacementGate.open()
      try await newer.value
    }
    #expect(tasks.configurations.count == 1)
    #expect(tasks.configurations.first === replacement)
  }

  enum Invalidation: CaseIterable { case cancel, stop, taskCancellation }

  @Test(arguments: Invalidation.allCases)
  func invalidatedPreparationCannotStartATransfer(_ invalidation: Invalidation) async throws {
    let gate = Gate()
    let tasks = Tasks()
    let configuration = AVAssetDownloadConfiguration(asset: AVURLAsset(url: url), title: "video")
    let engine = PutioSystemOfflineDownloadEngine(
      accountID: 1,
      prepareConfiguration: { _, _, _ in
        await gate.wait()
        return configuration
      },
      makeTask: tasks.make)
    defer {
      gate.open()
      engine.stop()
      tasks.close()
    }
    let start = Task {
      try await engine.start(fileID: fileID, url: url, title: "video", audioLanguages: ["en"])
    }
    defer { start.cancel() }
    try await gate.waitUntilEntered()
    switch invalidation {
    case .cancel: engine.cancel(fileID: fileID)
    case .stop: engine.stop()
    case .taskCancellation: start.cancel()
    }
    gate.open()
    await expectCancellation(of: start)
    #expect(tasks.configurations.isEmpty)
  }

  @Test func cancellingAnotherFileDoesNotInvalidatePreparation() async throws {
    let gate = Gate()
    let tasks = Tasks()
    let configuration = AVAssetDownloadConfiguration(asset: AVURLAsset(url: url), title: "video")
    let engine = PutioSystemOfflineDownloadEngine(
      accountID: 1,
      prepareConfiguration: { _, _, _ in
        await gate.wait()
        return configuration
      },
      makeTask: tasks.make)
    defer {
      gate.open()
      engine.stop()
      tasks.close()
    }
    let start = Task {
      try await engine.start(fileID: fileID, url: url, title: "video", audioLanguages: ["en"])
    }
    defer { start.cancel() }
    try await gate.waitUntilEntered()
    engine.cancel(fileID: PutioFileID(rawValue: 8))
    gate.open()
    try await start.value
    #expect(tasks.configurations.count == 1)
  }

  @Test func progressReachesTheMainActorOncePerNewPercent() {
    let gate = PutioOfflineProgressGate()
    let ticks = [0, 0.004, 0.005, 0.015, 0.0152, 0.425, 0.4195, 0.4251, 0.435, 0.9995, 1, 1]
    #expect(ticks.filter(gate.admits) == [0, 0.015, 0.425, 0.435, 0.9995, 1])
  }

  private final class Hops: @unchecked Sendable {
    var pending: [@MainActor @Sendable () -> Void] = []
  }

  @Test func delegateProgressHopsOncePerNewPercentAndNeverGoesBack() {
    let hops = Hops()
    let relay = PutioOfflineDownloadRelay(dispatch: { hops.pending.append($0) })
    let engine = PutioSystemOfflineDownloadEngine(accountID: 7)
    relay.engine = engine
    var delivered: [Double] = []
    engine.onProgress = { _, progress in delivered.append(progress) }
    let session = URLSession(configuration: .ephemeral)
    defer { session.invalidateAndCancel() }
    let task = session.dataTask(with: URL(string: "https://download.test/task")!)
    task.taskDescription = "7:5"
    relay.track(task, with: PutioOfflineProgressGate())

    for tick in [0.421, 0.425, 0.429, 0.43, 0.431] { relay.progressed(task, tick) }
    #expect(hops.pending.count == 2, "only 42% and 43% hop to the main actor")

    // The later hop runs first; the earlier, lower one must not undo it.
    for hop in hops.pending.reversed() { hop() }
    #expect(delivered == [0.43])

    relay.track(task, with: nil)
    relay.progressed(task, 0.9)
    #expect(hops.pending.count == 2, "an untracked task never hops")
  }

  private func expectCancellation(of task: Task<Void, Error>) async {
    do {
      try await task.value
      Issue.record("An invalidated start created a transfer")
    } catch {
      #expect(error is CancellationError)
    }
  }
}

private final class DownloadEngineStubProtocol: URLProtocol {
  override class func canInit(with request: URLRequest) -> Bool { true }
  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
  override func startLoading() { client?.urlProtocolDidFinishLoading(self) }
  override func stopLoading() {}
}
