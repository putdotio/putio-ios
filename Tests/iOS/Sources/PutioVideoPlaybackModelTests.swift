import Foundation
import PutioCore
import XCTest

@testable import Putio

@MainActor
private final class PlaybackResolverStub {
  private(set) var requestedIDs: [PutioFileID] = []
  var results: [Result<PutioPlaybackResolution, PutioRuntimeError>]

  init(_ results: [Result<PutioPlaybackResolution, PutioRuntimeError>]) {
    self.results = results
  }

  func resolve(_ fileID: PutioFileID) async throws -> PutioPlaybackResolution {
    requestedIDs.append(fileID)
    guard !results.isEmpty else {
      throw PutioRuntimeError.unknown
    }
    return try results.removeFirst().get()
  }
}

@MainActor
private final class CancellationPlaybackResolver {
  private(set) var attempts = 0
  let source: PutioPlaybackSource

  init(source: PutioPlaybackSource) {
    self.source = source
  }

  func resolve(_: PutioFileID) async throws -> PutioPlaybackResolution {
    attempts += 1
    if attempts == 1 {
      try await Task.sleep(for: .seconds(60))
    }
    return .ready(source)
  }
}

@MainActor
private final class VideoConversionStub {
  private(set) var startRequests: [PutioFileID] = []
  private(set) var statusRequests: [PutioFileID] = []
  private(set) var sleepDurations: [Duration] = []
  var startResults: [Result<Void, PutioRuntimeError>]
  var statusResults: [Result<PutioVideoConversionStatus, PutioRuntimeError>]

  init(
    startResults: [Result<Void, PutioRuntimeError>] = [.success(())],
    statusResults: [Result<PutioVideoConversionStatus, PutioRuntimeError>]
  ) {
    self.startResults = startResults
    self.statusResults = statusResults
  }

  func start(_ fileID: PutioFileID) async throws {
    startRequests.append(fileID)
    guard !startResults.isEmpty else { throw PutioRuntimeError.unknown }
    try startResults.removeFirst().get()
  }

  func status(_ fileID: PutioFileID) async throws -> PutioVideoConversionStatus {
    statusRequests.append(fileID)
    guard !statusResults.isEmpty else { throw PutioRuntimeError.unknown }
    return try statusResults.removeFirst().get()
  }

  func sleep(for duration: Duration) async throws {
    sleepDurations.append(duration)
    await Task.yield()
  }
}

@MainActor
private final class SuspendedConversionStatus {
  private(set) var startRequests: [PutioFileID] = []
  private(set) var requests = 0

  func start(_ fileID: PutioFileID) async throws {
    startRequests.append(fileID)
  }

  func load(_: PutioFileID) async throws -> PutioVideoConversionStatus {
    requests += 1
    if requests == 1 {
      try await Task.sleep(for: .seconds(60))
    }
    return .completed
  }
}

@MainActor
private final class SuspendedConversionStart {
  private(set) var requests = 0

  func start(_: PutioFileID) async throws {
    requests += 1
    try await Task.sleep(for: .seconds(60))
  }
}

@MainActor
final class PutioVideoPlaybackModelTests: XCTestCase {
  private let fileID = PutioFileID(rawValue: 411)

  func testReadySourceResolvesWithoutConversion() async {
    let source = playbackSource()
    let readyResolver = PlaybackResolverStub([.success(.ready(source))])
    let readyModel = PutioVideoPlaybackModel(fileID: fileID) {
      try await readyResolver.resolve($0)
    }

    await readyModel.loadIfNeeded()

    XCTAssertEqual(readyModel.state, .ready(source))
    XCTAssertEqual(readyResolver.requestedIDs, [fileID])

  }

  func testConversionLifecycleResolvesTheEventualPlaybackSource() async {
    let source = playbackSource()
    let resolver = PlaybackResolverStub([
      .success(.conversionRequired),
      .success(.conversionRequired),
      .success(.ready(source)),
    ])
    let conversion = VideoConversionStub(statusResults: [
      .success(.queued),
      .success(.converting(progress: 0.35)),
      .success(.completed),
    ])
    let model = PutioVideoPlaybackModel(
      fileID: fileID,
      conversionPollInterval: .milliseconds(10),
      startConversion: { try await conversion.start($0) },
      loadConversionStatus: { try await conversion.status($0) },
      sleep: { try await conversion.sleep(for: $0) },
      resolve: { try await resolver.resolve($0) }
    )

    await model.loadIfNeeded()

    XCTAssertEqual(model.state, .ready(source))
    XCTAssertEqual(conversion.startRequests, [fileID])
    XCTAssertEqual(conversion.statusRequests, [fileID, fileID, fileID])
    XCTAssertEqual(resolver.requestedIDs, [fileID, fileID, fileID])
    XCTAssertEqual(conversion.sleepDurations.count, 3)
  }

