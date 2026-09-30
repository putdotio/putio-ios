import XCTest

/// Signs in to the devs-auto put.io account with a real activation code and
/// signs out again. Only `journey --scenario live-device-sign-in` runs it: the
/// harness approves the code the app reports while this test waits.
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

    let username = app.descendants(matching: .any)["account.username"]
    XCTAssertTrue(username.waitForExistence(timeout: 180), "the approved code never signed in")
    XCTAssertFalse(username.label.isEmpty)
    let signOut = app.buttons["auth.sign-out"]
    XCTAssertTrue(signOut.waitForExistence(timeout: 10))
    XCTAssertTrue(focus(signOut))
    attach("live-tv-account")

    XCUIRemote.shared.press(.select)
    let confirm = app.buttons["auth.sign-out-confirm"]
    XCTAssertTrue(confirm.waitForExistence(timeout: 5))
    // The dialog opens on Cancel with the destructive action to its right.
    XCUIRemote.shared.press(.right)
    XCUIRemote.shared.press(.select)

    // Signing out revokes the grant and asks put.io for a fresh code.
    XCTAssertTrue(awaiting.waitForExistence(timeout: 30), "sign-out did not return to a code")
    XCTAssertFalse(username.exists)
    XCTAssertNotEqual(code.value as? String, issuedCode)
    attach("live-tv-signed-out")
  }

  /// Moves focus onto `element` with the remote, bounded so a screen that
  /// never offers it still fails instead of looping.
  private func focus(_ element: XCUIElement) -> Bool {
    let directions: [XCUIRemote.Button] = [.down, .down, .up, .down, .down, .down]
    for direction in directions {
      if waitUntil(timeout: 1, { element.hasFocus }) { return true }
      XCUIRemote.shared.press(direction)
    }
    return waitUntil(timeout: 2) { element.hasFocus }
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
