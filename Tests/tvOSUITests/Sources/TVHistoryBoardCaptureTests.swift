import XCTest

final class TVHistoryBoardCaptureTests: XCTestCase {
  private var app: XCUIApplication!
  private let remote = XCUIRemote.shared

  override func setUp() {
    continueAfterFailure = false
    app = XCUIApplication()
  }

  func testHistoryListPanelAndFileGoneBoards() {
    openHistory("board")
    XCTAssertTrue(focusRow(907))
    capture("rd-tvos-hist-01-list")
    remote.press(.right)
    XCTAssertTrue(focus("history.panel.play", moving: .down, limit: 3))
    capture("rd-tvos-hist-02-panel-focus")
    remote.press(.left)
    XCTAssertTrue(focusRow(906))
    capture("rd-tvos-hist-03-transfer")
    XCTAssertTrue(focusRow(904))
    capture("rd-tvos-hist-04-failed-event")
    XCTAssertTrue(focusRow(901))
    remote.press(.select)
    XCTAssertTrue(label(containing: "File not found").waitForExistence(timeout: 5))
    capture("rd-tvos-hist-11-file-gone")
  }

  func testHistoryClearBoards() {
    openHistory("board")
    XCTAssertTrue(focus("history.clear", moving: .up))
    remote.press(.select)
    XCTAssertTrue(app.buttons["history.clear-confirm"].waitForExistence(timeout: 5))
    pause(1)
    capture("rd-tvos-hist-05-clear")
    XCTAssertTrue(selectModalButton("history.clear-confirm"))
    XCTAssertTrue(label(containing: "Couldn’t clear history").waitForExistence(timeout: 10))
    capture("rd-tvos-hist-10-clear-failed")
  }

  func testHistoryEmptyBoard() {
    openHistory("empty")
    XCTAssertTrue(element("history.empty").waitForExistence(timeout: 10))
    capture("rd-tvos-hist-06-empty")
  }

  func testHistoryLoadingBoard() {
    openHistory("slow", waitForList: false)
    XCTAssertTrue(waitUntil(timeout: 10) { self.app.activityIndicators.count > 0 })
    capture("rd-tvos-hist-07-loading")
  }

  func testHistoryErrorBoard() {
    openHistory("failing", waitForList: false)
    XCTAssertTrue(element("history.retry").waitForExistence(timeout: 10))
    capture("rd-tvos-hist-08-error")
  }

  func testHistoryMoreFailedBoard() {
    openHistory("more-fails")
    XCTAssertTrue(element("history.more-retry").waitForExistence(timeout: 15))
    XCTAssertTrue(focusRow(901))
    capture("rd-tvos-hist-09-more-failed")
  }

  private func openHistory(_ mode: String, waitForList: Bool = true) {
    app.launchArguments = [
      "--putio-harness-scenario", "signed-in", "--putio-harness-history", mode,
    ]
    app.launch()
    XCTAssertTrue(TVTabBar(app).open("History"))
    if waitForList {
      XCTAssertTrue(
        waitUntil(timeout: 15) {
          self.element("history.item.907").exists || self.element("history.item.905").exists
            || self.element("history.empty").exists
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
    focus("history.item.\(id)", moving: .down, limit: 10)
      || focus("history.item.\(id)", moving: .up, limit: 14)
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

  private func selectModalButton(_ identifier: String) -> Bool {
    let target = app.buttons[identifier]
    guard target.waitForExistence(timeout: 5) else { return false }
    pause(1)
    let goal = target.frame
    for _ in 0..<8 {
      let focused = app.buttons.matching(NSPredicate(format: "hasFocus == true")).firstMatch
      guard focused.exists else { return false }
      let current = focused.frame
      if abs(current.midX - goal.midX) < 4, abs(current.midY - goal.midY) < 4 {
        remote.press(.select)
        return waitUntil(timeout: 5) { !target.exists }
      }
      remote.press(goal.midY > current.midY ? .down : .up)
      pause(0.5)
    }
    return false
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
    pause(1)
    let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
    attachment.name = name
    attachment.lifetime = .keepAlways
    add(attachment)
  }
}
