import XCTest

extension XCUIApplication {
  var putioAlerts: XCUIElementQuery {
    descendants(matching: .any).matching(identifier: "putio-alert")
  }

  func putioAlert(_ title: String) -> XCUIElement {
    putioAlerts.matching(NSPredicate(format: "label == %@", title)).firstMatch
  }

  var resumePrompt: XCUIElement {
    putioAlerts.matching(NSPredicate(format: "label BEGINSWITH %@", "Resume from ")).firstMatch
  }

  func answerResumePrompt(
    startingOver: Bool = false, file: StaticString = #filePath, line: UInt = #line
  ) {
    let choice = buttons[startingOver ? "video.resume.start-over" : "video.resume.resume"]
      .firstMatch
    XCTAssertTrue(
      choice.waitForExistence(timeout: 15), "the video never asked where to start",
      file: file, line: line)
    choice.tap()
    XCTAssertTrue(
      resumePrompt.waitForNonExistence(timeout: 5), "the resume prompt stayed open",
      file: file, line: line)
  }

  /// Lazy List rows below the fold, such as the Account list's Sign out, are
  /// absent from the accessibility tree until scrolled into view. Bounded so
  /// a missing row still fails instead of scrolling forever.
  func revealed(_ identifier: String, maximumSwipes: Int = 6) -> XCUIElement {
    let target = descendants(matching: .any)[identifier]
    var swipes = 0
    while !target.appears(within: 3), swipes < maximumSwipes {
      swipeUp()
      swipes += 1
    }
    return target
  }

  func scrollDown(toHit element: XCUIElement, maximumSwipes: Int = 6) {
    var swipes = 0
    while !element.isHittable, swipes < maximumSwipes {
      swipeDown()
      swipes += 1
    }
  }

  func bringIntoView(_ element: XCUIElement, maximumSwipes: Int = 6) {
    var swipes = 0
    while !(element.exists && element.isHittable), swipes < maximumSwipes {
      if element.exists, element.frame.minY < frame.midY { swipeDown() } else { swipeUp() }
      swipes += 1
    }
  }

  func showTabBar() {
    scrollDown(toHit: buttons["Files"])
  }

  func sortChoice(_ title: String) -> XCUIElement {
    descendants(matching: .any).matching(
      NSPredicate(
        format: "label == %@ AND elementType IN %@", title,
        [
          XCUIElement.ElementType.button, .switch, .menuItem, .toggle,
        ].map { NSNumber(value: $0.rawValue) })
    ).firstMatch
  }

  /// Sign out asks once: an alert with no downloads, otherwise a dialog
  /// whose plain Sign out keeps them.
  func confirmSignOut(file: StaticString = #filePath, line: UInt = #line) {
    let confirm = buttons.matching(
      NSPredicate(
        format: "identifier IN %@", ["auth.sign-out-confirm", "confirm-alert.confirm"])
    ).firstMatch
    XCTAssertTrue(
      confirm.appears(within: 5), "sign out was not confirmed", file: file, line: line)
    confirm.tap()
  }
}
