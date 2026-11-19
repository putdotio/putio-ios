import AetherEngine
import PutioCore
import XCTest

@testable import Putio

@MainActor
final class PutioDirectPlayFaultTests: XCTestCase {
  func testAForbiddenSourceRefusalAsksForFreshAccess() {
    let refusal = PlaybackErrorInfo(
      kind: .sourceRefused, message: "Failed to load", underlyingCode: 403)

    let error = PutioDirectPlayCoordinator.error(refusal)
    XCTAssertEqual(error.fault, .accessExpired)
    XCTAssertEqual(error.requestStatus, 403)
  }

  func testAMissingSourceStaysAPlaybackFailureAndReportsItGone() {
    let refusal = PlaybackErrorInfo(
      kind: .sourceRefused, message: "Failed to load", underlyingCode: 404)

    let error = PutioDirectPlayCoordinator.error(refusal)
    XCTAssertEqual(error.fault, .playback)
    XCTAssertEqual(error.mode, .sourceGone)
    XCTAssertEqual(error.requestStatus, 404)
    XCTAssertEqual(error.category, "sourceRefused")
    XCTAssertNil(error.domain)
  }

  func testEngineKindsMapOntoTheContractsFailureModes() {
    let cases: [(PlaybackErrorInfo, PutioPlaybackFailureMode)] = [
      (PlaybackErrorInfo(kind: .sourceRateLimited, message: "", underlyingCode: 429), .throttled),
      (
        PlaybackErrorInfo(kind: .sourceRateLimited, message: "", underlyingCode: 503),
        .serverTransient
      ),
      (PlaybackErrorInfo(kind: .softwarePipelineFailed, message: ""), .decode),
      (PlaybackErrorInfo(kind: .audioBridgeProducedNoOutput, message: ""), .decode),
      (PlaybackErrorInfo(kind: .dolbyVisionRequiresHardware, message: ""), .unsupportedSource),
      (PlaybackErrorInfo(kind: .sourceCertificateRejected, message: ""), .network),
      (PlaybackErrorInfo(kind: .vodSourceFailed, message: ""), .load),
      (
        PlaybackErrorInfo(
          kind: .sourceOpenFailed, message: "", underlyingDomain: NSURLErrorDomain,
          underlyingCode: NSURLErrorNotConnectedToInternet), .network
      ),
    ]
    for (info, mode) in cases {
      XCTAssertEqual(PutioDirectPlayCoordinator.error(info).mode, mode, info.kind.rawValue)
    }
    XCTAssertEqual(PutioDirectPlayCoordinator.error(nil).mode, .unknown)
  }
}
