import XCTest

extension XCUIElement {
  func scrollTextToEnd(revealing end: XCUIElement) {
    let bottom = coordinate(withNormalizedOffset: CGVector(dx: 0.99, dy: 0.99))
    let barBottom = XCUIApplication().navigationBars.firstMatch.frame.maxY - frame.minY
    for thumbOffset in [32.0, 16, 48, 8, 64] where !end.isOnScreen {
      swipeUp(velocity: .fast)
      coordinate(withNormalizedOffset: CGVector(dx: 0.99, dy: 0))
        .withOffset(CGVector(dx: -2, dy: barBottom + thumbOffset))
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
