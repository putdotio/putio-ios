import XCTest

@testable import PutioCore

final class SignedOutPresentationTests: XCTestCase {
  func testPutioPresentationDescribesSignedOutState() {
    XCTAssertEqual(SignedOutPresentation.putio.title, "put.io")
    XCTAssertEqual(SignedOutPresentation.putio.message, "Sign in to continue")
  }
}
