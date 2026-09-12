import XCTest

final class AccountSecurityJourneyTests: XCTestCase {
  private var app: XCUIApplication!

  override func setUpWithError() throws {
    try super.setUpWithError()
    continueAfterFailure = false
    app = XCUIApplication()
    app.launchArguments = [
      "--putio-harness-scenario", "files-browser", "--putio-harness-account-security",
    ]
  }

  func testTwoFactorAppsLinkingClearDataAndDestroy() throws {
    app.launch()
    signIn()
    app.buttons["Account"].tap()
    tap("account.security")

    // Enrollment: secret, a rejected code that clears the field, then the
    // accepted code and the recovery codes.
    let twoFactor = app.switches["security.two-factor"]
    XCTAssertTrue(twoFactor.waitForExistence(timeout: 5))
    assertToggle(twoFactor, value: "0")
    tapToggle(twoFactor)
    let secret = element("security.two-factor-secret")
    XCTAssertTrue(secret.waitForExistence(timeout: 10))
    XCTAssertEqual(secret.value as? String, "HARNESSSECRETJBSWY3DP")
    tap("security.two-factor-next")
    let code = app.textFields["security.two-factor-code"]
    XCTAssertTrue(code.waitForExistence(timeout: 5))
    enter("000000", into: code)
    tap("security.two-factor-submit")
    XCTAssertTrue(element("security.two-factor-failure").waitForExistence(timeout: 10))
    XCTAssertEqual(
      code.value as? String, "Authenticator code", "a rejected code stayed in the field")
    enter("246810", into: code)
    tap("security.two-factor-submit")
    let firstCode = element("security.recovery-code.0")
    XCTAssertTrue(firstCode.waitForExistence(timeout: 10))
    XCTAssertEqual(firstCode.value as? String, "code0-0")
    XCTAssertEqual(element("security.recovery-code.3").label, "Used recovery code")
    XCTAssertFalse(element("security.two-factor-cancel").exists, "recovery codes could be skipped")
    screenshot("runtime-security-recovery-codes")
    tap("security.two-factor-done")
    XCTAssertTrue(firstCode.waitForNonExistence(timeout: 5))
    assertToggle(twoFactor, value: "1")

    // Recovery codes regenerate after a transient failure.
    tap("security.recovery-codes")
    XCTAssertTrue(firstCode.waitForExistence(timeout: 10))
    XCTAssertEqual(firstCode.value as? String, "code0-0")
    tap("security.recovery-regenerate")
    let regenerateConfirm = app.buttons["security.recovery-regenerate-confirm"].firstMatch
    XCTAssertTrue(waitUntilHittable(regenerateConfirm))
    regenerateConfirm.tap()
    tap("security.recovery-retry")
    XCTAssertTrue(waitForValue(firstCode, "code1-0", timeout: 10))
    XCTAssertNotEqual(element("security.recovery-code.3").label, "Used recovery code")
    back()

    // Signed-in apps: this app has no revoke action; the TV revoke retries.
    tap("security.apps")
    let tv = element("security.app.42")
    XCTAssertTrue(tv.waitForExistence(timeout: 10))
    let thisApp = element("security.app.3001")
    XCTAssertEqual(thisApp.value as? String, "This app")
    thisApp.swipeLeft()
    XCTAssertFalse(app.buttons["security.app.revoke.3001"].exists, "this app offered revocation")
    tv.swipeLeft()
    tap("security.app.revoke.42")
    tap("security.apps.retry")
    XCTAssertTrue(tv.waitForNonExistence(timeout: 10))
    XCTAssertTrue(thisApp.exists)
    screenshot("runtime-security-apps")
    back()

    // Device linking rejects an unknown code and reports the linked app.
    tap("security.link-device")
    let linkCode = app.textFields["security.link-code"]
    XCTAssertTrue(linkCode.waitForExistence(timeout: 5))
    enter("ZZZZ", into: linkCode)
    tap("security.link-submit")
    XCTAssertTrue(element("security.link-failure").waitForExistence(timeout: 10))
    enter("HARN", into: linkCode)
    tap("security.link-submit")
    let connected = app.alerts["Connected"]
    XCTAssertTrue(connected.waitForExistence(timeout: 10))
    XCTAssertTrue(connected.staticTexts["Bedroom TV is now signed in with your account."].exists)
    connected.buttons["security.link-done"].firstMatch.tap()
    XCTAssertTrue(linkCode.waitForNonExistence(timeout: 5), "linking did not return to Security")
    tap("security.apps")
    XCTAssertTrue(element("security.app.77").waitForExistence(timeout: 10))
    back()

    // Disabling asks for the current code only.
    tapToggle(twoFactor)
    XCTAssertTrue(code.waitForExistence(timeout: 5))
    XCTAssertFalse(secret.exists)
    enter("246810", into: code)
    tap("security.two-factor-submit")
    XCTAssertTrue(code.waitForNonExistence(timeout: 10))
    assertToggle(twoFactor, value: "0")
    XCTAssertFalse(element("security.recovery-codes").exists)
    back()

    // Clear Data retries a transient failure before confirming.
    tap("account.clear-data")
    let history = app.switches["danger.clear.history"]
    XCTAssertTrue(history.waitForExistence(timeout: 5))
    let clear = app.buttons["danger.clear"]
    XCTAssertFalse(clear.isEnabled, "clearing was offered with nothing selected")
    tapToggle(history)
    tapToggle(app.switches["danger.clear.trash"])
    assertToggle(history, value: "1")
    tap("danger.clear")
    let clearConfirm = app.buttons["danger.clear-confirm"].firstMatch
    XCTAssertTrue(waitUntilHittable(clearConfirm))
    clearConfirm.tap()
    XCTAssertTrue(element("danger.clear-failure").waitForExistence(timeout: 10))
    assertToggle(history, value: "1")
    tap("danger.clear")
    XCTAssertTrue(waitUntilHittable(clearConfirm))
    clearConfirm.tap()
    XCTAssertTrue(reveal("danger.clear-success"), "clearing reported no success")
    assertToggle(history, value: "0")
    screenshot("runtime-danger-clear-data")
    back()

    // Destroy Account rejects the wrong password, then ends the session.
    tap("account.destroy-account")
    tap("danger.destroy")
    let destroyAlert = app.alerts["One last step"]
    XCTAssertTrue(destroyAlert.waitForExistence(timeout: 5))
    let password = destroyAlert.secureTextFields.firstMatch
    password.tap()
    password.typeText("wrong")
    destroyAlert.buttons["danger.destroy-confirm"].firstMatch.tap()
    XCTAssertTrue(element("danger.destroy-failure").waitForExistence(timeout: 10))
    tap("danger.destroy")
    XCTAssertTrue(destroyAlert.waitForExistence(timeout: 5))
    password.tap()
    password.typeText("harness-pass")
    destroyAlert.buttons["danger.destroy-confirm"].firstMatch.tap()
    XCTAssertTrue(element("auth.sign-in").waitForExistence(timeout: 10))
  }

