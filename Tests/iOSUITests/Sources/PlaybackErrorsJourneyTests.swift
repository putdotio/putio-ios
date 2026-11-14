import XCTest

final class PlaybackErrorsJourneyTests: XCTestCase {
  private var app: XCUIApplication!

  func testExpiredAccessAndALostConnectionRecoverWithTryAgainAtTheSavedPosition() throws {
    continueAfterFailure = false
    app = XCUIApplication()
    app.launchArguments = [
      "--putio-harness-scenario", "files-browser",
      "--putio-harness-video-faults", "forbidden,forbidden,refused,forbidden,none",
    ]
    app.launchEnvironment["PUTIO_HARNESS_MEDIA_BASE_URL"] = try XCTUnwrap(
      ProcessInfo.processInfo.environment["PUTIO_HARNESS_MEDIA_BASE_URL"])
    app.launch()
    let signIn = element("auth.sign-in")
    XCTAssertTrue(signIn.appears(within: 10), "sign-in screen never appeared")
    signIn.tap()
    let rootVideo = element("files.item.412")
    XCTAssertTrue(rootVideo.appears(within: 10), "the root video never appeared")
    rootVideo.tap()
    app.answerResumePrompt()

    let error = element("video.error")
    let failures = element("video.reported-failures")
    XCTAssertTrue(error.appears(within: 15), "a second 403 did not show an error")
    XCTAssertTrue(app.staticTexts["Couldn’t play this video"].appears(within: 5))
    XCTAssertTrue(
      app.staticTexts["Playback access expired. Retry to refresh it."].appears(within: 5))
    XCTAssertEqual(failures.value as? String, "accessExpired,accessExpired")
    assertKeepsCloseAndFileName()
    addScreenshot(named: "runtime-video-access-expired")

    let retry = app.buttons["Try again"]
    retry.tap()
    XCTAssertTrue(
      app.staticTexts["Connection lost"].appears(within: 15), "a refused stream did not say so")
    XCTAssertTrue(app.staticTexts["Check your connection and try again."].appears(within: 5))
    XCTAssertTrue(waitForValue(failures, "accessExpired,accessExpired,connectionLost"))
    assertKeepsCloseAndFileName()
    addScreenshot(named: "runtime-video-connection-lost")

    retry.tap()
    let ready = element("video.ready")
    XCTAssertTrue(ready.appears(within: 15), "Try again never played after one silent refetch")
    XCTAssertFalse(error.exists, "the silent refetch showed an error")
    XCTAssertEqual(
      failures.value as? String, "accessExpired,accessExpired,connectionLost,accessExpired",
      "the last load did not get its 403 before playing")
    XCTAssertEqual(element("video.resume-position").value as? String, "560")
    let position = element("video.current-position")
    let resumed = XCTNSPredicateExpectation(
      predicate: NSPredicate(format: "value.integerValue >= 560"), object: position)
    XCTAssertEqual(
      XCTWaiter.wait(for: [resumed], timeout: 10), .completed,
      "Try again did not resume at the saved position")
    addScreenshot(named: "runtime-video-recovered")
  }

  private func assertKeepsCloseAndFileName(file: StaticString = #filePath, line: UInt = #line) {
    XCTAssertTrue(app.videoClose.isHittable, "the error hid Close", file: file, line: line)
    XCTAssertEqual(
      element("video.title").label, "Root Movie.mkv", "the error hid the file name",
      file: file, line: line)
  }

  private func waitForValue(_ element: XCUIElement, _ value: String) -> Bool {
    let expectation = XCTNSPredicateExpectation(
      predicate: NSPredicate(format: "value == %@", value), object: element)
    return XCTWaiter.wait(for: [expectation], timeout: 10) == .completed
  }

  private func element(_ identifier: String) -> XCUIElement {
    app.descendants(matching: .any)[identifier]
  }

  private func addScreenshot(named name: String) {
    let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
    attachment.name = name
    attachment.lifetime = .keepAlways
    add(attachment)
  }
}
