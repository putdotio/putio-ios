import XCTest

@testable import PutioCore

final class SignedOutPresentationTests: XCTestCase {
  func testPutioPresentationDescribesSignedOutState() {
    XCTAssertEqual(SignedOutPresentation.putio.title, "put.io")
    XCTAssertEqual(SignedOutPresentation.putio.message, "Sign in to continue")
  }

  func testHarnessExerciseRequiresTheDedicatedURL() throws {
    let exerciseURL = try XCTUnwrap(URL(string: "putio-harness://exercise"))
    let unrelatedURL = try XCTUnwrap(URL(string: "putio-harness://unrelated"))

    XCTAssertEqual(
      SignedOutPresentation.harnessExercise(for: exerciseURL)?.message,
      "Harness exercise complete"
    )
    XCTAssertNil(SignedOutPresentation.harnessExercise(for: unrelatedURL))
    XCTAssertEqual(
      SignedOutPresentation.harnessInitialPresentation(arguments: [
        "PutioWatch", "--putio-harness-scenario", "exercised",
      ]).message,
      "Harness exercise complete"
    )
    XCTAssertEqual(
      SignedOutPresentation.harnessInitialPresentation(arguments: ["PutioWatch"]),
      .putio
    )
  }
}
