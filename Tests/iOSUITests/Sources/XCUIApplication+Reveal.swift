import XCTest

extension XCUIApplication {
  /// Lazy List rows below the fold, such as the Account list's Sign out, are
  /// absent from the accessibility tree until scrolled into view. Bounded so
  /// a missing row still fails instead of scrolling forever.
  func revealed(_ identifier: String, maximumSwipes: Int = 3) -> XCUIElement {
    let target = descendants(matching: .any)[identifier]
    var swipes = 0
    while !target.waitForExistence(timeout: 3), swipes < maximumSwipes {
      swipeUp()
      swipes += 1
    }
    return target
  }
}
