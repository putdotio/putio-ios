import XCTest

@testable import PutioDomain

final class PutioPlaybackRecoveryTests: XCTestCase {
  func testEveryFailureOffersOneRecovery() {
    XCTAssertEqual(PutioVideoPlaybackFailure.accessExpired.recovery, .reconnect)
    XCTAssertEqual(PutioVideoPlaybackFailure.connectionLost.recovery, .reconnect)
    XCTAssertEqual(PutioVideoPlaybackFailure.playback.recovery, .retry)
    XCTAssertEqual(PutioVideoPlaybackFailure.conversion.recovery, .convertAgain)
    XCTAssertEqual(PutioVideoPlaybackFailure.unsupported.recovery, .playElsewhere)
    XCTAssertEqual(PutioVideoPlaybackFailure.conversionUnavailable.recovery, .playElsewhere)
    XCTAssertEqual(
      PutioVideoPlaybackFailure.checkingConversion(PutioRuntimeError.transient)?.recovery,
      .checkConversionAgain)
    XCTAssertEqual(
      PutioVideoPlaybackFailure.resolving(PutioRuntimeError.notFound)?.recovery, .retry)
  }

  func testConversionStatesShowOnePhase() {
    XCTAssertEqual(PutioVideoPlaybackState.conversionRequired.conversionPhase, .waiting)
    XCTAssertEqual(PutioVideoPlaybackState.conversionQueued.conversionPhase, .waiting)
    XCTAssertEqual(
      PutioVideoPlaybackState.converting(progress: 0.4).conversionPhase,
      .converting(progress: 0.4))
    XCTAssertEqual(
      PutioVideoPlaybackState.conversionCompleted.conversionPhase, .converting(progress: 1))
    XCTAssertNil(PutioVideoPlaybackState.loading.conversionPhase)
    XCTAssertEqual(PutioVideoConversionPhase.converting(progress: 0.4).title, "Converting to MP4")
  }

  func testTheWebLinkOpensTheFile() {
    XCTAssertEqual(
      PutioWebLinks.file(PutioFileID(rawValue: 411)).absoluteString,
      "https://app.put.io/files/411")
  }
}
