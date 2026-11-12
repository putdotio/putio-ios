import XCTest

final class PublicLinksJourneyTests: XCTestCase {
  private var app: XCUIApplication!

  override func setUpWithError() throws {
    try super.setUpWithError()
    continueAfterFailure = false
    app = XCUIApplication()
    app.launchArguments = ["--putio-harness-scenario", "files-browser"]
  }

  func testRowsCopyShareAndRevokeByMenuAndSwipe() throws {
    openPublicLinks(mode: "journey")
    let blueLights = link(901)
    let sintel = link(902)
    let photo = link(903)
    let undated = link(905)
    let later = link(906)
    XCTAssertTrue(blueLights.appears(within: 10), "the links never loaded")
    XCTAssertTrue(sintel.exists)
    XCTAssertTrue(photo.exists)
    XCTAssertTrue(undated.exists)
    XCTAssertFalse(link(904).exists, "an expired link is listed")
    XCTAssertFalse(later.exists, "a link made after the list loaded is already listed")
    XCTAssertTrue(
      app.staticTexts["Anyone with a link can open the file for 72 hours"].exists,
      "the 72 hour rule is missing")
    XCTAssertTrue(app.staticTexts["Expires in 38 hours"].exists, "Sintel shows no expiry")
    XCTAssertTrue(app.staticTexts["Expires within 72 hours"].exists, "no fallback expiry")
    attach("runtime-public-links")

    let header = app.staticTexts["Anyone with a link can open the file for 72 hours"]
    header.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).press(
      forDuration: 0.05,
      thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.85)))
    XCTAssertTrue(later.appears(within: 10), "pull to refresh never reloaded the list")

    openMenu(sintel)
    XCTAssertTrue(menuItem("Share").exists, "the menu has no Share")
    XCTAssertTrue(menuItem("Revoke").exists, "the menu has no Revoke")
    menuItem("Copy link").tap()
    let pasteboard = element("harness.pasteboard")
    let url = "https://app.put.io/exclusive-access/Rt4vW8nZq1"
    let copied = XCTNSPredicateExpectation(
      predicate: NSPredicate(format: "value == %@", url), object: pasteboard)
    XCTAssertEqual(
      XCTWaiter.wait(for: [copied], timeout: 5), .completed, "Copy link copied nothing")
    XCTAssertFalse(
      (pasteboard.value as? String ?? "").contains("putio-harness-session-token"),
      "the copied link carries the account token")
    XCTAssertTrue(app.staticTexts["Copied to clipboard"].appears(within: 5), "no copied toast")

    openMenu(sintel)
    menuItem("Share").tap()
    let sheet = app.otherElements["ActivityListView"]
    XCTAssertTrue(sheet.appears(within: 10), "Share opened no share sheet")
    let close = sheet.buttons["Close"]
    if close.exists {
      close.tap()
    } else {
      app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.08)).tap()
    }
    if !sheet.disappears(within: 3) { sheet.swipeDown(velocity: .fast) }
    XCTAssertTrue(sheet.disappears(within: 5), "the share sheet stayed open")

    askToRevoke(sintel)
    XCTAssertTrue(
      app.staticTexts["Anyone who has the link to “Sintel.2010.1080p.mkv” loses access."].exists,
      "the revoke alert does not name the file")
    app.buttons["putio-alert.cancel"].tap()
    XCTAssertTrue(app.putioAlert("Revoke this link?").disappears(within: 5))
    XCTAssertTrue(sintel.exists, "Cancel removed the link")

    askToRevoke(sintel)
    confirmRevoke()
    XCTAssertTrue(
      app.staticTexts["Couldn’t revoke the link. Check your connection and try again."]
        .appears(within: 10), "a failed revoke said nothing")
    XCTAssertTrue(sintel.exists, "a failed revoke removed the row")
    attach("runtime-public-link-revoke-failed")

    askToRevoke(sintel)
    confirmRevoke()
    XCTAssertTrue(sintel.disappears(within: 10), "the revoked link stayed")

    blueLights.press(forDuration: 1.2)
    XCTAssertTrue(menuItem("Copy link").appears(within: 5), "long press opened no menu")
    app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.12)).tap()
    XCTAssertTrue(menuItem("Copy link").disappears(within: 5), "the menu stayed open")

    blueLights.swipeLeft()
    let swipeRevoke = app.buttons["public-links.swipe-revoke"]
    XCTAssertTrue(swipeRevoke.appears(within: 5), "swipe left shows no Revoke")
    swipeRevoke.tap()
    XCTAssertTrue(app.putioAlert("Revoke this link?").appears(within: 5), "swipe asked nothing")
    confirmRevoke()
    XCTAssertTrue(blueLights.disappears(within: 10), "the swiped link stayed")

    for remaining in [photo, undated, later] {
      askToRevoke(remaining)
      confirmRevoke()
      XCTAssertTrue(remaining.disappears(within: 10), "\(remaining) stayed after revoke")
    }
    XCTAssertTrue(
      element("public-links.empty").appears(within: 5), "the last revoke left no empty state")
    XCTAssertTrue(app.staticTexts["No exclusive links"].exists)
    attach("runtime-public-links-empty")

    app.navigationBars["Exclusive links"].buttons.element(boundBy: 0).tap()
    XCTAssertTrue(app.navigationBars["Account"].appears(within: 5))
    element("account.public-links").tap()
    XCTAssertTrue(element("public-links.empty").appears(within: 10), "reopening lost the revokes")
  }

  func testLeavingMidLoadLeavesNothingBehind() {
    openPublicLinks(mode: "slow")
    XCTAssertTrue(element("public-links.loading").appears(within: 5), "the list never loaded")
    XCTAssertTrue(app.staticTexts["Loading links…"].exists, "the loading line is missing")
    attach("runtime-public-links-loading")
    app.navigationBars["Exclusive links"].buttons.element(boundBy: 0).tap()
    XCTAssertTrue(app.navigationBars["Account"].appears(within: 5), "back never left the list")
    RunLoop.current.run(until: Date.now.addingTimeInterval(8))
    XCTAssertTrue(app.navigationBars["Account"].exists, "the late list moved off Account")
    XCTAssertFalse(app.navigationBars["Exclusive links"].exists, "the late list reopened")
    XCTAssertFalse(app.putioAlerts.firstMatch.exists, "the late list left an alert")
    XCTAssertFalse(link(901).exists, "the late list left a row")

    element("account.public-links").tap()
    XCTAssertTrue(element("public-links.loading").appears(within: 5), "reopening never reloaded")
    XCTAssertTrue(link(901).appears(within: 15), "the slow list never arrived")
  }

  func testFailedLoadRetries() {
    openPublicLinks(mode: "failing")
    let retry = app.buttons["public-links.retry"]
    XCTAssertTrue(retry.appears(within: 10), "the failed load offers no Try again")
    XCTAssertTrue(app.staticTexts["Couldn’t load this"].exists)
    XCTAssertTrue(app.staticTexts["Check your connection and try again."].exists)
    attach("runtime-public-links-failed")
    retry.tap()
    XCTAssertTrue(link(901).appears(within: 10), "Try again never loaded the links")
  }

  private func openPublicLinks(mode: String) {
    app.launchArguments += ["--putio-harness-public-links", mode]
    app.launch()
    let signIn = element("auth.sign-in")
    if signIn.appears(within: 10) { signIn.tap() }
    let account = app.buttons["Account"]
    XCTAssertTrue(account.appears(within: 10))
    account.tap()
    let row = element("account.public-links")
    XCTAssertTrue(row.appears(within: 10), "Account has no Exclusive links row")
    row.tap()
    XCTAssertTrue(
      app.navigationBars["Exclusive links"].appears(within: 5), "Exclusive links never opened")
  }

  private func openMenu(_ row: XCUIElement) {
    XCTAssertTrue(row.becomesHittable(within: 5), "\(row) is not tappable")
    row.tap()
    XCTAssertTrue(menuItem("Copy link").appears(within: 5), "a tap opened no menu")
  }

  private func askToRevoke(_ row: XCUIElement) {
    openMenu(row)
    menuItem("Revoke").tap()
    XCTAssertTrue(app.putioAlert("Revoke this link?").appears(within: 5), "Revoke asked nothing")
  }

  private func confirmRevoke() {
    app.buttons["confirm-alert.confirm"].tap()
    XCTAssertTrue(app.putioAlert("Revoke this link?").disappears(within: 5))
  }

  private func menuItem(_ title: String) -> XCUIElement {
    app.buttons.matching(NSPredicate(format: "label == %@", title)).firstMatch
  }

  private func link(_ id: Int) -> XCUIElement {
    element("public-links.item.\(id)")
  }

  private func element(_ identifier: String) -> XCUIElement {
    app.descendants(matching: .any)[identifier]
  }

  private func attach(_ name: String) {
    let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
    attachment.name = name
    attachment.lifetime = .keepAlways
    add(attachment)
  }
}
