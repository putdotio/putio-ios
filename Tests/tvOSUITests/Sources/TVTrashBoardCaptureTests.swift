import XCTest

final class TVTrashBoardCaptureTests: XCTestCase {
  private var app: XCUIApplication!
  private let remote = XCUIRemote.shared

  override func setUp() {
    continueAfterFailure = false
    app = XCUIApplication()
  }

  func testTrashListPanelAndDeleteBoards() {
    openTrash("board")
    XCTAssertTrue(focusRow(4302))
    capture("rd-tvos-trash-01-list")
    remote.press(.select)
    XCTAssertTrue(waitUntil(timeout: 5) { self.hasFocus("trash.panel.restore") })
    capture("rd-tvos-trash-02-panel-focus")
    XCTAssertTrue(focus("trash.panel.delete", moving: .down, limit: 3))
    remote.press(.select)
    XCTAssertTrue(app.buttons["trash.delete-confirm"].waitForExistence(timeout: 5))
    capture("rd-tvos-trash-04-delete")
  }

  func testTrashRestoredBoard() {
    openTrash("board")
    XCTAssertTrue(focusRow(4302))
    remote.press(.select)
    XCTAssertTrue(waitUntil(timeout: 5) { self.hasFocus("trash.panel.restore") })
    remote.press(.select)
    XCTAssertTrue(label(containing: "Restore started").waitForExistence(timeout: 5))
    capture("rd-tvos-trash-03-restored", after: 0)
  }

  func testTrashEmptyConfirmBoard() {
    openTrash("board")
    XCTAssertTrue(focus("trash.empty", moving: .up))
    remote.press(.select)
    XCTAssertTrue(app.buttons["trash.empty-confirm"].waitForExistence(timeout: 5))
    capture("rd-tvos-trash-05-empty-confirm")
  }

  func testTrashRestoreAllBoard() {
    openTrash("board")
    XCTAssertTrue(focus("trash.restore-all", moving: .up))
    remote.press(.select)
    XCTAssertTrue(
      waitUntil(timeout: 5) {
        self.label(containing: "Restore started").exists
          || self.label(containing: "Restore could not start").exists
      })
    capture("rd-tvos-trash-06-restore-all", after: 0)
  }

  func testTrashEmptyBoard() {
    openTrash("empty")
    XCTAssertTrue(element("trash.empty-state").waitForExistence(timeout: 10))
    capture("rd-tvos-trash-07-empty")
  }

  func testTrashLoadingBoard() {
    openTrash("slow", waitForList: false)
    XCTAssertTrue(waitUntil(timeout: 10) { self.app.activityIndicators.count > 0 })
    capture("rd-tvos-trash-08-loading")
  }

  func testTrashErrorBoard() {
    openTrash("failing", waitForList: false)
    XCTAssertTrue(element("trash.retry").waitForExistence(timeout: 10))
    capture("rd-tvos-trash-09-error")
  }

  func testTrashRestoreFailedBoard() {
    openTrash("restore-rejected")
    XCTAssertTrue(focusRow(4302))
    remote.press(.select)
    XCTAssertTrue(waitUntil(timeout: 5) { self.hasFocus("trash.panel.restore") })
    remote.press(.select)
    XCTAssertTrue(label(containing: "Restore could not start").waitForExistence(timeout: 5))
    capture("rd-tvos-trash-10-restore-failed", after: 0)
  }

  func testTrashMoreFailedBoard() {
    openTrash("more-failing")
    XCTAssertTrue(focus("trash.more-retry", moving: .down, limit: 20))
    capture("rd-tvos-trash-11-more-failed")
  }

  private func openTrash(_ mode: String, waitForList: Bool = true) {
    app.launchArguments = [
      "--putio-harness-scenario", "signed-in", "--putio-harness-trash", mode,
    ]
    app.launch()
    XCTAssertTrue(TVTabBar(app).open("Account"))
    remote.press(.down)
    XCTAssertTrue(focus("account.manage-trash", moving: .down, limit: 14))
    remote.press(.select)
    if waitForList {
      XCTAssertTrue(
        waitUntil(timeout: 15) {
          self.element("trash.item.4301").exists || self.element("trash.empty-state").exists
        })
    }
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

  private func focusRow(_ id: Int) -> Bool {
    focus("trash.item.\(id)", moving: .down, limit: 10)
      || focus("trash.item.\(id)", moving: .up, limit: 14)
  }

  private func focus(
    _ identifier: String, moving direction: XCUIRemote.Button, limit: Int = 10
  ) -> Bool {
    for _ in 0..<limit {
      if waitUntil(timeout: 0.75, { self.hasFocus(identifier) }) { return true }
      remote.press(direction)
    }
    return waitUntil(timeout: 1.5) { self.hasFocus(identifier) }
  }

  private func pause(_ seconds: TimeInterval) {
    RunLoop.current.run(until: Date().addingTimeInterval(seconds))
  }

  private func waitUntil(timeout: TimeInterval, _ condition: () -> Bool) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
      if condition() { return true }
      RunLoop.current.run(until: Date().addingTimeInterval(0.25))
    }
    return condition()
  }

  private func capture(_ name: String, after delay: TimeInterval = 1) {
    pause(delay)
    let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
    attachment.name = name
    attachment.lifetime = .keepAlways
    add(attachment)
  }
}
