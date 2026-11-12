import XCTest

extension XCUIElement {
  func scrollTextToEnd(revealing end: XCUIElement) {
    coordinate(withNormalizedOffset: CGVector(dx: 0.1, dy: 0.3)).doubleTap()
    typeKey(.downArrow, modifierFlags: .command)
    var swipes = 0
    while !end.isHittable, swipes < 40 {
      swipeUp(velocity: .fast)
      swipes += 1
    }
    coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.2)).tap()
  }
}