  func testStartFailureRetriesTheConversionRequest() async {
    let source = playbackSource()
    let resolver = PlaybackResolverStub([
      .success(.conversionRequired),
      .success(.ready(source)),
    ])
    let conversion = VideoConversionStub(
      startResults: [.failure(.transient), .success(())],
      statusResults: [.success(.completed)]
    )
    let model = conversionModel(resolver: resolver, conversion: conversion)

    await model.loadIfNeeded()
    XCTAssertEqual(conversionFailure(from: model)?.kind, .transient)

    await model.retry()

    XCTAssertEqual(model.state, .ready(source))
    XCTAssertEqual(conversion.startRequests, [fileID, fileID])
  }

  func testQueuedStateWaitsForConversionStartAcceptance() async {
    let resolver = PlaybackResolverStub([.success(.conversionRequired)])
    let suspendedStart = SuspendedConversionStart()
    let model = PutioVideoPlaybackModel(
      fileID: fileID,
      startConversion: { try await suspendedStart.start($0) },
      loadConversionStatus: { _ in .queued },
      resolve: { try await resolver.resolve($0) }
    )

    let loadTask = Task { await model.loadIfNeeded() }
    while suspendedStart.requests == 0 {
      await Task.yield()
    }

    XCTAssertEqual(model.state, .conversionRequired)
    loadTask.cancel()
    await loadTask.value
    XCTAssertEqual(model.state, .conversionRequired)
  }

  func testPollFailureRetriesStatusWithoutStartingAgain() async {
    let source = playbackSource()
    let resolver = PlaybackResolverStub([
      .success(.conversionRequired),
      .success(.ready(source)),
    ])
    let conversion = VideoConversionStub(statusResults: [
      .failure(.transient),
      .success(.completed),
    ])
    let model = conversionModel(resolver: resolver, conversion: conversion)

    await model.loadIfNeeded()
    XCTAssertEqual(conversionFailure(from: model)?.kind, .transient)

    await model.retry()

    XCTAssertEqual(model.state, .ready(source))
    XCTAssertEqual(conversion.startRequests, [fileID])
    XCTAssertEqual(conversion.statusRequests, [fileID, fileID])
  }

  func testTerminalConversionFailureRestartsConversionOnRetry() async {
    let source = playbackSource()
    let resolver = PlaybackResolverStub([
      .success(.conversionRequired),
      .success(.ready(source)),
    ])
    let conversion = VideoConversionStub(
      startResults: [.success(()), .success(())],
      statusResults: [.success(.failed), .success(.completed)]
    )
    let model = conversionModel(resolver: resolver, conversion: conversion)

    await model.loadIfNeeded()
    XCTAssertEqual(conversionFailure(from: model), .conversion)

    await model.retry()

    XCTAssertEqual(model.state, .ready(source))
    XCTAssertEqual(conversion.startRequests, [fileID, fileID])
  }

  func testConversionPollingCancelsWithoutPresentingAnError() async {
    let source = playbackSource()
    let resolver = PlaybackResolverStub([
      .success(.conversionRequired),
      .success(.ready(source)),
    ])
    let suspendedStatus = SuspendedConversionStatus()
    let model = PutioVideoPlaybackModel(
      fileID: fileID,
      startConversion: { try await suspendedStatus.start($0) },
      loadConversionStatus: { try await suspendedStatus.load($0) },
      resolve: { try await resolver.resolve($0) }
    )

    let loadTask = Task { await model.loadIfNeeded() }
    while suspendedStatus.requests == 0 {
      await Task.yield()
    }
    loadTask.cancel()
    await loadTask.value

    XCTAssertEqual(model.state, .conversionQueued)

    await model.loadIfNeeded()

    XCTAssertEqual(model.state, .ready(source))
    XCTAssertEqual(suspendedStatus.startRequests, [fileID])
    XCTAssertEqual(suspendedStatus.requests, 2)
  }

  func testResolutionFailureIsTypedAndRetryCanRecover() async {
    let source = playbackSource()
    let resolver = PlaybackResolverStub([
      .failure(.transient),
      .success(.ready(source)),
    ])
    let model = PutioVideoPlaybackModel(fileID: fileID) {
      try await resolver.resolve($0)
    }

    await model.loadIfNeeded()

    guard case .failed(let failure) = model.state else {
      return XCTFail("expected typed failure")
    }
    XCTAssertEqual(failure.kind, .transient)
    XCTAssertEqual(failure.title, "Could not open video")

    await model.retry()

    XCTAssertEqual(model.state, .ready(source))
    XCTAssertEqual(resolver.requestedIDs, [fileID, fileID])
  }

