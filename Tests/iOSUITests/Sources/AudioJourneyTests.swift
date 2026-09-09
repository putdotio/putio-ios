import XCTest

final class AudioJourneyTests: XCTestCase {
  func testAudioPlaysPausesChangesSpeedAndAdvancesToTheNextTrack() throws {
    continueAfterFailure = false
    let app = XCUIApplication()
    app.launchArguments = ["--putio-harness-scenario", "files-browser"]
    app.launchEnvironment["PUTIO_HARNESS_MEDIA_BASE_URL"] = try XCTUnwrap(
      ProcessInfo.processInfo.environment["PUTIO_HARNESS_MEDIA_BASE_URL"])
    app.launch()
    let signIn = app.descendants(matching: .any)["auth.sign-in"]
    XCTAssertTrue(signIn.waitForExistence(timeout: 10))
    signIn.tap()
    let track = app.descendants(matching: .any)["files.item.408"]
    XCTAssertTrue(track.waitForExistence(timeout: 10))
    track.tap()

    let state = app.descendants(matching: .any)["audio.state"]
    XCTAssertTrue(state.waitForExistence(timeout: 10))
    XCTAssertTrue(waitForValue(state, "id=408;state=playing"))
    XCTAssertEqual(app.descendants(matching: .any)["audio.title"].label, "Harness Track.m4a")

    let playPause = app.buttons["audio.play-pause"]
    XCTAssertTrue(playPause.waitForExistence(timeout: 5))
    playPause.tap()
    XCTAssertTrue(waitForValue(state, "id=408;state=paused"))
    let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
    attachment.name = "runtime-audio-player"
    attachment.lifetime = .keepAlways
    add(attachment)

    let speed = app.buttons["audio.speed"]
    XCTAssertEqual(speed.value as? String, "1×")
    speed.tap()
    let faster = app.buttons["audio.speed.1.5"]
    XCTAssertTrue(faster.waitForExistence(timeout: 5))
    faster.tap()
    XCTAssertTrue(waitForValue(speed, "1.5×"))

    playPause.tap()
    XCTAssertTrue(waitForValue(state, "id=408;state=playing"))
    // The four-second fixture ends on its own and the successor takes over.
    XCTAssertTrue(waitForValue(state, "id=409;state=playing", timeout: 20))
    XCTAssertEqual(speed.value as? String, "1.5×")
    XCTAssertTrue(waitForValue(state, "id=409;state=ended", timeout: 20))
    XCTAssertTrue(app.descendants(matching: .any)["audio.ended"].exists)

    app.buttons["audio.done"].tap()
    XCTAssertTrue(track.waitForExistence(timeout: 5))
    track.tap()
    XCTAssertTrue(waitForValue(state, "id=408;state=playing", timeout: 10))
    XCTAssertEqual(speed.value as? String, "1.5×")
    app.buttons["audio.done"].tap()

    let account = app.buttons["Account"]
    XCTAssertTrue(account.waitForExistence(timeout: 5))
    account.tap()
    let signOut = app.descendants(matching: .any)["auth.sign-out"]
    XCTAssertTrue(signOut.waitForExistence(timeout: 5))
    if !signOut.isHittable { app.swipeUp() }
    let hittable = XCTNSPredicateExpectation(
      predicate: NSPredicate(format: "hittable == true"), object: signOut)
    XCTAssertEqual(XCTWaiter.wait(for: [hittable], timeout: 5), .completed)
    signOut.tap()
    XCTAssertTrue(signIn.waitForExistence(timeout: 10))
  }

  private func waitForValue(_ element: XCUIElement, _ value: String, timeout: TimeInterval = 10)
    -> Bool
  {
    let expectation = XCTNSPredicateExpectation(
      predicate: NSPredicate(format: "value == %@", value), object: element)
    return XCTWaiter.wait(for: [expectation], timeout: timeout) == .completed
  }
}
