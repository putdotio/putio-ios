import XCTest

struct TVTabBar {
  let app: XCUIApplication
  private let remote = XCUIRemote.shared

  init(_ app: XCUIApplication) {
    self.app = app
  }

  func item(_ title: String) -> XCUIElement {
    app.tabBars.buttons[title]
  }

  private var focusedItem: XCUIElement {
    app.tabBars.buttons.matching(NSPredicate(format: "hasFocus == true")).firstMatch
  }

  func open(_ title: String, timeout: TimeInterval = 15) -> Bool {
    let target = item(title)
    guard target.waitForExistence(timeout: timeout) else { return false }
    for _ in 0..<12 where !waitUntil(1, { focusedItem.exists }) {
      remote.press(.up)
    }
    for _ in 0..<8 {
      let current = focusedItem
      guard current.exists else { return false }
      let label = current.label
      if label == target.label {
        return waitUntil(10) { target.isSelected }
      }
      remote.press(current.frame.midX < target.frame.midX ? .right : .left)
      _ = waitUntil(5) { focusedItem.exists && focusedItem.label != label }
    }
    return false
  }

  private func waitUntil(_ timeout: TimeInterval, _ condition: () -> Bool) -> Bool {
    let deadline = Date.now.addingTimeInterval(timeout)
    while Date.now < deadline {
      if condition() { return true }
      RunLoop.current.run(until: Date.now.addingTimeInterval(0.2))
    }
    return condition()
  }
}
