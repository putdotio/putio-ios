import Foundation
import XCTest

@testable import PutioDomain

@MainActor
final class PutioVideoFallbackTests: XCTestCase {
  private let fileID = PutioFileID(rawValue: 441)
  private let original = PutioPlaybackSource(
    url: URL(string: "https://api.example.test/v2/files/441/stream?oauth_token=secret")!,
    startFromSeconds: 120, original: PutioOriginalPlayback(player: .engine))
  private let converted = PutioPlaybackSource(
    url: URL(string: "https://api.example.test/v2/files/441/mp4/stream?oauth_token=secret")!,
    startFromSeconds: 120)

  func testAnOriginalThatFailsBeforeItsFirstFramePlaysConvertedWhereItStood() async {
    var convertedRequests: [PutioFileID] = []
    let converted = converted
    let model = model(
      converted: {
        convertedRequests.append($0)
        return .ready(converted)
      })

    await model.loadIfNeeded()
    XCTAssertFalse(model.playsConvertedFallback)
    XCTAssertTrue(model.fallsBack(after: .playback, beforeFirstFrame: true))
    await model.playerFailed(.playback, heldSeconds: 120, beforeFirstFrame: true)
    XCTAssertTrue(model.playsConvertedFallback)

    XCTAssertEqual(convertedRequests, [fileID])
    XCTAssertEqual(
      model.state,
      .ready(
        PutioPlaybackSource(url: converted.url, startFromSeconds: 120, resumesAfterFailure: true)))
    XCTAssertEqual(model.playerAttempt, 2)
    XCTAssertFalse(
      model.fallsBack(after: .playback, beforeFirstFrame: true), "the converted stream fell back")
  }

  func testTheConvertedStreamFailingShowsTheErrorInsteadOfFallingBackAgain() async {
    var convertedRequests = 0
    let converted = converted
    let model = model(
      converted: { _ in
        convertedRequests += 1
        return .ready(converted)
      })

    await model.loadIfNeeded()
    await model.playerFailed(.playback, heldSeconds: nil, beforeFirstFrame: true)
    await model.playerFailed(.playback, heldSeconds: nil, beforeFirstFrame: true)

    XCTAssertEqual(convertedRequests, 1)
    XCTAssertEqual(model.state, .failed(.playback))
  }

  func testAnOriginalStillRefusedAfterItsSilentRefreshPlaysConvertedWhereItStood() async {
    var originalRequests = 0
    var convertedRequests = 0
    let original = original
    let converted = converted
    let model = model(
      converted: { _ in
        convertedRequests += 1
        return .ready(converted)
      },
      resolve: { _ in
        originalRequests += 1
        return .ready(original)
      })

    await model.loadIfNeeded()
    XCTAssertFalse(model.fallsBack(after: .accessExpired, beforeFirstFrame: true))
    await model.playerFailed(.accessExpired, heldSeconds: 120, beforeFirstFrame: true)
    XCTAssertEqual(originalRequests, 2)
    XCTAssertEqual(convertedRequests, 0)

    XCTAssertTrue(model.fallsBack(after: .accessExpired, beforeFirstFrame: true))
    await model.playerFailed(.accessExpired, heldSeconds: 120, beforeFirstFrame: true)

    XCTAssertTrue(model.playsConvertedFallback)
    XCTAssertEqual(convertedRequests, 1)
    XCTAssertEqual(
      model.state,
      .ready(
        PutioPlaybackSource(url: converted.url, startFromSeconds: 120, resumesAfterFailure: true)))
  }

  func testAnOriginalRefusedAfterReadyButBeforeItsFirstFramePlaysConvertedAfterOneRefresh() async {
    var originalRequests = 0
    var convertedRequests = 0
    let original = original
    let converted = converted
    let model = model(
      converted: { _ in
        convertedRequests += 1
        return .ready(converted)
      },
      resolve: { _ in
        originalRequests += 1
        return .ready(original)
      })

    await model.loadIfNeeded()
    model.playerReady()
    await model.playerFailed(.accessExpired, heldSeconds: 120, beforeFirstFrame: true)
    model.playerReady()
    XCTAssertTrue(model.fallsBack(after: .accessExpired, beforeFirstFrame: true))
    await model.playerFailed(.accessExpired, heldSeconds: 120, beforeFirstFrame: true)

    XCTAssertEqual(originalRequests, 2)
    XCTAssertEqual(convertedRequests, 1)
    XCTAssertTrue(model.playsConvertedFallback)
    XCTAssertEqual(
      model.state,
      .ready(
        PutioPlaybackSource(url: converted.url, startFromSeconds: 120, resumesAfterFailure: true)))
  }

  func testAnOriginalWithoutAConvertedStreamRefusedAfterReadyShowsExpiredAccessAfterOneRefresh()
    async
  {
    var originalRequests = 0
    let original = original
    let model = PutioVideoPlaybackModel(
      fileID: fileID,
      resolve: { _ in
        originalRequests += 1
        return .ready(original)
      })

    await model.loadIfNeeded()
    model.playerReady()
    await model.playerFailed(.accessExpired, heldSeconds: 120, beforeFirstFrame: true)
    model.playerReady()
    await model.playerFailed(.accessExpired, heldSeconds: 120, beforeFirstFrame: true)

    XCTAssertEqual(originalRequests, 2)
    XCTAssertEqual(model.state, .failed(.accessExpired))
  }

