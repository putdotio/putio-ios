import XCTest

final class InactiveAccountJourneyTests: XCTestCase {
  private var app: XCUIApplication!

  override func setUpWithError() throws {
    try super.setUpWithError()
    continueAfterFailure = false
    XCUIDevice.shared.orientation = .portrait
    app = XCUIApplication()
    app.launchArguments = ["--putio-harness-scenario", "files-browser"]
    app.launchEnvironment["PUTIO_HARNESS_MEDIA_BASE_URL"] = try XCTUnwrap(
      ProcessInfo.processInfo.environment["PUTIO_HARNESS_MEDIA_BASE_URL"]
    )
  }

  func testNoticeShowsWhileInactiveAndClearsAfterRenewalOnReturn() {
    app.launchArguments += [
      "--putio-harness-account-inactive", "owner",
      "--putio-harness-account-renews-in-background",
    ]
    app.launch()
    signIn()

    let notice = element("account.inactive-notice")
    XCTAssertTrue(notice.appears(within: 10), "the inactive account has no notice")
    XCTAssertTrue(
      notice.label.contains("Your account has been deactivated"), "notice title: \(notice.label)")
    XCTAssertTrue(
      notice.label.contains("scheduled to be deleted in 12 days."),
      "notice message: \(notice.label)")
    XCTAssertTrue(element("files.item.410").exists, "the notice blocked the file list")
    XCTAssertFalse(
      notice.buttons.firstMatch.exists, "the notice offers an action")
    addScreenshot(named: "runtime-inactive-notice")

    element("files.item.410").tap()
    XCTAssertTrue(
      element("files.screen.410").appears(within: 10), "browsing stopped while inactive")
    XCTAssertFalse(
      element("account.inactive-notice").exists, "the notice left the Files root")
    app.navigationBars.buttons.firstMatch.tap()
    XCTAssertTrue(notice.appears(within: 10), "the notice did not return with the root")

    XCUIDevice.shared.press(.home)
    XCTAssertTrue(
      app.wait(for: .runningBackground, timeout: 10), "the app never left the foreground")
    app.activate()
    XCTAssertTrue(
      app.wait(for: .runningForeground, timeout: 10), "the app never returned")
    XCTAssertTrue(
      notice.disappears(within: 10), "renewing did not clear the notice on return")
    XCTAssertTrue(element("files.item.410").exists)
    addScreenshot(named: "runtime-inactive-renewed")
    signOut()
  }

  func testFamilyMemberSeesTheFamilyPlanNoticeWithoutADate() {
    app.launchArguments += ["--putio-harness-account-inactive", "family"]
    app.launch()
    signIn()

    let notice = element("account.inactive-notice")
    XCTAssertTrue(notice.appears(within: 10), "the inactive family member has no notice")
    XCTAssertTrue(
      notice.label.contains("Your family plan is no longer active."),
      "notice: \(notice.label)")
    XCTAssertFalse(notice.label.contains("deleted"), "the family notice names a deletion date")
    signOut()
  }

  func testActiveAccountSeesNoNotice() {
    app.launch()
    signIn()
    XCTAssertTrue(element("files.item.410").appears(within: 10))
    XCTAssertFalse(element("account.inactive-notice").exists, "an active account sees a notice")
    signOut()
  }

  private func signIn() {
    let signIn = element("auth.sign-in")
    XCTAssertTrue(signIn.appears(within: 10))
    signIn.tap()
    XCTAssertTrue(element("files.screen.0").appears(within: 10))
  }

  private func signOut() {
    app.buttons["Account"].tap()
    let signOut = app.revealed("auth.sign-out")
    XCTAssertTrue(signOut.appears(within: 5))
    signOut.tap()
    app.confirmSignOut()
    XCTAssertTrue(element("auth.sign-in").appears(within: 10))
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
