import XCTest

final class SessionRecoveryJourneyTests: XCTestCase {
  private var app: XCUIApplication!

  private static let savedCredential = "--putio-harness-saved-credential-at-launch"
  private static let readFailsOnce = "--putio-harness-credential-read-fails-once"
  private static let offlineOnce = "--putio-harness-restore-offline-once"
  private static let clearFails = "--putio-harness-sign-out-failure"
  private static let signInCancelsOnce = "--putio-harness-sign-in-cancels-once"

  override func setUpWithError() throws {
    try super.setUpWithError()
    continueAfterFailure = false
    XCUIDevice.shared.orientation = .portrait
    app = XCUIApplication()
    app.launchArguments = [
      "--putio-harness-scenario", "files-browser", "--putio-harness-restore-seconds", "3",
    ]
    app.launchEnvironment["PUTIO_HARNESS_MEDIA_BASE_URL"] = try XCTUnwrap(
      ProcessInfo.processInfo.environment["PUTIO_HARNESS_MEDIA_BASE_URL"])
  }

  override func tearDown() {
    app?.terminate()
    app = nil
    super.tearDown()
  }

  func testUnreadableCredentialRetriesKeepsItOnFailedResetAndResets() {
    relaunch([Self.savedCredential, Self.readFailsOnce])
    assertRecovery(
      title: "Secure storage is unavailable",
      message:
        "Your session couldn’t be read or saved safely on this iPhone. Reset clears it so you can sign in again.",
      discard: "Reset and sign in")
    addScreenshot(named: "runtime-session-storage")

    retry.tap()
    XCTAssertTrue(restoring.appears(within: 2), "retrying showed no progress")
    XCTAssertTrue(filesRoot.appears(within: 15), "retry did not restore once the fault cleared")

    relaunch([Self.readFailsOnce, Self.clearFails])
    assertRecovery(
      title: "Secure storage is unavailable",
      message:
        "Your session couldn’t be read or saved safely on this iPhone. Reset clears it so you can sign in again.",
      discard: "Reset and sign in")
    discard.tap()
    RunLoop.current.run(until: .now.addingTimeInterval(2))
    XCTAssertTrue(
      notice.label.contains("Secure storage is unavailable"),
      "a failed reset left the secure-storage screen")
    XCTAssertEqual(discard.label, "Reset and sign in", "a failed reset changed the actions")
    XCTAssertFalse(filesRoot.exists, "a failed reset signed in")

    relaunch([Self.readFailsOnce, Self.signInCancelsOnce])
    XCTAssertTrue(discard.appears(within: 15), "the secure-storage screen never appeared")
    discard.tap()
    assertFreshWelcome("reset did not land on the fresh welcome")

    relaunch([])
    assertFreshWelcome("the reset credential was restored on relaunch")
  }

  func testFailedSessionCheckRetriesAndSignInAgainRemovesTheCredential() {
    relaunch([Self.savedCredential, Self.offlineOnce])
    XCTAssertTrue(restoring.appears(within: 10), "launch restore showed no progress")
    XCTAssertFalse(element("auth.sign-in").exists, "restore offered sign-in while it ran")
    addScreenshot(named: "runtime-session-restoring")
    assertRecovery(
      title: "Couldn’t check your session",
      message: "Your sign-in is still saved. Check your connection and try again.",
      discard: "Sign in again")
    addScreenshot(named: "runtime-session-check-failed")

    retry.tap()
    XCTAssertTrue(restoring.appears(within: 2), "retrying showed no progress")
    XCTAssertTrue(filesRoot.appears(within: 15), "retry did not restore once the fault cleared")

    relaunch([Self.offlineOnce, Self.signInCancelsOnce])
    XCTAssertTrue(discard.appears(within: 15), "the session-check screen never appeared")
    XCTAssertEqual(discard.label, "Sign in again")
    discard.tap()
    assertFreshWelcome("Sign in again did not land on the fresh welcome")

    relaunch([])
    assertFreshWelcome("the removed credential was restored on relaunch")
  }

  private var retry: XCUIElement { element("auth.retry").firstMatch }
  private var discard: XCUIElement { element("auth.discard-credential").firstMatch }
  private var notice: XCUIElement { element("auth.notice").firstMatch }
  private var filesRoot: XCUIElement { element("files.screen.0").firstMatch }
  private var restoring: XCUIElement { app.staticTexts["Restoring your session"].firstMatch }

  private func relaunch(_ arguments: [String]) {
    app.terminate()
    let base = app.launchArguments.filter { !Self.faults.contains($0) }
    app.launchArguments = base + arguments
    app.launch()
  }

  private static let faults: Set<String> = [
    savedCredential, readFailsOnce, offlineOnce, clearFails, signInCancelsOnce,
  ]

  private func assertRecovery(
    title: String, message: String, discard discardTitle: String,
    file: StaticString = #filePath, line: UInt = #line
  ) {
    XCTAssertTrue(retry.appears(within: 15), "the recovery screen never appeared", file: file, line: line)
    XCTAssertEqual(retry.label, "Try again", file: file, line: line)
    XCTAssertEqual(discard.label, discardTitle, file: file, line: line)
    XCTAssertTrue(notice.label.contains(title), "missing \(title)", file: file, line: line)
    XCTAssertTrue(notice.label.contains(message), "missing \(message)", file: file, line: line)
    XCTAssertEqual(element("auth.welcome-title").label, "Welcome!", file: file, line: line)
    XCTAssertFalse(
      notice.label.contains("Signing in again removes the saved sign-in"),
      "the removed footnote is back", file: file, line: line)
  }

  private func assertFreshWelcome(
    _ message: String, file: StaticString = #filePath, line: UInt = #line
  ) {
    let signIn = element("auth.sign-in").firstMatch
    XCTAssertTrue(signIn.appears(within: 15), message, file: file, line: line)
    XCTAssertEqual(signIn.label, "Sign in", message, file: file, line: line)
    XCTAssertFalse(notice.exists, message, file: file, line: line)
    XCTAssertFalse(filesRoot.exists, message, file: file, line: line)
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
