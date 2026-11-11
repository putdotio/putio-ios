import XCTest

final class SelectionGalleryTests: XCTestCase {
  private var app: XCUIApplication!

  override func setUpWithError() throws {
    try super.setUpWithError()
    continueAfterFailure = false
    XCUIDevice.shared.orientation = .portrait
    app = XCUIApplication()
    app.launchArguments = [
      "--putio-harness-scenario", "gallery", "--putio-harness-gallery-page", "selection-none",
    ]
  }

  func testSelectionHeaderAndBarReplaceTheTabBarUntilClosed() {
    app.launch()

    let count = element("selection.count")
    XCTAssertTrue(count.appears(within: 15), "the selection gallery never appeared")
    close()

    let select = element("gallery.selection.select")
    XCTAssertTrue(select.appears(within: 5), "the Select button is missing")
    select.tap()
    XCTAssertTrue(count.appears(within: 5), "Select did not enter selection")
    XCTAssertEqual(count.label, "0 selected")
    assertTabBarHidden()
    XCTAssertTrue(element("selection.bar").exists, "the action bar is missing")
    XCTAssertFalse(action("trash").isEnabled, "actions are enabled with nothing selected")
    XCTAssertFalse(
      app.buttons["Pause download, Sintel.2010.1080p.mkv"].exists,
      "the trailing download control stayed visible in selection")

    row(0).tap()
    row(3).tap()
    XCTAssertEqual(count.label, "2 selected")
    XCTAssertTrue(row(0).isSelected, "the first tapped row is not selected")
    XCTAssertTrue(row(3).isSelected, "the second tapped row is not selected")
    XCTAssertTrue(action("trash").isEnabled, "actions stay disabled with rows selected")
    XCTAssertEqual(toggleAll().label, "Select all")
    attachScreenshot(named: "selection-mode-some")

    toggleAll().tap()
    XCTAssertEqual(count.label, "9 selected")
    XCTAssertEqual(toggleAll().label, "Select all")
    attachScreenshot(named: "selection-mode-all")

    action("trash").tap()
    XCTAssertEqual(
      app.staticTexts["gallery.selection.reported-action"].label, "Last action: trash 9")

    close()
    select.tap()
    XCTAssertTrue(count.appears(within: 5))
    XCTAssertEqual(count.label, "0 selected", "closing did not clear the selection")
    close()
  }

  private func close() {
    let close = element("selection.close")
    XCTAssertTrue(close.appears(within: 5), "the close button is missing")
    close.tap()
    XCTAssertTrue(element("selection.count").disappears(within: 5), "close did not end selection")
    XCTAssertFalse(element("selection.bar").exists, "the action bar outlived the selection")
    XCTAssertTrue(
      tabButton("Downloads").becomesHittable(within: 5), "the tab bar did not come back")
  }

  private func assertTabBarHidden() {
    XCTAssertTrue(
      tabButton("Downloads").becomesUnhittable(within: 5), "the tab bar stayed visible")
  }

  private func row(_ index: Int) -> XCUIElement {
    app.buttons["gallery.selection.row.\(index)"]
  }

  private func action(_ id: String) -> XCUIElement {
    app.buttons["selection.action.\(id)"]
  }

  private func toggleAll() -> XCUIElement {
    app.buttons["selection.toggle-all"]
  }

  private func tabButton(_ label: String) -> XCUIElement {
    app.buttons.matching(NSPredicate(format: "label == %@", label)).firstMatch
  }

  private func element(_ identifier: String) -> XCUIElement {
    app.descendants(matching: .any)[identifier]
  }

  private func attachScreenshot(named name: String) {
    let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
    attachment.name = name
    attachment.lifetime = .keepAlways
    add(attachment)
  }
}
