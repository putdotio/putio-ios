import XCTest

final class TVSearchBoardCaptureTests: XCTestCase {
  private var app: XCUIApplication!
  private let remote = XCUIRemote.shared

  override func setUp() {
    continueAfterFailure = false
    app = XCUIApplication()
  }

  func testSearchStartBoard() {
    let field = openSearch()
    XCTAssertTrue(element("search.start").waitForExistence(timeout: 10))
    pause(1)
    capture("rd-tvos-srch-01-start")
    field.typeText("blue velvet 4k")
    XCTAssertTrue(element("search.empty").waitForExistence(timeout: 10))
    pause(1)
    capture("rd-tvos-srch-07-none")
    field.typeText(
      String(repeating: XCUIKeyboardKey.delete.rawValue, count: 14)
        + "Night.of.the.Living.Dead.1968.1080p.BluRay.x264-GROUP")
    XCTAssertTrue(label(containing: "Night.of.the.Living").waitForExistence(timeout: 10))
    pause(1)
    capture("rd-tvos-srch-09-long-query")
  }

  func testSearchRecentAndResultBoards() {
    let field = openSearch(["--putio-harness-search-history", "seeded"])
    XCTAssertTrue(element("search.recent.tree rings").waitForExistence(timeout: 10))
    pause(1)
    capture("rd-tvos-srch-02-recent")
    XCTAssertTrue(focus("search.recent.sintel", moving: .down, limit: 8))
    remote.press(.select, forDuration: 1.2)
    XCTAssertTrue(menuItem("Remove from recent searches").waitForExistence(timeout: 5))
    pause(1)
    capture("rd-tvos-srch-03-recent-menu")
    remote.press(.menu)
    pause(1)

    XCTAssertTrue(focusKeyboard())
    field.typeText("harness")
    XCTAssertTrue(element("search.more-retry").waitForExistence(timeout: 10))
    XCTAssertTrue(focus("search.more-retry", moving: .down, limit: 6))
    remote.press(.select)
    XCTAssertTrue(element("search.item.411").waitForExistence(timeout: 10))
    XCTAssertTrue(focus("search.item.411", moving: .down, limit: 6))
    XCTAssertTrue(element("search.panel").waitForExistence(timeout: 5))
    pause(1)
    capture("rd-tvos-srch-05-results")
    remote.press(.right)
    XCTAssertTrue(focus("search.panel.play", moving: .up, limit: 6))
    pause(1)
    capture("rd-tvos-srch-06-result-actions")
  }

  func testSearchingBoard() {
    let field = openSearch(["--putio-harness-hold-search"])
    field.typeText("bunny")
    XCTAssertTrue(waitUntil(timeout: 10) { self.app.activityIndicators.count > 0 })
    pause(1)
    capture("rd-tvos-srch-04-searching")
  }

  func testOfflineBoard() {
    let field = openSearch([
      "--putio-harness-search-history", "seeded", "--putio-harness-search-offline",
    ])
    field.typeText("sintel")
    XCTAssertTrue(element("search.retry").waitForExistence(timeout: 10))
    XCTAssertTrue(focus("search.retry", moving: .down, limit: 6))
    pause(1)
    capture("rd-tvos-srch-08-offline")
  }

  private func openSearch(_ arguments: [String] = []) -> XCUIElement {
    app.launchArguments = ["--putio-harness-scenario", "signed-in"] + arguments
    app.launch()
    XCTAssertTrue(TVTabBar(app).open("Search"))
    let field = app.searchFields.firstMatch
    XCTAssertTrue(field.waitForExistence(timeout: 10))
    pause(1)
    for _ in 0..<3 {
      remote.press(.down)
      if app.keyboards.firstMatch.waitForExistence(timeout: 3) { break }
    }
    return field
  }

  private func focusKeyboard() -> Bool {
    let below = app.descendants(matching: .any).matching(
      NSPredicate(
        format:
          "hasFocus == true AND (identifier BEGINSWITH 'search.' OR identifier BEGINSWITH 'tab.')"
      )
    ).firstMatch
    for _ in 0..<8 {
      if waitUntil(timeout: 3, { self.focusIsSettled() }), !below.exists,
        app.keyboards.firstMatch.exists
      {
        return true
      }
      remote.press(.up)
      pause(0.5)
    }
    return focusIsSettled() && !below.exists && app.keyboards.firstMatch.exists
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

  private func focusIsSettled() -> Bool {
    app.descendants(matching: .any).matching(NSPredicate(format: "hasFocus == true"))
      .firstMatch.exists
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
