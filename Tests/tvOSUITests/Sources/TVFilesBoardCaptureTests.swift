import XCTest

final class TVFilesBoardCaptureTests: XCTestCase {
  private var app: XCUIApplication!
  private let remote = XCUIRemote.shared

  override func setUp() {
    continueAfterFailure = false
    app = XCUIApplication()
  }

  func testFilesListPanelSortAndTrashBoards() {
    openFiles()
    XCTAssertTrue(focus("files.item.412"))
    capture("rd-tvos-files-01-root")
    remote.press(.right)
    XCTAssertTrue(focus("files.panel.markUnwatched", moving: .down, limit: 6))
    capture("rd-tvos-files-03-panel-focus")
    remote.press(.left)

    XCTAssertTrue(focus("files.more-retry", moving: .down, limit: 16))
    capture("rd-tvos-files-08-more-failed")
    remote.press(.select)
    XCTAssertTrue(waitUntil(timeout: 10) { !self.element("files.more-retry").exists })

    XCTAssertTrue(focus("files.refresh", moving: .up, limit: 20))
    remote.press(.right)
    pause(1)
    remote.press(.select)
    XCTAssertTrue(menuItem("Z to A").waitForExistence(timeout: 5))
    pause(1)
    capture("rd-tvos-files-04-sort")
    remote.press(.menu)
    pause(1)

    XCTAssertTrue(panelAction("files.panel.trash", on: "files.item.412"))
    XCTAssertTrue(label(containing: "Could not move item to Trash").waitForExistence(timeout: 10))
    XCTAssertTrue(panelAction("files.panel.trash", on: "files.item.412"))
    XCTAssertTrue(label(containing: "Moved to trash").waitForExistence(timeout: 10))
    capture("rd-tvos-files-09-trashed")

    XCTAssertTrue(focus("files.item.410"))
    remote.press(.select)
    XCTAssertTrue(element("files.item.411").waitForExistence(timeout: 10))
    XCTAssertTrue(focus("files.item.411"))
    capture("rd-tvos-files-02-folder")
    remote.press(.menu)

    XCTAssertTrue(focus("files.item.423"))
    remote.press(.select)
    XCTAssertTrue(element("files.empty").waitForExistence(timeout: 10))
    pause(1)
    capture("rd-tvos-files-06-empty")
    remote.press(.menu)

    XCTAssertTrue(focus("files.item.424"))
    remote.press(.select)
    XCTAssertTrue(element("files.retry").waitForExistence(timeout: 10))
    XCTAssertTrue(focus("files.retry"))
    capture("rd-tvos-files-07-error")
  }

  func testFilesLoadingBoard() {
    openFiles(["--putio-harness-hold-root-listing"], waitForList: false)
    XCTAssertTrue(waitUntil(timeout: 10) { self.app.activityIndicators.count > 0 })
    pause(1)
    capture("rd-tvos-files-05-loading")
  }

  func testFilesPermanentDeleteBoard() {
    openFiles(["--putio-harness-trash-disabled"])
    XCTAssertTrue(panelAction("files.panel.trash", on: "files.item.412"))
    XCTAssertTrue(app.buttons["files.delete-confirm"].waitForExistence(timeout: 5))
    pause(1)
    capture("rd-tvos-files-10-delete")
  }

  private func openFiles(_ arguments: [String] = [], waitForList: Bool = true) {
    app.launchArguments =
      ["--putio-harness-scenario", "signed-in", "--putio-harness-tv-browse"] + arguments
    app.launch()
    XCTAssertTrue(TVTabBar(app).open("Files"))
    remote.press(.down)
    if waitForList {
      XCTAssertTrue(element("files.item.412").waitForExistence(timeout: 15))
    }
  }

  private func panelAction(_ action: String, on row: String) -> Bool {
    guard focus(row) else { return false }
    remote.press(.right)
    guard focus(action, moving: .down, limit: 8) || focus(action, moving: .up, limit: 8) else {
      return false
    }
    remote.press(.select)
    return true
  }

  private func menuItem(_ title: String) -> XCUIElement {
    app.cells.containing(NSPredicate(format: "label == %@", title)).firstMatch
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
    focus(identifier, moving: .down, limit: 14) || focus(identifier, moving: .up, limit: 20)
  }

  private func focus(
    _ identifier: String, moving direction: XCUIRemote.Button, limit: Int
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

  private func capture(_ name: String) {
    let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
    attachment.name = name
    attachment.lifetime = .keepAlways
    add(attachment)
  }
}
