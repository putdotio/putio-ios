import XCTest

final class SessionWelcomeJourneyTests: XCTestCase {
  private var app: XCUIApplication!
  private var settings: XCUIApplication?
  private var originalReduceMotion: Bool?

  override func setUpWithError() throws {
    try super.setUpWithError()
    continueAfterFailure = false
    XCUIDevice.shared.orientation = .portrait
    app = XCUIApplication()
    app.launchArguments = [
      "--putio-harness-scenario", "files-browser", "--putio-harness-signed-out-at-launch",
    ]
    app.launchEnvironment["PUTIO_HARNESS_MEDIA_BASE_URL"] = try XCTUnwrap(
      ProcessInfo.processInfo.environment["PUTIO_HARNESS_MEDIA_BASE_URL"])
  }

  override func tearDownWithError() throws {
    app?.terminate()
    app = nil
    defer { settings?.terminate() }
    if let settings, let originalReduceMotion {
      settings.activate()
      XCTAssertTrue(setReduceMotion(originalReduceMotion, in: settings))
    }
    try super.tearDownWithError()
  }

  func testFramesRollAndReduceMotionHoldsFrameOne() throws {
    app.launch()
    XCTAssertTrue(signInButton.appears(within: 15), "the welcome screen never appeared")
    XCTAssertTrue(stage.appears(within: 5), "the welcome stage probe is missing")
    XCTAssertTrue(
      waitForStage("frame=0;rolling=true;dots=true", timeout: 5), "the stage did not start rolling")
    XCTAssertTrue(
      waitForStage("frame=1;rolling=true;dots=true", timeout: 5), "the frames never rolled")
    addScreenshot(named: "runtime-session-welcome-rolled")
    XCTAssertTrue(
      waitForStage("frame=0;rolling=true;dots=true", timeout: 5), "the sequence did not loop")
    app.terminate()

    let settings = XCUIApplication(bundleIdentifier: "com.apple.Preferences")
    self.settings = settings
    settings.launch()
    let toggle = try reduceMotionSwitch(in: settings)
    originalReduceMotion = toggle.value as? String == "1"
    XCTAssertTrue(setReduceMotion(true, in: settings))

    app.launch()
    XCTAssertTrue(signInButton.appears(within: 15), "the welcome screen never appeared")
    XCTAssertTrue(waitForStage("frame=0;rolling=false;dots=true", timeout: 5))
    RunLoop.current.run(until: .now.addingTimeInterval(6))
    XCTAssertEqual(
      stage.value as? String, "frame=0;rolling=false;dots=true",
      "Reduce Motion did not hold frame one")
    addScreenshot(named: "runtime-session-welcome-reduce-motion")
  }

  func testCancelFailRetryAndExpiry() {
    app.launchArguments += [
      "--putio-harness-sign-in-cancels-once", "--putio-harness-sign-in-fails-once",
      "--putio-harness-sign-in-check-seconds", "6", "--putio-harness-session-expires",
    ]
    app.launch()
    XCTAssertTrue(signInButton.appears(within: 15), "the welcome screen never appeared")
    assertWelcome(title: "Welcome!", button: "Sign in", notice: false)
    addScreenshot(named: "runtime-session-welcome")

    signInButton.tap()
    XCTAssertTrue(waitForLabel(signInButton, "Sign in", timeout: 5))
    assertWelcome(title: "Welcome!", button: "Sign in", notice: false)
    addScreenshot(named: "runtime-session-cancelled")

    signInButton.tap()
    XCTAssertTrue(
      waitForLabel(signInButton, "Checking your session", timeout: 5),
      "the button was not busy while the session was checked")
    XCTAssertFalse(signInButton.isEnabled, "the busy button still accepts taps")
    XCTAssertTrue(notice.appears(within: 10), "the failed sign-in showed no notice")
    assertWelcome(title: "Welcome!", button: "Try again", notice: true)
    XCTAssertTrue(waitForStage("frame=0;rolling=false;dots=false", timeout: 5))
    addScreenshot(named: "runtime-session-sign-in-failed")

    signInButton.tap()
    XCTAssertTrue(
      waitForLabel(signInButton, "Checking your session", timeout: 5),
      "retrying did not start a new sign-in")
    assertWelcome(title: "Welcome!", button: "Checking your session", notice: false)
    XCTAssertTrue(
      waitForStage(endingWith: ";rolling=true;dots=true", timeout: 5),
      "retrying did not return to the fresh stage")
    addScreenshot(named: "runtime-session-checking")
    XCTAssertTrue(
      app.staticTexts["Welcome back!"].appears(within: 15), "the session never expired")
    assertWelcome(title: "Welcome back!", button: "Sign in", notice: false)
    XCTAssertTrue(
      app.staticTexts["Your session expired. Sign in again to continue."].exists,
      "the expired lede is missing")
    addScreenshot(named: "runtime-session-expired")

    signInButton.tap()
    XCTAssertTrue(element("files.screen.0").appears(within: 15), "signing in again failed")
    signOut()
  }

