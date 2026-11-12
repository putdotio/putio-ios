import XCTest

final class ExclusiveLinkJourneyTests: XCTestCase {
  private var app: XCUIApplication!

  override func setUpWithError() throws {
    try super.setUpWithError()
    continueAfterFailure = false
    app = XCUIApplication()
    app.launchArguments = ["--putio-harness-scenario", "files-browser"]
  }

  func testLinksForAFileAndAFolderCopyShareAndShowUpInAccount() {
    launch(create: "ready")
    openSeasonFolder()
    openSheet(for: "files.item.442")
    XCTAssertTrue(app.staticTexts["Exclusive access"].exists, "the sheet has no title")
    XCTAssertTrue(
      element("files.exclusive-link.body").label.hasPrefix(
        "Anyone with a link can open Blue.Lights.S04E02.1080p.HDTV.H264-ORGANiC.mkv."),
      "the body does not name the file")
    app.buttons["files.exclusive-link.create"].tap()
    XCTAssertTrue(created.appears(within: 10), "the link was never created")
    XCTAssertTrue(app.staticTexts["Expires within 72 hours"].exists, "the link shows no expiry")
    XCTAssertEqual(
      element("files.exclusive-link.address").label, "app.put.io/exclusive-access/8f3KxQ2mVt71")
    attach("runtime-exclusive-link-created")

    app.buttons["files.exclusive-link.copy"].tap()
    let pasteboard = element("harness.pasteboard")
    let copied = XCTNSPredicateExpectation(
      predicate: NSPredicate(
        format: "value == %@", "https://app.put.io/exclusive-access/8f3KxQ2mVt71"),
      object: pasteboard)
    XCTAssertEqual(
      XCTWaiter.wait(for: [copied], timeout: 5), .completed, "Copy link copied nothing")
    XCTAssertTrue(app.staticTexts["Link copied"].appears(within: 5), "no copied toast")

    app.buttons["files.exclusive-link.share"].tap()
    let activity = app.otherElements["ActivityListView"]
    XCTAssertTrue(activity.appears(within: 10), "Share opened no share sheet")
    let close = activity.buttons["Close"]
    if close.exists {
      close.tap()
    } else {
      app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.08)).tap()
    }
    if !activity.disappears(within: 3) { activity.swipeDown(velocity: .fast) }
    XCTAssertTrue(activity.disappears(within: 5), "the share sheet stayed open")
    XCTAssertTrue(created.exists, "closing the share sheet closed Exclusive access")
    closeSheet()

    app.navigationBars.buttons["BackButton"].tap()
    openSheet(for: "files.item.440")
    XCTAssertTrue(
      element("files.exclusive-link.body").label.hasPrefix(
        "Anyone with a link can open Blue Lights."),
      "the body does not name the folder")
    app.buttons["files.exclusive-link.create"].tap()
    XCTAssertTrue(created.appears(within: 10), "the folder link was never created")
    XCTAssertEqual(
      element("files.exclusive-link.address").label, "app.put.io/exclusive-access/8f3KxQ2mVt72")
    closeSheet()

    app.buttons["Account"].tap()
    let row = app.revealed("account.public-links")
    XCTAssertTrue(row.appears(within: 10), "Account has no Exclusive links row")
    row.tap()
    XCTAssertTrue(element("public-links.item.951").appears(within: 10), "the file link is missing")
    XCTAssertTrue(element("public-links.item.952").exists, "the folder link is missing")
    attach("runtime-exclusive-link-account")
    app.navigationBars["Exclusive links"].buttons.element(boundBy: 0).tap()
    signOut()
  }

  func testEveryRefusalNamesItsReasonAndCreateLinkTriesAgain() {
    launch(create: "refusals")
    openSeasonFolder()
    openSheet(for: "files.item.442")
    let reasons = [
      "You can’t create public links with your current plan.",
      "This file type can’t be shared.",
      "You have reached the limit of your public links. You’ll have to revoke some under Account, Exclusive access, if you want to make more.",
      "This folder is too big to share.",
      "This folder contains too many files to share.",
      "You have reached the daily public link creation limit.",
      "You have reached the weekly public link creation limit.",
    ]
    for reason in reasons {
      app.buttons["files.exclusive-link.create"].tap()
      let shown = app.staticTexts.matching(NSPredicate(format: "label == %@", reason)).firstMatch
      XCTAssertTrue(shown.appears(within: 10), "no refusal: \(reason)")
      XCTAssertEqual(app.buttons["files.exclusive-link.create"].label, "Create link")
      if reason == reasons[0] { attach("runtime-exclusive-link-refused") }
    }
    app.buttons["files.exclusive-link.create"].tap()
    XCTAssertTrue(created.appears(within: 10), "Create link after the refusals created nothing")
    closeSheet()
    signOut()
  }

  func testAFailureOffersTryAgain() {
    launch(create: "failing")
    openSeasonFolder()
    openSheet(for: "files.item.442")
    app.buttons["files.exclusive-link.create"].tap()
    XCTAssertTrue(
      app.staticTexts["Couldn’t create a link. Check your connection and try again."]
        .appears(within: 10), "the failure said nothing")
    let retry = app.buttons["files.exclusive-link.create"]
    XCTAssertEqual(retry.label, "Try again")
    attach("runtime-exclusive-link-failed")
    retry.tap()
    XCTAssertTrue(created.appears(within: 10), "Try again created nothing")
    closeSheet()
    signOut()
  }

  func testClosingWhileCreatingCancels() {
    launch(create: "slow")
    openSeasonFolder()
    openSheet(for: "files.item.442")
    app.buttons["files.exclusive-link.create"].tap()
    XCTAssertTrue(app.staticTexts["Creating link…"].appears(within: 5), "creation never started")
    attach("runtime-exclusive-link-creating")
    closeSheet()
    openSheet(for: "files.item.442")
    XCTAssertEqual(
      app.buttons["files.exclusive-link.create"].label, "Create link",
      "reopening kept the cancelled request")
    XCTAssertFalse(app.staticTexts["Creating link…"].exists)
    closeSheet()
    signOut()
  }

  private var created: XCUIElement { element("files.exclusive-link.created") }

  private func launch(create mode: String) {
    app.launchArguments += ["--putio-harness-public-link-create", mode]
    app.launch()
  }

  private func openSeasonFolder() {
    let signIn = element("auth.sign-in")
    let harness = element("files.item.410")
    let seasonRow = element("files.item.440")
    let season = element("files.screen.440")
    let deadline = Date.now.addingTimeInterval(15)
    while !signIn.exists, !harness.exists, !seasonRow.exists, !season.exists, Date.now < deadline {
      _ = season.appears(within: 0.5)
    }
    if signIn.exists { signIn.tap() }
    if !season.exists {
      if !seasonRow.exists {
        XCTAssertTrue(harness.becomesHittable(within: 10), "the seeded folder never appeared")
        harness.tap()
      }
      XCTAssertTrue(seasonRow.becomesHittable(within: 10), "the season folder never appeared")
      seasonRow.tap()
    }
    XCTAssertTrue(element("files.item.442").appears(within: 10), "the episodes never appeared")
  }

  private func openSheet(for identifier: String) {
    let row = element(identifier)
    XCTAssertTrue(row.becomesHittable(within: 10), "\(identifier) is not tappable")
    row.press(forDuration: 1)
    let action = app.buttons["Exclusive link"].firstMatch
    XCTAssertTrue(action.appears(within: 5), "the item menu has no Exclusive link")
    action.tap()
    XCTAssertTrue(
      app.buttons["files.exclusive-link.create"].appears(within: 5), "Exclusive link never opened")
  }

  private func signOut() {
    app.buttons["Account"].tap()
    let signOut = app.revealed("auth.sign-out")
    XCTAssertTrue(signOut.appears(within: 5), "sign-out action never appeared")
    if !signOut.isHittable { app.swipeUp() }
    XCTAssertTrue(signOut.becomesHittable(within: 5), "sign-out action is not tappable")
    signOut.tap()
    app.confirmSignOut()
    XCTAssertTrue(element("auth.sign-in").appears(within: 10), "sign-out never finished")
  }

  private func closeSheet() {
    let sheet = element("files.exclusive-link")
    sheet.swipeDown(velocity: .fast)
    if !sheet.disappears(within: 3) {
      app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.1)).tap()
    }
    XCTAssertTrue(sheet.disappears(within: 5), "Exclusive access stayed open")
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
