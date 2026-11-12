import XCTest

extension XCUIElement {
  func scrollTextToEnd(revealing end: XCUIElement) {
    swipeUp(velocity: .fast)
    let thumb = coordinate(withNormalizedOffset: CGVector(dx: 0.995, dy: 0.14))
    let bottom = coordinate(withNormalizedOffset: CGVector(dx: 0.995, dy: 0.99))
    thumb.press(forDuration: 0.5, thenDragTo: bottom)
    var swipes = 0
    while !end.isHittable, swipes < 10 {
      swipeUp(velocity: .fast)
      swipes += 1
    }
  }
}