  private var signInButton: XCUIElement { element("auth.sign-in").firstMatch }
  private var notice: XCUIElement { element("auth.notice").firstMatch }
  private var stage: XCUIElement { element("welcome.stage").firstMatch }

  private func assertWelcome(
    title: String, button: String, notice expectsNotice: Bool,
    file: StaticString = #filePath, line: UInt = #line
  ) {
    XCTAssertEqual(element("auth.welcome-title").label, title, file: file, line: line)
    XCTAssertEqual(signInButton.label, button, file: file, line: line)
    XCTAssertEqual(notice.exists, expectsNotice, file: file, line: line)
  }

  private func signOut() {
    app.buttons.matching(NSPredicate(format: "label == %@", "Account")).firstMatch.tap()
    let signOut = app.revealed("auth.sign-out")
    XCTAssertTrue(signOut.appears(within: 5))
    signOut.tap()
    app.confirmSignOut()
    XCTAssertTrue(signInButton.appears(within: 10))
  }

  private func waitForStage(_ value: String, timeout: TimeInterval) -> Bool {
    waitForValue(stage, value, timeout: timeout)
  }

  private func waitForValue(_ element: XCUIElement, _ value: String, timeout: TimeInterval)
    -> Bool
  {
    let expectation = XCTNSPredicateExpectation(
      predicate: NSPredicate(format: "value == %@", value), object: element)
    return XCTWaiter.wait(for: [expectation], timeout: timeout) == .completed
  }

  private func waitForStage(endingWith suffix: String, timeout: TimeInterval) -> Bool {
    let expectation = XCTNSPredicateExpectation(
      predicate: NSPredicate(format: "value ENDSWITH %@", suffix), object: stage)
    return XCTWaiter.wait(for: [expectation], timeout: timeout) == .completed
  }

  private func waitForLabel(_ element: XCUIElement, _ label: String, timeout: TimeInterval)
    -> Bool
  {
    let expectation = XCTNSPredicateExpectation(
      predicate: NSPredicate(format: "label == %@", label), object: element)
    return XCTWaiter.wait(for: [expectation], timeout: timeout) == .completed
  }

  private func reduceMotionSwitch(in settings: XCUIApplication) throws -> XCUIElement {
    let toggle = settings.switches["Reduce Motion"]
    if toggle.appears(within: 2) { return toggle }
    let motion = settings.staticTexts["Motion"].firstMatch
    if !motion.exists {
      let accessibility = settings.staticTexts["Accessibility"].firstMatch
      for _ in 0..<5 {
        if accessibility.exists && accessibility.isHittable { break }
        settings.swipeUp()
      }
      XCTAssertTrue(accessibility.exists && accessibility.isHittable)
      accessibility.tap()
    }
    XCTAssertTrue(motion.appears(within: 5))
    if !motion.isHittable { settings.swipeUp() }
    motion.tap()
    XCTAssertTrue(toggle.appears(within: 5))
    return toggle
  }

  private func setReduceMotion(_ enabled: Bool, in settings: XCUIApplication) -> Bool {
    guard let toggle = try? reduceMotionSwitch(in: settings) else { return false }
    let value = enabled ? "1" : "0"
    for _ in 0..<2 {
      if toggle.value as? String == value { return true }
      toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
      if waitForValue(toggle, value, timeout: 3) { return true }
    }
    return false
  }

  private func addScreenshot(named name: String) {
    let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
    attachment.name = name
    attachment.lifetime = .keepAlways
    add(attachment)
  }

  private func element(_ identifier: String) -> XCUIElement {
    app.descendants(matching: .any)[identifier]
  }
}
