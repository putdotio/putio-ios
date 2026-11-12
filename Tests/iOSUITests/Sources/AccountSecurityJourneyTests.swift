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
    tap("account.two-factor")

    // Enrollment: secret, a rejected code that clears the field, then the
    // accepted code and the recovery codes.
    let twoFactor = app.switches["security.two-factor"]
    XCTAssertTrue(twoFactor.appears(within: 5))
    assertToggle(twoFactor, value: "0")
    tapToggle(twoFactor)
    let secret = element("security.two-factor-secret")
    XCTAssertTrue(secret.appears(within: 10))
    XCTAssertEqual(secret.value as? String, "HARNESSSECRETJBSWY3DP")
    tap("security.two-factor-next")
    let code = app.textFields["security.two-factor-code"]
    XCTAssertTrue(code.appears(within: 5))
    enter("000000", into: code)
    tap("security.two-factor-submit")
    XCTAssertTrue(element("security.two-factor-failure").appears(within: 10))
    XCTAssertEqual(
      code.value as? String, "Authenticator code", "a rejected code stayed in the field")
    enter("246810", into: code)
    tap("security.two-factor-submit")
    let firstCode = element("security.recovery-code.0")
    XCTAssertTrue(firstCode.appears(within: 10))
    XCTAssertEqual(firstCode.value as? String, "code0-0")
    XCTAssertEqual(element("security.recovery-code.3").label, "Used recovery code")
    XCTAssertFalse(element("security.two-factor-cancel").exists, "recovery codes could be skipped")
    screenshot("runtime-security-recovery-codes")
    tap("security.two-factor-done")
    XCTAssertTrue(firstCode.disappears(within: 5))
    assertToggle(twoFactor, value: "1")

    // Recovery codes regenerate after a transient failure.
    tap("security.recovery-codes")
    XCTAssertTrue(firstCode.appears(within: 10))
    XCTAssertEqual(firstCode.value as? String, "code0-0")
    tap("security.recovery-regenerate")
    let regenerateConfirm = app.buttons["security.recovery-regenerate-confirm"].firstMatch
    XCTAssertTrue(waitUntilHittable(regenerateConfirm))
    regenerateConfirm.tap()
    tap("security.recovery-retry")
    XCTAssertTrue(waitForValue(firstCode, "code1-0", timeout: 10))
    XCTAssertNotEqual(element("security.recovery-code.3").label, "Used recovery code")
    // Download hands the codes to the system exporter under put.io's web name.
    tap("security.recovery-download")
    let filename = app.textFields["DOCPicker.filenameTextField"]
    XCTAssertTrue(filename.appears(within: 10), "the exporter never appeared")
    let exportedName = filename.value as? String ?? ""
    XCTAssertTrue(
      exportedName.hasPrefix("putio-two-factor-recovery-codes_"), "exported as \(exportedName)")
    XCTAssertFalse(exportedName.contains(".txt.txt"), "exported as \(exportedName)")
    screenshot("runtime-security-recovery-download")
    app.buttons["DOCPicker.actionButton"].tap()
    XCTAssertTrue(filename.disappears(within: 10), "the exporter did not finish")
    XCTAssertTrue(waitUntilHittable(element("security.recovery-download")))
    XCTAssertFalse(
      element("security.recovery-download-failure").exists, "the saved export reported a failure")
    back()
    back()

    tap("security.apps")
    XCTAssertTrue(app.navigationBars["Logged-in apps"].appears(within: 5))
    let tv = element("security.app.42")
    XCTAssertTrue(tv.appears(within: 10))
    let thisApp = element("security.app.3001")
    XCTAssertEqual(thisApp.value as? String, "This iPhone")
    XCTAssertTrue(app.staticTexts["Used on Nov 9, 2026"].exists, "the TV shows no last use")
    thisApp.swipeLeft()
    XCTAssertFalse(app.buttons["security.app.revoke.3001"].exists, "this app offered revocation")
    tv.swipeLeft()
    tap("security.app.revoke.42")
    XCTAssertTrue(
      app.staticTexts["Check your connection and try again."].appears(within: 10),
      "the failed revoke showed no reason")
    XCTAssertTrue(tv.exists, "the failed revoke dropped the row")
    tv.swipeLeft()
    tap("security.app.revoke.42")
    XCTAssertTrue(tv.disappears(within: 10))
    XCTAssertTrue(thisApp.exists)
    screenshot("runtime-security-apps")
    back()

    // Device linking needs six characters, rejects an unknown code, and
    // submits the code uppercased.
    tap("security.link-device")
    let linkCode = app.textFields["security.link-code"]
    XCTAssertTrue(linkCode.appears(within: 5))
    enter("ZZZ", into: linkCode)
    tap("security.link-submit")
    XCTAssertTrue(app.staticTexts["Must be exactly 6 characters."].appears(within: 5))
    enter("ZZZ", into: linkCode)
    tap("security.link-submit")
    XCTAssertTrue(
      app.staticTexts["That device code was not found. Check the code on the device and try again."]
        .appears(within: 10))
    XCTAssertEqual(linkCode.value as? String, "Activation code", "a rejected code stayed")
    enter("harn42", into: linkCode)
    tap("security.link-submit")
    let connected = app.alerts["Connected"]
    XCTAssertTrue(connected.appears(within: 10))
    XCTAssertTrue(connected.staticTexts["Bedroom TV is now signed in with your account."].exists)
    connected.buttons["security.link-done"].firstMatch.tap()
    XCTAssertTrue(linkCode.disappears(within: 5), "linking did not return to Account")
    tap("security.apps")
    XCTAssertTrue(element("security.app.77").appears(within: 10))
    back()

    // Disabling asks for the current code only.
    tap("account.two-factor")
    tapToggle(twoFactor)
    XCTAssertTrue(code.appears(within: 5))
    XCTAssertFalse(secret.exists)
    enter("246810", into: code)
    tap("security.two-factor-submit")
    XCTAssertTrue(code.disappears(within: 10))
    assertToggle(twoFactor, value: "0")
    XCTAssertFalse(element("security.recovery-codes").exists)
    back()

    // Clear Data retries a transient failure before confirming.
    tap("account.clear-data")
    let history = app.switches["danger.clear.history"]
    XCTAssertTrue(history.appears(within: 5))
    let clear = app.buttons["danger.clear"]
    XCTAssertFalse(clear.isEnabled, "clearing was offered with nothing selected")
    tapToggle(history)
    tapToggle(app.switches["danger.clear.trash"])
    assertToggle(history, value: "1")
    tap("danger.clear")
    let clearConfirm = app.buttons["danger.clear-confirm"].firstMatch
    XCTAssertTrue(waitUntilHittable(clearConfirm))
    clearConfirm.tap()
    XCTAssertTrue(element("danger.clear-failure").appears(within: 10))
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
    XCTAssertTrue(destroyAlert.appears(within: 5))
    let password = destroyAlert.secureTextFields.firstMatch
    password.tap()
    password.typeText("wrong")
    destroyAlert.buttons["danger.destroy-confirm"].firstMatch.tap()
    XCTAssertTrue(element("danger.destroy-failure").appears(within: 10))
    tap("danger.destroy")
    XCTAssertTrue(destroyAlert.appears(within: 5))
    password.tap()
    password.typeText("harness-pass")
    destroyAlert.buttons["danger.destroy-confirm"].firstMatch.tap()
    XCTAssertTrue(element("auth.sign-in").appears(within: 10))
  }

  func testSignOutOfAllOtherAppsAsksFirstAndKeepsFailedApps() throws {
    app.launch()
    signIn()
    app.buttons["Account"].tap()
    tap("security.apps")
    let signOutOthers = element("security.apps.sign-out-others")
    XCTAssertTrue(signOutOthers.appears(within: 10))
    let thisApp = element("security.app.3001")
    let tv = element("security.app.42")
    let android = element("security.app.43")
    let infuse = element("security.app.44")

    tap("security.apps.sign-out-others")
    let alert = app.alerts["Sign out of all other apps?"]
    XCTAssertTrue(alert.appears(within: 5))
    XCTAssertTrue(
      alert.staticTexts[
        "This iPhone stays signed in. Every other app and device has to sign in again."
      ].exists)
    alert.buttons["Cancel"].tap()
    XCTAssertTrue(alert.disappears(within: 5))
    XCTAssertTrue(tv.exists && android.exists && infuse.exists, "Cancel revoked an app")

    tap("security.apps.sign-out-others")
    XCTAssertTrue(alert.appears(within: 5))
    alert.buttons["Sign out"].tap()
    XCTAssertTrue(android.disappears(within: 10))
    XCTAssertTrue(infuse.disappears(within: 10))
    XCTAssertTrue(
      app.staticTexts["Check your connection and try again."].appears(within: 10),
      "the failed app showed no reason")
    XCTAssertTrue(tv.exists, "the failed app left the list")
    XCTAssertTrue(signOutOthers.exists, "a partial failure hid the row")
    screenshot("runtime-security-sign-out-others-partial")

    tap("security.apps.sign-out-others")
    XCTAssertTrue(alert.appears(within: 5))
    alert.buttons["Sign out"].tap()
    XCTAssertTrue(tv.disappears(within: 10))
    XCTAssertTrue(signOutOthers.disappears(within: 5), "the row stayed with only this app")
    XCTAssertTrue(thisApp.exists)
    screenshot("runtime-security-sign-out-others-done")

    app.terminate()
    app.launch()
    XCTAssertTrue(
      element("files.screen.0").appears(within: 15), "this app was signed out after relaunch")
    XCTAssertFalse(element("auth.sign-in").exists)
  }

  private func signIn() {
    let button = element("auth.sign-in")
    let root = element("files.screen.0")
    let deadline = Date.now.addingTimeInterval(10)
    while !button.exists, !root.exists, Date.now < deadline {
      _ = button.appears(within: 0.5)
    }
    if button.exists { button.tap() }
    XCTAssertTrue(root.appears(within: 10))
  }

  private func back() {
    app.navigationBars.buttons["BackButton"].tap()
  }

  /// Waits for an outcome row that may sit below the fold after a relayout.
  private func reveal(_ identifier: String) -> Bool {
    let target = element(identifier)
    if target.appears(within: 5) { return true }
    app.swipeUp()
    return target.appears(within: 10)
  }

  private func tap(_ identifier: String, file: StaticString = #filePath, line: UInt = #line) {
    // Lazy List rows below the fold are absent until scrolled into view.
    let target = app.revealed(identifier)
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
    app.bringIntoView(toggle)
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
