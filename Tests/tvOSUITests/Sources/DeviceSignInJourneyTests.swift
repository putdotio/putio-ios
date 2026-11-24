import XCTest

/// Drives the seeded device-code flow with the Siri Remote: each code shows
/// put.io's QR beside it, the first code expires after three polls, "Get a
/// new code" issues one that survives an unreachable poll, is approved and
/// lands on Home, the session survives a relaunch, and signing out from
/// Account returns to a fresh code.
final class DeviceSignInJourneyTests: XCTestCase {
  func testCodeExpiryApprovalRelaunchAndSignOut() {
    continueAfterFailure = false
    let app = XCUIApplication()
    app.launchArguments = ["--putio-harness-scenario", "device-sign-in"]
    app.launch()

    let code = app.descendants(matching: .any)["auth.device-code"]
    XCTAssertTrue(waitForValue(code, "TVXP1", timeout: 15))
    let qrCode = app.descendants(matching: .any)["auth.qr-code"]
    XCTAssertTrue(qrCode.waitForExistence(timeout: 10), "the QR never joined the code")
    attach("runtime-tv-sign-in-code")
    XCTAssertTrue(
      app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "put.io/link"))
        .firstMatch.exists)
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
    let offline = app.staticTexts["auth.offline"]
    XCTAssertTrue(offline.waitForExistence(timeout: 10), "an unreachable poll never showed")
    XCTAssertEqual(code.value as? String, "TVOK2", "the code stays through the outage")
    attach("runtime-tv-sign-in-offline")
    XCTAssertTrue(TVTabBar(app).open("Account"))
    XCUIRemote.shared.press(.down)
    let username = app.descendants(matching: .any)["account.username"]
    XCTAssertTrue(username.waitForExistence(timeout: 15))
    XCTAssertEqual(username.label, "moviebuff")
    XCTAssertTrue(app.descendants(matching: .any)["account.storage"].exists)
    let signOut = app.buttons["auth.sign-out"]
    XCTAssertTrue(signOut.waitForExistence(timeout: 5))
    XCTAssertTrue(focus(signOut, moving: .up))
    attach("runtime-tv-account")

    // The keychain session restores to Home without showing a code.
    app.terminate()
    app.launch()
    XCTAssertTrue(TVTabBar(app).open("Account"))
    XCTAssertFalse(code.exists)
    XCUIRemote.shared.press(.down)
    XCTAssertTrue(username.waitForExistence(timeout: 15))
    XCTAssertTrue(signOut.waitForExistence(timeout: 5))
    XCTAssertTrue(focus(signOut, moving: .up))

    // Menu dismisses the confirmation without signing out.
    XCUIRemote.shared.press(.select)
    let confirm = app.buttons["auth.sign-out-confirm"]
    XCTAssertTrue(confirm.waitForExistence(timeout: 5))
    XCUIRemote.shared.press(.menu)
    XCTAssertTrue(waitUntil(timeout: 5) { !confirm.exists })
    XCTAssertTrue(username.exists)

    XCTAssertTrue(focus(signOut, moving: .up))
    XCUIRemote.shared.press(.select)
    XCTAssertTrue(confirm.waitForExistence(timeout: 5))
    // The dialog opens on Cancel with the destructive action to its right.
    // Alert buttons never report `hasFocus`, so the fresh code below is the
    // proof that Select landed on Sign out.
    XCUIRemote.shared.press(.right)
    XCUIRemote.shared.press(.select)

    // The relaunched process issues codes from the start of the seeded sequence.
    XCTAssertTrue(waitForValue(code, "TVXP1", timeout: 15))
    XCTAssertFalse(username.exists)
  }

  /// A saved sign-in put.io can't check at launch shows the offline notice and
  /// restores on its own; when Files then finds the session rejected, sign-in
  /// returns with the expired-session title.
  func testOfflineLaunchRestoresOnItsOwnAndAnExpiredSessionAsksToSignIn() {
    continueAfterFailure = false
    let app = XCUIApplication()
    app.launchArguments = [
      "--putio-harness-scenario", "device-sign-in",
      "--putio-harness-saved-credential-at-launch", "--putio-harness-restore-offline-once",
      "--putio-harness-restore-seconds", "8", "--putio-harness-session-expires",
    ]
    app.launch()

    let checking = app.staticTexts["Checking your session"].firstMatch
    XCTAssertTrue(checking.waitForExistence(timeout: 10), "the session check never showed")
    attach("runtime-tv-session-checking")
    let failure = app.staticTexts["auth.failure"]
    XCTAssertTrue(failure.waitForExistence(timeout: 15), "the offline notice never showed")
    XCTAssertTrue(app.buttons["auth.retry"].exists)
    XCTAssertTrue(app.buttons["auth.discard-credential"].exists)
    attach("runtime-tv-session-offline")

    XCTAssertTrue(
      TVTabBar(app).item("Files").waitForExistence(timeout: 40),
      "the saved session never restored on its own")
    XCTAssertFalse(failure.exists)
    // Focusing Files loads it; the seeded rejection then replaces the tab bar.
    let expired = app.staticTexts["auth.session-expired"]
    for direction in [XCUIRemote.Button.up, .up, .right, .right, .right, .right]
    where !expired.exists {
      XCUIRemote.shared.press(direction)
      _ = expired.waitForExistence(timeout: 2)
    }
    XCTAssertTrue(
      expired.waitForExistence(timeout: 15), "a session put.io rejects never asked to sign in")
    let code = app.descendants(matching: .any)["auth.device-code"]
    XCTAssertTrue(code.waitForExistence(timeout: 15))
    attach("runtime-tv-session-expired")
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

  /// Account's sign-out sits in the header above the settings list.
  private func focus(_ element: XCUIElement, moving direction: XCUIRemote.Button) -> Bool {
    for _ in 0..<8 {
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
