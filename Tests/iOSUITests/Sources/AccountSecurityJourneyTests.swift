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

  func testAppsAndLinking() throws {
    app.launch()
    signIn()
    app.buttons["Account"].tap()

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
    assertRequests([Self.revokeTV])
    tv.swipeLeft()
    tap("security.app.revoke.42")
    XCTAssertTrue(tv.disappears(within: 10))
    XCTAssertTrue(thisApp.exists)
    assertRequests([Self.revokeTV, Self.revokeTV])
    screenshot("runtime-security-apps")
    back()

    tap("security.link-device")
    XCTAssertTrue(app.navigationBars["Link a device"].appears(within: 5))
    let linkCode = app.textFields["security.link-code"]
    let linkSubmit = app.buttons["security.link-submit"]
    XCTAssertTrue(linkCode.appears(within: 5))
    XCTAssertFalse(linkSubmit.isEnabled, "Link was enabled with an empty field")
    enter("zzz", into: linkCode)
    XCTAssertEqual(linkCode.value as? String, "ZZZ", "the code was not uppercased as typed")
    tap("security.link-submit")
    XCTAssertTrue(app.staticTexts["Must be exactly 6 characters."].appears(within: 5))
    assertRequests([Self.revokeTV, Self.revokeTV], "a short code reached put.io")
    enter("zzz", into: linkCode)
    tap("security.link-submit")
    XCTAssertTrue(
      app.staticTexts["That device code was not found. Check the code on the device and try again."]
        .appears(within: 10))
    XCTAssertEqual(linkCode.value as? String, "ZZZZZZ", "a rejected code was not kept for editing")
    assertRequests([Self.revokeTV, Self.revokeTV, Self.link("ZZZZZZ")])
    enter(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 6) + "harn42", into: linkCode)
    tap("security.link-submit")
    let connected = app.putioAlert("Connected")
    XCTAssertTrue(connected.appears(within: 10))
    XCTAssertTrue(app.staticTexts["Bedroom TV is now signed in with your account."].exists)
    assertRequests([Self.revokeTV, Self.revokeTV, Self.link("ZZZZZZ"), Self.link("HARN42")])
    app.buttons["security.link-done"].firstMatch.tap()
    XCTAssertTrue(connected.disappears(within: 5))
    XCTAssertEqual(linkCode.value as? String ?? "", "", "OK did not clear the field")
    XCTAssertFalse(linkSubmit.isEnabled)
    back()
    tap("security.apps")
    XCTAssertTrue(element("security.app.77").appears(within: 10))
    back()
  }

  func testClearDataAsksFirstAndKeepsTheSelectionOnFailure() throws {
    app.launch()
    signIn()
    app.buttons["Account"].tap()
    tap("account.clear-data")
    XCTAssertTrue(app.navigationBars["Clear your data"].appears(within: 5))
    let files = app.buttons["danger.clear.files"]
    let history = app.buttons["danger.clear.history"]
    let trash = app.buttons["danger.clear.trash"]
    let clear = app.buttons["danger.clear"]
    XCTAssertTrue(files.appears(within: 5))
    XCTAssertFalse(clear.isEnabled, "clearing was offered with nothing selected")

    for row in [files, history, trash] { tap(row) }
    assertSelected([files, history, trash])
    let friends = app.buttons["danger.clear.friends"]
    app.bringIntoView(friends)
    XCTAssertFalse(friends.isSelected)
    XCTAssertTrue(clear.isEnabled, "Clear stayed disabled with three categories")

    let confirm = app.putioAlert("Clear the selected data?")
    tap(clear)
    XCTAssertTrue(confirm.appears(within: 5))
    XCTAssertTrue(
      app.staticTexts[
        "This permanently deletes Files, History, and Trash from your put.io account. It can’t be undone."
      ].exists, "the confirm did not name the selected categories")
    app.buttons["putio-alert.cancel"].firstMatch.tap()
    XCTAssertTrue(confirm.disappears(within: 5))
    assertSelected([files, history, trash])
    assertRequests([], "Cancel sent a clear")

    tap(clear)
    XCTAssertTrue(confirm.appears(within: 5))
    app.buttons["confirm-alert.confirm"].firstMatch.tap()
    XCTAssertTrue(
      element("danger.clear-failure").appears(within: 10),
      "the first clear did not fail, so Cancel sent a request")
    XCTAssertEqual(
      element("danger.clear-failure").label, "Check your connection and try again.")
    assertSelected([files, history, trash])
    XCTAssertTrue(clear.isEnabled, "Clear was not offered again after a failure")
    let clearFilesHistoryTrash = Self.clear(["files", "history", "trash"])
    assertRequests([clearFilesHistoryTrash])
    screenshot("runtime-danger-clear-failed")

    tap(clear)
    XCTAssertTrue(confirm.appears(within: 5))
    app.buttons["confirm-alert.confirm"].firstMatch.tap()
    XCTAssertTrue(element("danger.clear-success").appears(within: 10), "clearing never finished")
    XCTAssertFalse(element("danger.clear-failure").exists)
    XCTAssertFalse(files.isSelected || history.isSelected || trash.isSelected)
    XCTAssertFalse(clear.isEnabled, "Clear stayed enabled after the selection was cleared")
    assertRequests([clearFilesHistoryTrash, clearFilesHistoryTrash])
    screenshot("runtime-danger-clear-data")

    tap(history)
    XCTAssertFalse(element("danger.clear-success").exists, "a new selection kept the old result")
  }

  func testLeavingMidClearFinishesCleanly() throws {
    app.launchArguments += ["--putio-harness-clear-data", "slow"]
    app.launch()
    signIn()
    app.buttons["History"].tap()
    XCTAssertTrue(
      element("history.item.810").appears(within: 10), "the seeded history never loaded")
    app.buttons["Account"].tap()
    tap("account.clear-data")
    let history = app.buttons["danger.clear.history"]
    let clear = app.buttons["danger.clear"]
    tap(history)
    tap(clear)
    XCTAssertTrue(app.putioAlert("Clear the selected data?").appears(within: 5))
    app.buttons["confirm-alert.confirm"].firstMatch.tap()
    XCTAssertTrue(
      history.wait(for: \.isEnabled, toEqual: false, timeout: 5), "the rows stayed editable")
    XCTAssertFalse(clear.isEnabled, "Clear stayed tappable while clearing")
    assertRequests([Self.clear(["history"])])
    back()
    XCTAssertTrue(app.navigationBars["Account"].appears(within: 5))

    app.showTabBar()
    app.buttons["History"].tap()
    XCTAssertTrue(
      app.staticTexts["No history"].appears(within: 15), "the clear did not finish after leaving")
    app.buttons["Account"].tap()
    tap("account.clear-data")
    XCTAssertTrue(history.appears(within: 5))
    XCTAssertTrue(history.isEnabled, "the reopened rows stayed locked")
    XCTAssertFalse(history.isSelected, "the reopened screen kept the old selection")
    XCTAssertFalse(element("danger.clear-failure").exists)
    XCTAssertFalse(element("danger.clear-success").exists)
    XCTAssertFalse(clear.isEnabled)
    assertRequests([Self.clear(["history"])], "leaving and reopening sent another clear")
  }

  func testTwoFactorAndDestroyOpenTheBrowserAndRefreshOnReturn() throws {
    app.launchArguments += [
      "--putio-harness-rating-link", "--putio-harness-two-factor-flips-in-background",
    ]
    app.launch()
    signIn()
    app.buttons["Account"].tap()
    let requests = element("account.rating-link-requests")
    XCTAssertTrue(requests.appears(within: 5))

    let twoFactor = app.revealed("account.two-factor")
    XCTAssertTrue(
      waitForLabel(twoFactor, "Two-factor authentication, Off"), "label: \(twoFactor.label)")
    tap("account.two-factor")
    XCTAssertTrue(
      waitForValue(requests, "1|https://app.put.io/account/security", timeout: 5),
      "requests: \(requests.value ?? "nil")")
    XCTAssertTrue(app.navigationBars["Account"].exists, "the two-factor row opened a screen")
    assertNoCodeOrPasswordField()

    sendToBackgroundAndReturn()
    XCTAssertTrue(
      waitForLabel(twoFactor, "Two-factor authentication, On"),
      "the value did not refresh on return: \(twoFactor.label)")

    tap("account.destroy-account")
    XCTAssertTrue(app.navigationBars["Destroy your account"].appears(within: 5))
    XCTAssertTrue(app.staticTexts["Opens put.io in your browser to finish."].exists)
    assertNoCodeOrPasswordField()
    tap("danger.destroy")
    XCTAssertTrue(
      waitForValue(requests, "2|https://app.put.io/account/danger-zone", timeout: 5),
      "requests: \(requests.value ?? "nil")")
    XCTAssertFalse(
      app.putioAlerts.firstMatch.exists, "Destroy account asked for anything in the app")
    XCTAssertTrue(app.navigationBars["Destroy your account"].exists)
    XCTAssertFalse(element("auth.sign-in").exists, "the app signed out before put.io answered")
    assertRequests([], "a browser handoff changed the account from the app")

    sendToBackgroundAndReturn()
    XCTAssertTrue(
      app.navigationBars["Destroy your account"].appears(within: 5),
      "returning without destroying left the screen")
    XCTAssertFalse(element("auth.sign-in").exists, "returning without destroying signed out")
  }

  func testAccountDestroyedInTheBrowserSignsOutOnReturn() throws {
    app.launchArguments += [
      "--putio-harness-rating-link", "--putio-harness-account-destroyed-in-background",
    ]
    app.launch()
    signIn()
    app.buttons["Account"].tap()
    tap("account.destroy-account")
    tap("danger.destroy")
    XCTAssertTrue(
      waitForValue(
        element("account.rating-link-requests"), "1|https://app.put.io/account/danger-zone",
        timeout: 5))
    sendToBackgroundAndReturn()
    XCTAssertTrue(
      element("auth.sign-in").appears(within: 10), "a destroyed account stayed signed in")
    XCTAssertFalse(app.tabBars.firstMatch.exists, "the signed-in shell outlived the account")
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
    let alert = app.putioAlert("Sign out of all other apps?")
    XCTAssertTrue(alert.appears(within: 5))
    XCTAssertTrue(
      alert.staticTexts[
        "This iPhone stays signed in. Every other app and device has to sign in again."
      ].exists)
    alert.buttons["Cancel"].tap()
    XCTAssertTrue(alert.disappears(within: 5))
    XCTAssertTrue(tv.exists && android.exists && infuse.exists, "Cancel revoked an app")
    assertRequests([], "Cancel sent a revoke")

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
    let revokeOthers = [Self.revokeTV, Self.revoke(43), Self.revoke(44)]
    assertRequests(revokeOthers, inAnyOrder: true)
    screenshot("runtime-security-sign-out-others-partial")

    tap("security.apps.sign-out-others")
    XCTAssertTrue(alert.appears(within: 5))
    alert.buttons["Sign out"].tap()
    XCTAssertTrue(tv.disappears(within: 10))
    XCTAssertTrue(signOutOthers.disappears(within: 5), "the row stayed with only this app")
    XCTAssertTrue(thisApp.exists)
    assertRequests(revokeOthers + [Self.revokeTV], inAnyOrder: true)
    screenshot("runtime-security-sign-out-others-done")

    app.terminate()
    app.launch()
    XCTAssertTrue(
      element("files.screen.0").appears(within: 15), "this app was signed out after relaunch")
    XCTAssertFalse(element("auth.sign-in").exists)
  }

  func testLeavingMidLinkCancelsCleanly() throws {
    app.launchArguments += ["--putio-harness-link-device", "hold"]
    app.launch()
    signIn()
    app.buttons["Account"].tap()
    tap("security.link-device")
    let linkCode = app.textFields["security.link-code"]
    let linkSubmit = app.buttons["security.link-submit"]
    enter("x7k2qm", into: linkCode)
    tap("security.link-submit")
    XCTAssertTrue(
      linkCode.wait(for: \.isEnabled, toEqual: false, timeout: 5), "the field stayed editable")
    XCTAssertFalse(linkSubmit.isEnabled, "Link stayed tappable while linking")
    assertRequests([Self.link("X7K2QM")])
    back()
    XCTAssertTrue(app.navigationBars["Account"].appears(within: 5))
    XCTAssertFalse(app.putioAlerts.firstMatch.appears(within: 3), "a cancelled link reported back")
    tap("security.link-device")
    XCTAssertTrue(linkCode.appears(within: 5))
    XCTAssertTrue(linkCode.isEnabled, "the reopened field stayed locked")
    XCTAssertFalse(element("security.link-failure").exists, "a cancelled link showed a failure")
    XCTAssertEqual(linkCode.value as? String ?? "", "", "the reopened field kept the old code")
    enter("x7k2qm", into: linkCode)
    XCTAssertTrue(linkSubmit.isEnabled, "Link stayed busy after the cancelled attempt")
    assertRequests([Self.link("X7K2QM")], "reopening Link a device sent the code again")
  }

  private static let revokeTV = revoke(42)

  private static func revoke(_ grantID: Int) -> String {
    "POST /v2/oauth/grants/\(grantID)/delete"
  }

  private static func link(_ code: String) -> String {
    #"POST /v2/oauth2/oob/code {"code":"\#(code)"}"#
  }

  private static func clear(_ categories: Set<String>) -> String {
    let flags = [
      "active_transfers", "files", "finished_transfers", "friends", "history", "rss_feeds",
      "rss_logs", "trash",
    ].map { #""\#($0)":\#(categories.contains($0))"# }
    return "POST /v2/account/clear {\(flags.joined(separator: ","))}"
  }

  private func sentRequests() -> [String] {
    let value = element("harness.account-requests").value as? String ?? ""
    return value.split(separator: "\n").map(String.init)
  }

  private func assertRequests(
    _ expected: [String], _ message: String = "", inAnyOrder: Bool = false,
    file: StaticString = #filePath, line: UInt = #line
  ) {
    let normalized: ([String]) -> [String] = { inAnyOrder ? $0.sorted() : $0 }
    let deadline = Date.now.addingTimeInterval(5)
    var sent = sentRequests()
    while normalized(sent) != normalized(expected), Date.now < deadline {
      _ = XCTWaiter.wait(for: [XCTestExpectation(description: "account requests")], timeout: 0.25)
      sent = sentRequests()
    }
    XCTAssertEqual(normalized(sent), normalized(expected), message, file: file, line: line)
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

  private func sendToBackgroundAndReturn() {
    XCUIDevice.shared.press(.home)
    XCTAssertTrue(
      app.wait(for: .runningBackground, timeout: 10), "the app never left the foreground")
    app.activate()
    XCTAssertTrue(app.wait(for: .runningForeground, timeout: 10), "the app never returned")
  }

  private func assertNoCodeOrPasswordField(file: StaticString = #filePath, line: UInt = #line) {
    XCTAssertEqual(app.secureTextFields.count, 0, "a password field exists", file: file, line: line)
    XCTAssertEqual(app.textFields.count, 0, "a code field exists", file: file, line: line)
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

  private func tap(_ target: XCUIElement, file: StaticString = #filePath, line: UInt = #line) {
    app.bringIntoView(target)
    XCTAssertTrue(
      waitUntilHittable(target), "\(target) never became hittable", file: file, line: line)
    target.tap()
  }

  private func assertSelected(
    _ rows: [XCUIElement], file: StaticString = #filePath, line: UInt = #line
  ) {
    for row in rows {
      XCTAssertTrue(row.isSelected, "\(row) is not checked", file: file, line: line)
    }
  }

  private func waitUntilHittable(_ target: XCUIElement, timeout: TimeInterval = 10) -> Bool {
    let expectation = XCTNSPredicateExpectation(
      predicate: NSPredicate(format: "exists == true AND hittable == true"), object: target)
    return XCTWaiter.wait(for: [expectation], timeout: timeout) == .completed
  }

  private func waitForLabel(_ target: XCUIElement, _ label: String) -> Bool {
    let expectation = XCTNSPredicateExpectation(
      predicate: NSPredicate(format: "label == %@", label), object: target)
    return XCTWaiter.wait(for: [expectation], timeout: 10) == .completed
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
