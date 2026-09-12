import XCTest

extension XCUIApplication {
  /// Lazy List rows below the fold, such as the Account list's Sign out, are
  /// absent from the accessibility tree until scrolled into view.
  func revealed(_ identifier: String) -> XCUIElement {
    let target = descendants(matching: .any)[identifier]
    if !target.waitForExistence(timeout: 3) { swipeUp() }
    return target
  }
}
