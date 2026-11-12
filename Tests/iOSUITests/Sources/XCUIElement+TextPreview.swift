import XCTest

extension XCUIElement {
  func scrollTextToEnd(revealing end: XCUIElement) {
    let bottom = coordinate(withNormalizedOffset: CGVector(dx: 0.99, dy: 0.99))
    for thumbY in [0.16, 0.14, 0.18, 0.12] where !end.isOnScreen {
      swipeUp(velocity: .fast)
      coordinate(withNormalizedOffset: CGVector(dx: 0.99, dy: thumbY))
        .press(forDuration: 0.5, thenDragTo: bottom)
      var swipes = 0
      while !end.isOnScreen, swipes < 4 {
        swipeUp(velocity: .fast)
        swipes += 1
      }
    }
    let deadline = Date.now.addingTimeInterval(3)
    while !end.isOnScreen, Date.now < deadline {
      RunLoop.current.run(until: Date.now.addingTimeInterval(0.2))
    }
  }

  var isOnScreen: Bool {
    guard exists, !frame.isEmpty else { return false }
    return XCUIApplication().windows.firstMatch.frame.contains(frame)
  }
}
