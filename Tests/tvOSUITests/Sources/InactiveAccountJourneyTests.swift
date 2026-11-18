import XCTest

final class InactiveAccountJourneyTests: XCTestCase {
  private var app: XCUIApplication!
  private let remote = XCUIRemote.shared

  override func setUp() {
    continueAfterFailure = false
    app = XCUIApplication()
    app.launchArguments = ["--putio-harness-scenario", "signed-in", "--putio-harness-tv-browse"]
    if let mediaBaseURL = ProcessInfo.processInfo.environment["PUTIO_HARNESS_MEDIA_BASE_URL"] {
      app.launchEnvironment["PUTIO_HARNESS_MEDIA_BASE_URL"] = mediaBaseURL
    }
  }

  func testInactiveOwnerSeesTheNoticeAndPlaybackSaysWhyUntilRenewal() {
    app.launchArguments += [
      "--putio-harness-account-inactive", "owner",
      "--putio-harness-account-renews-in-background",
    ]
    app.launch()

    let notice = element("account.inactive-notice")
    XCTAssertTrue(notice.waitForExistence(timeout: 15), "Home has no inactive notice")
    XCTAssertTrue(notice.label.contains("Your account has been deactivated"), notice.label)
    XCTAssertTrue(notice.label.contains("scheduled to be deleted in 12 days."), notice.label)
    XCTAssertFalse(notice.buttons.firstMatch.exists, "the notice offers an action")
    XCTAssertTrue(waitUntil(timeout: 5) { self.hasFocus("home.files") }, "the notice took focus")
    attach("runtime-tv-inactive-home")

    XCTAssertTrue(focus("home.account"))
    remote.press(.select)
    let accountNotice = element("account.status-notice")
    XCTAssertTrue(accountNotice.waitForExistence(timeout: 15), "Account has no inactive notice")
    XCTAssertTrue(accountNotice.label.contains("12 days."), accountNotice.label)
    XCTAssertTrue(element("account.proxy").exists, "the notice blocked Account")
    attach("runtime-tv-inactive-account")
    remote.press(.menu)

    XCTAssertTrue(notice.waitForExistence(timeout: 10))
    XCTAssertTrue(focus("home.files"))
    remote.press(.select)
    XCTAssertTrue(element("files.item.412").waitForExistence(timeout: 15), "browsing stopped")
    XCTAssertTrue(focus("files.item.412"))
    remote.press(.select)
    let playbackNotice = element("video.account-notice")
    let resume = element("video.resume.continue")
    XCTAssertTrue(
      waitUntil(timeout: 30) { playbackNotice.exists || resume.exists },
      "the refused video never settled")
    if resume.exists { remote.press(.select) }
    XCTAssertTrue(
      playbackNotice.waitForExistence(timeout: 30), "a refused stream did not show the notice")
    XCTAssertTrue(label(containing: "Your account has been deactivated").exists)
    XCTAssertTrue(label(containing: "scheduled to be deleted in 12 days.").exists)
    XCTAssertFalse(element("video.retry").exists, "the generic playback error still shows")
    attach("runtime-tv-inactive-playback")

    remote.press(.menu)
    XCTAssertTrue(element("files.item.412").waitForExistence(timeout: 10))
    remote.press(.menu)
    XCTAssertTrue(notice.waitForExistence(timeout: 10))

    remote.press(.home)
    XCTAssertTrue(app.wait(for: .runningBackground, timeout: 10), "the app never left")
    app.activate()
    XCTAssertTrue(app.wait(for: .runningForeground, timeout: 10), "the app never returned")
    XCTAssertTrue(
      waitUntil(timeout: 15) { !notice.exists }, "renewing did not clear the Home notice")
    attach("runtime-tv-inactive-renewed")
  }

  func testInactiveFamilyMemberSeesTheFamilyNoticeWithoutADate() {
    app.launchArguments += ["--putio-harness-account-inactive", "family"]
    app.launch()

    let notice = element("account.inactive-notice")
    XCTAssertTrue(notice.waitForExistence(timeout: 15), "Home has no family plan notice")
    XCTAssertTrue(notice.label.contains("Your family plan is no longer active."), notice.label)
    XCTAssertFalse(notice.label.contains("deleted"), "the family notice names a date")
    attach("runtime-tv-inactive-family")

    XCTAssertTrue(focus("home.account"))
    remote.press(.select)
    let accountNotice = element("account.status-notice")
    XCTAssertTrue(accountNotice.waitForExistence(timeout: 15), "Account has no family notice")
    XCTAssertTrue(
      accountNotice.label.contains("Your family plan is no longer active."), accountNotice.label)
  }

  func testActiveAccountSeesNoNotice() {
    app.launch()

    XCTAssertTrue(element("home.files").waitForExistence(timeout: 15))
    XCTAssertFalse(element("account.inactive-notice").exists, "an active account sees a notice")
    XCTAssertTrue(focus("home.account"))
    remote.press(.select)
    XCTAssertTrue(element("account.proxy").waitForExistence(timeout: 15))
    XCTAssertFalse(element("account.status-notice").exists, "Account shows an active notice")
  }

  private func element(_ identifier: String) -> XCUIElement {
    app.descendants(matching: .any).matching(identifier: identifier).firstMatch
  }

  private func label(containing text: String) -> XCUIElement {
    app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", text))
      .firstMatch
  }

  private func hasFocus(_ identifier: String) -> Bool {
    app.descendants(matching: .any)
      .matching(NSPredicate(format: "identifier == %@ AND hasFocus == true", identifier))
      .firstMatch.exists
  }

  private func focus(_ identifier: String) -> Bool {
    for direction in [XCUIRemote.Button.down, .up] {
      for _ in 0..<12 {
        if waitUntil(timeout: 0.75, { self.hasFocus(identifier) }) { return true }
        remote.press(direction)
      }
    }
    return waitUntil(timeout: 1.5) { self.hasFocus(identifier) }
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