  func testEveryResolutionFailureMapsToStableRecoveryCopy() throws {
    let cases: [(Error, PutioVideoPlaybackFailure)] = [
      (
        PutioRuntimeError.notFound,
        PutioVideoPlaybackFailure(
          kind: .notFound,
          title: "Video not found",
          message: "It may have been moved or deleted."
        )
      ),
      (
        PutioRuntimeError.rateLimited,
        PutioVideoPlaybackFailure(
          kind: .rateLimited,
          title: "Could not open video",
          message: "put.io is receiving too many requests. Try again shortly."
        )
      ),
      (
        PutioRuntimeError.transient,
        PutioVideoPlaybackFailure(
          kind: .transient,
          title: "Could not open video",
          message: "Check your connection and try again."
        )
      ),
      (
        PutioRuntimeError.invalidResponse,
        PutioVideoPlaybackFailure(
          kind: .invalidResponse,
          title: "Could not open video",
          message: "put.io returned an invalid response. Try again."
        )
      ),
      (
        PutioRuntimeError.unknown,
        PutioVideoPlaybackFailure(
          kind: .unknown,
          title: "Could not open video",
          message: "put.io could not prepare this video. Try again."
        )
      ),
      (
        NSError(domain: "PutioVideoPlaybackModelTests", code: 1),
        PutioVideoPlaybackFailure(
          kind: .unknown,
          title: "Could not open video",
          message: "put.io could not prepare this video. Try again."
        )
      ),
    ]

    for (error, expected) in cases {
      XCTAssertEqual(try XCTUnwrap(PutioVideoPlaybackFailure.resolving(error)), expected)
    }
  }

  func testCancellationCanRetryWithoutBecomingAnError() async {
    let source = playbackSource()
    let resolver = CancellationPlaybackResolver(source: source)
    let model = PutioVideoPlaybackModel(fileID: fileID) {
      try await resolver.resolve($0)
    }

    let loadTask = Task { await model.loadIfNeeded() }
    while resolver.attempts == 0 {
      await Task.yield()
    }
    loadTask.cancel()
    await loadTask.value

    XCTAssertEqual(model.state, .loading)

    await model.loadIfNeeded()

    XCTAssertEqual(model.state, .ready(source))
    XCTAssertEqual(resolver.attempts, 2)
  }

  func testActiveCancellationErrorBecomesARecoverableFailure() async {
    let model = PutioVideoPlaybackModel(fileID: fileID) { _ in
      throw CancellationError()
    }

    await model.loadIfNeeded()

    guard case .failed(let failure) = model.state else {
      return XCTFail("expected recoverable failure, got \(model.state)")
    }
    XCTAssertEqual(failure.kind, .unknown)
  }

  func testPlayerFailureBecomesRecoverableAndIgnoresNonReadyStates() async {
    let source = playbackSource()
    let resolver = PlaybackResolverStub([.success(.ready(source))])
    let model = PutioVideoPlaybackModel(fileID: fileID) {
      try await resolver.resolve($0)
    }

    model.playerFailed()
    XCTAssertEqual(model.state, .loading)

    await model.loadIfNeeded()
    model.playerFailed()

    XCTAssertEqual(model.state, .failed(.playback))
  }

  func testSessionFailuresRemainOwnedByTheSessionRoot() {
    XCTAssertNil(PutioVideoPlaybackFailure.resolving(PutioRuntimeError.authenticationRequired))
    XCTAssertNil(PutioVideoPlaybackFailure.resolving(PutioRuntimeError.sessionExpired))
  }

  private func playbackSource() -> PutioPlaybackSource {
    PutioPlaybackSource(
      url: URL(string: "https://media.example.test/video.m3u8?oauth_token=secret")!,
      startFromSeconds: 90
    )
  }

  private func conversionModel(
    resolver: PlaybackResolverStub,
    conversion: VideoConversionStub
  ) -> PutioVideoPlaybackModel {
    PutioVideoPlaybackModel(
      fileID: fileID,
      conversionPollInterval: .milliseconds(10),
      startConversion: { try await conversion.start($0) },
      loadConversionStatus: { try await conversion.status($0) },
      sleep: { try await conversion.sleep(for: $0) },
      resolve: { try await resolver.resolve($0) }
    )
  }

  private func conversionFailure(
    from model: PutioVideoPlaybackModel
  ) -> PutioVideoPlaybackFailure? {
    guard case .failed(let failure) = model.state else {
      XCTFail("expected conversion failure, got \(model.state)")
      return nil
    }
    return failure
  }
}
