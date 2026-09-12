import XCTest

/// Drives the seeded device-code flow with the Siri Remote: the first code
/// expires after one poll, "Get new code" issues one that is approved, the
/// session survives a relaunch, and sign-out returns to a fresh code.
final class DeviceSignInJourneyTests: XCTestCase {
  func testCodeExpiryApprovalRelaunchAndSignOut() {
    continueAfterFailure = false
    let app = XCUIApplication()
    app.launchArguments = ["--putio-harness-scenario", "device-sign-in"]
    app.launch()

    let code = app.descendants(matching: .any)["auth.device-code"]
    XCTAssertTrue(waitForValue(code, "TVXP1", timeout: 15))
    attach("runtime-tv-sign-in-code")
    XCTAssertTrue(app.staticTexts["put.io/link"].exists)
    XCTAssertTrue(app.staticTexts["auth.awaiting-approval"].exists)

    let expired = app.descendants(matching: .any)["auth.code-expired"]
    XCTAssertTrue(expired.waitForExistence(timeout: 10))
    XCTAssertEqual(code.value as? String, "TVXP1", "the expired code stays visible")
    let newCode = app.buttons["auth.new-code"]
    XCTAssertTrue(newCode.waitForExistence(timeout: 5))
    XCTAssertTrue(focus(newCode))
    attach("runtime-tv-sign-in-expired")
    XCUIRemote.shared.press(.select)

    XCTAssertTrue(waitForValue(code, "TVOK2", timeout: 10))
    XCTAssertFalse(expired.exists)
    let username = app.descendants(matching: .any)["account.username"]
    XCTAssertTrue(username.waitForExistence(timeout: 15))
    XCTAssertEqual(username.label, "moviebuff")
    XCTAssertTrue(app.descendants(matching: .any)["account.storage"].exists)
    let signOut = app.buttons["auth.sign-out"]
    XCTAssertTrue(signOut.waitForExistence(timeout: 5))
    XCTAssertTrue(focus(signOut))
    attach("runtime-tv-account")

    // The keychain session restores without showing a code.
    app.terminate()
    app.launch()
    XCTAssertTrue(username.waitForExistence(timeout: 15))
    XCTAssertFalse(code.exists)
    XCTAssertTrue(signOut.waitForExistence(timeout: 5))
    XCTAssertTrue(focus(signOut))

    // Menu dismisses the confirmation without signing out.
    XCUIRemote.shared.press(.select)
    let confirm = app.buttons["auth.sign-out-confirm"]
    XCTAssertTrue(confirm.waitForExistence(timeout: 5))
    XCUIRemote.shared.press(.menu)
    XCTAssertTrue(waitUntil(timeout: 5) { !confirm.exists })
    XCTAssertTrue(username.exists)

    XCTAssertTrue(focus(signOut))
    XCUIRemote.shared.press(.select)
    XCTAssertTrue(confirm.waitForExistence(timeout: 5))
    // The dialog opens on Cancel; the destructive action sits to its right.
    XCTAssertTrue(focus(confirm, directions: [.right, .left, .right]))
    XCUIRemote.shared.press(.select)

    XCTAssertTrue(waitForValue(code, "TVWT3", timeout: 15))
    XCTAssertFalse(username.exists)
  }

  /// Moves focus onto `element` with the remote, bounded so a screen that
  /// never offers it still fails instead of looping.
  private func focus(
    _ element: XCUIElement,
    directions: [XCUIRemote.Button] = [.down, .down, .up, .down, .down, .down]
  ) -> Bool {
    for direction in directions {
      if waitUntil(timeout: 1, { element.hasFocus }) { return true }
      XCUIRemote.shared.press(direction)
    }
    return waitUntil(timeout: 2) { element.hasFocus }
  }

  private func waitForValue(_ element: XCUIElement, _ value: String, timeout: TimeInterval)
    -> Bool
  {
    waitUntil(timeout: timeout) { element.exists && element.value as? String == value }
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