  private func signIn() {
    let button = element("auth.sign-in")
    XCTAssertTrue(button.waitForExistence(timeout: 10))
    button.tap()
    XCTAssertTrue(element("files.screen.0").waitForExistence(timeout: 10))
  }

  private func back() {
    app.navigationBars.buttons["BackButton"].tap()
  }

  /// Waits for an outcome row that may sit below the fold after a relayout.
  private func reveal(_ identifier: String) -> Bool {
    let target = element(identifier)
    if target.waitForExistence(timeout: 5) { return true }
    app.swipeUp()
    return target.waitForExistence(timeout: 10)
  }

  private func tap(_ identifier: String, file: StaticString = #filePath, line: UInt = #line) {
    let target = element(identifier)
    // Lazy List rows below the fold are absent until scrolled into view.
    if !waitUntilHittable(target, timeout: 3) { app.swipeUp() }
    XCTAssertTrue(
      waitUntilHittable(target), "\(identifier) never became hittable", file: file, line: line)
    target.tap()
  }

  /// Fields keep rejected input only when the app chooses to; typing starts
  /// from whatever the field holds after the app's own reset.
  private func enter(_ text: String, into field: XCUIElement) {
    XCTAssertTrue(waitUntilHittable(field))
    field.tap()
    field.typeText(text)
  }

  private func tapToggle(_ toggle: XCUIElement) {
    XCTAssertTrue(waitUntilHittable(toggle))
    // Form exposes the full row as the switch accessibility frame.
    toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
  }

  private func assertToggle(
    _ toggle: XCUIElement, value: String, file: StaticString = #filePath, line: UInt = #line
  ) {
    let expectation = XCTNSPredicateExpectation(
      predicate: NSPredicate(format: "value == %@ AND enabled == true", value), object: toggle)
    XCTAssertEqual(
      XCTWaiter.wait(for: [expectation], timeout: 10), .completed,
      "toggle value was \(toggle.value ?? "nil")", file: file, line: line)
  }

  private func waitUntilHittable(_ target: XCUIElement, timeout: TimeInterval = 10) -> Bool {
    let expectation = XCTNSPredicateExpectation(
      predicate: NSPredicate(format: "exists == true AND hittable == true"), object: target)
    return XCTWaiter.wait(for: [expectation], timeout: timeout) == .completed
  }

  private func waitForValue(_ target: XCUIElement, _ value: String, timeout: TimeInterval)
    -> Bool
  {
    let expectation = XCTNSPredicateExpectation(
      predicate: NSPredicate(format: "value == %@", value), object: target)
    return XCTWaiter.wait(for: [expectation], timeout: timeout) == .completed
  }

  private func element(_ identifier: String) -> XCUIElement {
    app.descendants(matching: .any)[identifier]
  }

  private func screenshot(_ name: String) {
    let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
    attachment.name = name
    attachment.lifetime = .keepAlways
    add(attachment)
  }
}
