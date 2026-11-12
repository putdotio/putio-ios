import XCTest

@testable import PutioCore

final class PutioWelcomeSequenceTests: XCTestCase {
  private let easingTolerance = 0.005

  func testEachFrameHoldsThenRollsToTheNext() {
    XCTAssertEqual(PutioWelcomeSequence.position(elapsed: 0, frameCount: 2), 0)
    XCTAssertEqual(PutioWelcomeSequence.position(elapsed: 1.9, frameCount: 2), 0)
    XCTAssertEqual(
      PutioWelcomeSequence.position(elapsed: 2.05, frameCount: 2), 0.066, accuracy: easingTolerance)
    XCTAssertEqual(
      PutioWelcomeSequence.position(elapsed: 2.2, frameCount: 2), 0.636, accuracy: easingTolerance)
    XCTAssertEqual(
      PutioWelcomeSequence.position(elapsed: 2.35, frameCount: 2), 0.954, accuracy: easingTolerance)
    XCTAssertEqual(PutioWelcomeSequence.position(elapsed: 2.5, frameCount: 2), 1)
    XCTAssertEqual(PutioWelcomeSequence.position(elapsed: 4.4, frameCount: 2), 1)
  }

  func testTheLastRollBringsTheFirstFrameBackAndTheSequenceLoops() {
    XCTAssertEqual(
      PutioWelcomeSequence.position(elapsed: 4.7, frameCount: 2), 1.636, accuracy: easingTolerance)
    XCTAssertEqual(PutioWelcomeSequence.position(elapsed: 5, frameCount: 2), 0)
    XCTAssertEqual(PutioWelcomeSequence.position(elapsed: 7.5, frameCount: 2), 1)
  }

  func testASingleFrameNeverRolls() {
    XCTAssertEqual(PutioWelcomeSequence.position(elapsed: 2.2, frameCount: 1), 0)
    XCTAssertEqual(PutioWelcomeSequence.position(elapsed: 5, frameCount: 1), 0)
  }
}
