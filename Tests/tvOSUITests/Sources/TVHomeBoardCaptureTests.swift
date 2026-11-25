import XCTest

final class TVHomeBoardCaptureTests: XCTestCase {
  private var app: XCUIApplication!
  private let remote = XCUIRemote.shared
  private let cards = ["--putio-harness-continue-watching", "home"]
  private let pins = ["--putio-harness-pins", "home"]

  override func setUp() {
    continueAfterFailure = false
    app = XCUIApplication()
  }

  func testCardBoards() {
    launch(cards + pins)
    XCTAssertTrue(element("home.pinned.item.412").waitForExistence(timeout: 15))
    pause(1)
    capture("rd-tvos-home-01-launch")
    XCTAssertTrue(steer(to: "home.continue-watching.item.411"))
    pause(1)
    capture("rd-tvos-home-02-card")
    remote.press(.select, forDuration: 1.2)
    XCTAssertTrue(menuItem("Remove from Continue watching").waitForExistence(timeout: 5))
    pause(1)
    capture("rd-tvos-home-03-card-menu")
    remote.press(.menu)
    pause(1.5)
    XCTAssertTrue(steer(to: "home.pinned.item.410"))
    remote.press(.select, forDuration: 1.2)
    XCTAssertTrue(menuItem("Open").waitForExistence(timeout: 5))
    pause(1)
    capture("rd-tvos-home-04-pinned-menu")
  }

  func testNothingPinnedBoard() {
    launch(cards)
    XCTAssertTrue(element("home.pinned.empty").waitForExistence(timeout: 15))
    XCTAssertTrue(steer(to: "home.continue-watching.item.411"))
    pause(1)
    capture("rd-tvos-home-05-nothing-pinned")
  }

  func testEmptyBoard() {
    launch([])
    XCTAssertTrue(element("home.empty").waitForExistence(timeout: 15))
    pause(1)
    capture("rd-tvos-home-06-empty")
  }

  func testHistoryOffBoard() {
    launch(cards + pins + ["--putio-harness-history-disabled"])
    XCTAssertTrue(element("home.pinned.item.412").waitForExistence(timeout: 15))
    XCTAssertFalse(TVTabBar(app).item("History").exists)
    pause(1)
    capture("rd-tvos-home-07-history-off")
  }

  private func launch(_ arguments: [String]) {
    app.launchArguments = ["--putio-harness-scenario", "signed-in"] + arguments
    app.launch()
    XCTAssertTrue(TVTabBar(app).item("Home").waitForExistence(timeout: 20))
  }

  private func menuItem(_ title: String) -> XCUIElement {
    app.cells.containing(NSPredicate(format: "label == %@", title)).firstMatch
  }

  /// Moves focus to `identifier` by comparing the focused frame with the
  /// target's, entering the content from the tab bar first.
  private func steer(to identifier: String) -> Bool {
    let target = element(identifier)
    guard target.waitForExistence(timeout: 10) else { return false }
    for _ in 0..<12 {
      if waitUntil(timeout: 1, { self.hasFocus(identifier) }) { return true }
      let focused = app.descendants(matching: .any)
        .matching(NSPredicate(format: "hasFocus == true")).firstMatch
      guard focused.exists,
        !app.tabBars.buttons.matching(
          NSPredicate(format: "hasFocus == true")
        ).firstMatch.exists
      else {
        remote.press(.down)
        continue
      }
      let current = focused.frame
      let goal = target.frame
      if abs(current.midY - goal.midY) >= 40 {
        remote.press(goal.midY > current.midY ? .down : .up)
      } else {
        remote.press(goal.midX > current.midX ? .right : .left)
      }
    }
    return waitUntil(timeout: 1.5) { self.hasFocus(identifier) }
  }

  private func element(_ identifier: String) -> XCUIElement {
    app.descendants(matching: .any).matching(identifier: identifier).firstMatch
  }

  private func hasFocus(_ identifier: String) -> Bool {
    app.descendants(matching: .any)
      .matching(NSPredicate(format: "identifier == %@ AND hasFocus == true", identifier))
      .firstMatch.exists
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
