import XCTest

@testable import PutioCore

final class SignedOutPresentationTests: XCTestCase {
  func testPutioPresentationDescribesSignedOutState() {
    XCTAssertEqual(SignedOutPresentation.putio.title, "put.io")
    XCTAssertEqual(SignedOutPresentation.putio.message, "Sign in to continue")
  }

  func testHarnessExerciseRequiresTheExplicitScenario() {
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
    XCTAssertTrue(
      SignedOutPresentation.isHarnessExercise(arguments: [
        "PutioWatch", "--putio-harness-scenario", "exercised",
      ]))
    XCTAssertFalse(
      SignedOutPresentation.isHarnessExercise(arguments: [
        "PutioWatch", "--putio-harness-scenario", "signed-out",
      ]))
    XCTAssertTrue(
      SignedOutPresentation.harnessInitialPresentation(arguments: [
        "PutioWatch", "--putio-harness-scenario", "exercised",
      ]).isHarnessExercise)
  }
}
