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
final class PutioVideoPlaybackModelTests: XCTestCase {
  private let fileID = PutioFileID(rawValue: 411)

  func testReadySourceAndConversionRequiredAreDistinctStates() async {
    let source = playbackSource()
    let readyResolver = PlaybackResolverStub([.success(.ready(source))])
    let readyModel = PutioVideoPlaybackModel(fileID: fileID) {
      try await readyResolver.resolve($0)
    }

    await readyModel.loadIfNeeded()

    XCTAssertEqual(readyModel.state, .ready(source))
    XCTAssertEqual(readyResolver.requestedIDs, [fileID])

    let conversionResolver = PlaybackResolverStub([.success(.conversionRequired)])
    let conversionModel = PutioVideoPlaybackModel(fileID: fileID) {
      try await conversionResolver.resolve($0)
    }

    await conversionModel.loadIfNeeded()

    XCTAssertEqual(conversionModel.state, .conversionRequired)
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
}
