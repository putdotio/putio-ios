import XCTest

final class ItemActionsGalleryTests: XCTestCase {
  private var app: XCUIApplication!

  private let boardMenu = [
    "Play", "Play with Direct play", "Download", "Download with Direct play", "Share",
    "Select", "Pin", "Mark as unwatched",
    "Rename", "Move", "Exclusive link",
    "Move to trash",
  ]

  override func setUpWithError() throws {
    try super.setUpWithError()
    continueAfterFailure = false
    app = XCUIApplication()
  }

  func testLongPressAndSwipeMoreListTheSameItemsInOrder() {
    launch(page: "menus")
    let row = element("gallery.menus.row.1")
    XCTAssertTrue(row.appears(within: 10), "gallery Menus page never appeared")

    row.press(forDuration: 1)
    let longPressItems = menuItems()
    XCTAssertEqual(longPressItems, boardMenu)
    addScreenshot(named: "item-menu-long-press")
    app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.04)).tap()
    XCTAssertTrue(
      app.buttons["Play"].firstMatch.disappears(within: 5), "long-press menu never closed")

    row.swipeLeft()
    let more = swipeMore(beside: row)
    XCTAssertTrue(more.appears(within: 5), "swipe actions never showed More")
    more.tap()
    let swipeItems = menuItems()
    XCTAssertEqual(swipeItems, longPressItems)
    addScreenshot(named: "item-menu-swipe-more")

    app.buttons["Rename"].firstMatch.tap()
    XCTAssertTrue(
      reported(equals: "Last action: Rename Blue.Lights.S04E02.1080p.HDTV.H264-ORGANiC.mkv"),
      "the swipe More menu did not run its item's action")
  }

  func testTextAlertFailureClosesAndTryAgainResendsTheSameName() {
    launch(page: "text-alert")
    let alert = app.alerts["Rename"]
    XCTAssertTrue(alert.appears(within: 10), "rename alert never appeared")
    let field = alert.textFields.firstMatch
    let submit = alert.buttons["Rename"]
    XCTAssertEqual(field.value as? String, "Blue.Lights.S04E01.en.srt")
    XCTAssertFalse(submit.isEnabled, "submit is enabled for an unchanged name")
    XCTAssertTrue(app.keyboards.firstMatch.appears(within: 5), "the name field never took focus")

    app.typeText("Blue.Lights.S04E01.de")
    let renamed = "Blue.Lights.S04E01.de.srt"
    XCTAssertEqual(field.value as? String, renamed, "typing did not replace the selected stem")
    XCTAssertTrue(submit.isEnabled, "submit stayed disabled for a new name")

    submit.tap()
    XCTAssertTrue(alert.disappears(within: 5), "the alert stayed open after submit")
    XCTAssertTrue(app.staticTexts["Couldn’t rename."].appears(within: 5), "no failure toast")
    let tryAgain = app.buttons["Try again"]
    XCTAssertTrue(tryAgain.appears(within: 5), "the failure toast offers no Try again")
    XCTAssertTrue(reported(equals: "Sent: \(renamed)"))
    addScreenshot(named: "text-alert-failure-toast")

    tryAgain.tap()
    XCTAssertTrue(reported(equals: "Sent: \(renamed), \(renamed)"), "Try again sent another name")
    XCTAssertTrue(app.buttons["Try again"].appears(within: 5), "the retry failure has no toast")
  }

  private func launch(page: String) {
    app.launchArguments = [
      "--putio-harness-scenario", "gallery", "--putio-harness-gallery-page", page,
    ]
    app.launch()
  }

  private func menuItems() -> [String] {
    let first = app.buttons[boardMenu[0]].firstMatch
    XCTAssertTrue(first.appears(within: 5), "item menu never opened")
    let items = app.buttons.matching(NSPredicate(format: "label IN %@", boardMenu))
    return items.allElementsBoundByIndex
      .sorted { $0.frame.minY < $1.frame.minY }
      .map(\.label)
  }

  private func swipeMore(beside row: XCUIElement) -> XCUIElement {
    let identified = app.buttons["item-swipe.more"].firstMatch
    if identified.appears(within: 2) { return identified }
    let labelled = app.buttons.matching(
      NSPredicate(format: "label == %@ AND identifier != %@", "More", "gallery.menus.more"))
    return labelled.allElementsBoundByIndex.first { abs($0.frame.midY - row.frame.midY) < 30 }
      ?? labelled.firstMatch
  }

  private func reported(equals text: String) -> Bool {
    let label = element("gallery.actions.reported")
    let expectation = XCTNSPredicateExpectation(
      predicate: NSPredicate(format: "label == %@", text), object: label)
    return XCTWaiter().wait(for: [expectation], timeout: 5) == .completed
  }

  private func element(_ identifier: String) -> XCUIElement {
    app.descendants(matching: .any)[identifier].firstMatch
  }

  private func addScreenshot(named name: String) {
    let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
    attachment.name = name
    attachment.lifetime = .keepAlways
    add(attachment)
  }
}
