import XCTest

extension XCUIElement {
  func scrollTextToEnd(revealing end: XCUIElement) {
    swipeUp(velocity: .fast)
    let thumb = coordinate(withNormalizedOffset: CGVector(dx: 0.995, dy: 0.14))
    let bottom = coordinate(withNormalizedOffset: CGVector(dx: 0.995, dy: 0.99))
    thumb.press(forDuration: 0.5, thenDragTo: bottom)
    var swipes = 0
    while !end.isOnScreen, swipes < 10 {
      swipeUp(velocity: .fast)
      swipes += 1
    }
  }

  var isOnScreen: Bool {
    guard exists, !frame.isEmpty else { return false }
    return XCUIApplication().windows.firstMatch.frame.contains(frame)
  }
}
