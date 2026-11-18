import AetherEngine
import PutioCore
import XCTest

@testable import Putio

@MainActor
final class PutioDirectPlayFaultTests: XCTestCase {
  func testAForbiddenSourceRefusalAsksForFreshAccess() {
    let refusal = PlaybackErrorInfo(
      kind: .sourceRefused, message: "Failed to load", underlyingCode: 403)

    XCTAssertEqual(PutioDirectPlayCoordinator.fault(refusal), .accessExpired)
  }

  func testAMissingSourceStaysAPlaybackFailure() {
    let refusal = PlaybackErrorInfo(
      kind: .sourceRefused, message: "Failed to load", underlyingCode: 404)

    XCTAssertEqual(PutioDirectPlayCoordinator.fault(refusal), .playback)
  }
}
