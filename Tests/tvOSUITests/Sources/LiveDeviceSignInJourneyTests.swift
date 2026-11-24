import XCTest

/// Signs in to the devs-auto put.io account with a real activation code,
/// opens Account from Home, and signs out again. Only
/// `journey --scenario live-device-sign-in` runs it: the harness approves the
/// code the app reports while this test waits.
final class LiveDeviceSignInJourneyTests: XCTestCase {
  func testApprovedCodeSignsInAndSignOutRevokes() throws {
    try XCTSkipUnless(
      ProcessInfo.processInfo.environment["PUTIO_HARNESS_LIVE"] == "1",
      "live journeys run only from the harness")
    continueAfterFailure = false
    let app = XCUIApplication()
    app.launchArguments = ["--putio-harness-scenario", "live"]
    app.launch()

    let code = app.descendants(matching: .any)["auth.device-code"]
    let awaiting = app.staticTexts["auth.awaiting-approval"]
    XCTAssertTrue(awaiting.waitForExistence(timeout: 30), "put.io never issued a code")
    let issuedCode = try XCTUnwrap(code.value as? String)
    XCTAssertFalse(issuedCode.isEmpty)
    attach("live-tv-sign-in-code")

    XCTAssertTrue(
      TVTabBar(app).open("Account", timeout: 180), "the approved code never signed in")
    XCUIRemote.shared.press(.down)
    let username = app.descendants(matching: .any)["account.username"]
    XCTAssertTrue(username.waitForExistence(timeout: 30))
    XCTAssertFalse(username.label.isEmpty)
    attach("live-tv-account")
    let signOut = app.buttons["auth.sign-out"]
    XCTAssertTrue(focus(signOut, moving: .down))

    XCUIRemote.shared.press(.select)
    let confirm = app.buttons["auth.sign-out-confirm"]
    XCTAssertTrue(confirm.waitForExistence(timeout: 5))
    XCTAssertTrue(selectAlertButton(confirm, in: app))

    // Signing out revokes the grant and asks put.io for a fresh code.
    XCTAssertTrue(awaiting.waitForExistence(timeout: 30), "sign-out did not return to a code")
    XCTAssertFalse(username.exists)
    XCTAssertNotEqual(code.value as? String, issuedCode)
    attach("live-tv-signed-out")
  }

  /// Moves focus onto `element` with the remote, bounded so a screen that
  /// never offers it still fails instead of looping.
  private func focus(_ element: XCUIElement, moving direction: XCUIRemote.Button) -> Bool {
    for _ in 0..<24 {
      if waitUntil(timeout: 1, { element.exists && element.hasFocus }) { return true }
      XCUIRemote.shared.press(direction)
    }
    return waitUntil(timeout: 2) { element.exists && element.hasFocus }
  }

  /// Steers the remote to an alert button by frame and selects it; only the
  /// outer copy of each alert button reports focus.
  private func selectAlertButton(_ target: XCUIElement, in app: XCUIApplication) -> Bool {
    RunLoop.current.run(until: Date().addingTimeInterval(1))
    let goal = target.frame
    for _ in 0..<6 {
      let focused = app.buttons.matching(NSPredicate(format: "hasFocus == true")).firstMatch
      guard focused.exists else { return false }
      let current = focused.frame
      if abs(current.midX - goal.midX) < 4, abs(current.midY - goal.midY) < 4 {
        XCUIRemote.shared.press(.select)
        return true
      }
      if abs(current.midY - goal.midY) >= 4 {
        XCUIRemote.shared.press(goal.midY > current.midY ? .down : .up)
      } else {
        XCUIRemote.shared.press(goal.midX > current.midX ? .right : .left)
      }
      RunLoop.current.run(until: Date().addingTimeInterval(0.5))
    }
    return false
  }

  private func waitUntil(timeout: TimeInterval, _ condition: () -> Bool) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
      if condition() { return true }
      RunLoop.current.run(until: Date().addingTimeInterval(0.25))
    }
    return condition()
  }

  private func attach(_ name: String) {
    let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
    attachment.name = name
    attachment.lifetime = .keepAlways
    add(attachment)
  }
}