  func testARefusalAfterTheFirstFrameOrWithoutAConvertedStreamShowsExpiredAccess() async {
    let converted = converted
    let original = original
    let models = [
      (model(converted: { _ in .ready(converted) }), false),
      (
        PutioVideoPlaybackModel(fileID: fileID, resolve: { _ in .ready(original) }), true
      ),
    ]
    for (model, beforeFirstFrame) in models {
      await model.loadIfNeeded()
      await model.playerFailed(.accessExpired, heldSeconds: 120, beforeFirstFrame: beforeFirstFrame)
      XCTAssertFalse(model.fallsBack(after: .accessExpired, beforeFirstFrame: beforeFirstFrame))
      await model.playerFailed(.accessExpired, heldSeconds: 120, beforeFirstFrame: beforeFirstFrame)

      XCTAssertEqual(
        model.state, .failed(.accessExpired), "before the first frame: \(beforeFirstFrame)")
      XCTAssertFalse(model.playsConvertedFallback)
    }
  }

  func testOnlyAPlaybackFaultFallsBackBeforeAnyRefresh() async {
    let converted = converted
    for (fault, beforeFirstFrame) in [
      (PutioVideoPlayerFault.playback, false), (.connectionLost, true), (.accessExpired, true),
    ] {
      let model = model(converted: { _ in .ready(converted) })
      await model.loadIfNeeded()
      XCTAssertFalse(
        model.fallsBack(after: fault, beforeFirstFrame: beforeFirstFrame),
        "\(fault) before the first frame: \(beforeFirstFrame)")
    }
  }

  func testAStreamThatIsNotAnOriginalNeverFallsBack() async {
    let converted = converted
    let model = model(converted: { _ in .ready(converted) }, resolve: { _ in .ready(converted) })

    await model.loadIfNeeded()
    XCTAssertFalse(model.fallsBack(after: .playback, beforeFirstFrame: true))
    await model.playerFailed(.playback, heldSeconds: nil, beforeFirstFrame: true)
    XCTAssertEqual(model.state, .failed(.playback))
  }

  func testNoConvertedVersionShowsCantPlayThisFile() async {
    let model = model(converted: { _ in throw PutioPlaybackUnplayable(reason: "decoder_error") })

    await model.loadIfNeeded()
    await model.playerFailed(.playback, heldSeconds: 3, beforeFirstFrame: true)

    XCTAssertEqual(model.state, .failed(.unsupported))
    XCTAssertFalse(model.playsConvertedFallback)
    XCTAssertEqual(PutioVideoPlaybackFailure.unsupported.title, "Can’t play this file")
  }

  func testTryAgainAfterTheFallbackStillAsksForTheConvertedStream() async {
    var convertedRequests = 0
    var originalRequests = 0
    let original = original
    let model = model(
      converted: { _ in
        convertedRequests += 1
        throw PutioRuntimeError.transient
      },
      resolve: { _ in
        originalRequests += 1
        return .ready(original)
      })

    await model.loadIfNeeded()
    await model.playerFailed(.playback, heldSeconds: nil, beforeFirstFrame: true)
    await model.retry()

    XCTAssertEqual(originalRequests, 1)
    XCTAssertEqual(convertedRequests, 2)
  }

  func testAConvertedFallbackRemembersTheNewestFilesPerAccount() async throws {
    let defaults = try XCTUnwrap(UserDefaults(suiteName: "converted-fallbacks-\(UUID())"))
    let fallbacks = PutioConvertedFallbacks(defaults: defaults, accountID: 7)
    for id in 1...(PutioConvertedFallbacks.limit + 1) {
      fallbacks.remember(PutioFileID(rawValue: id))
    }
    fallbacks.remember(PutioFileID(rawValue: 2))

    XCTAssertFalse(fallbacks.contains(PutioFileID(rawValue: 1)))
    XCTAssertTrue(fallbacks.contains(PutioFileID(rawValue: 2)))
    XCTAssertTrue(fallbacks.contains(PutioFileID(rawValue: PutioConvertedFallbacks.limit + 1)))
    XCTAssertFalse(
      PutioConvertedFallbacks(defaults: defaults, accountID: 8)
        .contains(PutioFileID(rawValue: 2)))

    PutioConvertedFallbacks.clear(defaults: defaults, accountID: 7)
    XCTAssertFalse(fallbacks.contains(PutioFileID(rawValue: 2)))
  }

  private func model(
    converted: @escaping PutioPlaybackResolve, resolve: PutioPlaybackResolve? = nil
  ) -> PutioVideoPlaybackModel {
    let original = original
    return PutioVideoPlaybackModel(
      fileID: fileID, resolveConverted: converted,
      resolve: resolve ?? { _ in .ready(original) })
  }
}
