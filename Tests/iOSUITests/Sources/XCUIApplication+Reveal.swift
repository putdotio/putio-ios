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

  var signedInShell: XCUIElement {
    tabBars.firstMatch
  }

  func signInIfAsked(within timeout: TimeInterval = 10) {
    let signIn = descendants(matching: .any)["auth.sign-in"]
    if signIn.appears(before: [signedInShell], within: timeout) { signIn.tap() }
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
  /// absent from the accessibility tree until scrolled into view. An absent
  /// row swipes after a short look, because waiting never brings it in.
  /// Bounded so a missing row still fails instead of scrolling forever.
  func revealed(
    _ identifier: String, maximumSwipes: Int = 6, swipingIn container: XCUIElement? = nil
  ) -> XCUIElement {
    let target = descendants(matching: .any)[identifier]
    var swipes = 0
    while !target.shows(within: 1), swipes < maximumSwipes {
      (container.flatMap { $0.exists ? $0 : nil } ?? self).swipeUp()
      swipes += 1
    }
    _ = target.appears(within: 3)
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

  func openTab(_ label: String, file: StaticString = #filePath, line: UInt = #line) {
    let tab = buttons.matching(NSPredicate(format: "label == %@", label)).firstMatch
    let search = searchFields.firstMatch
    let closeSearch = buttons["Close"].firstMatch
    if search.exists, closeSearch.appears(within: 3) {
      closeSearch.tap()
      _ = search.disappears(within: 5)
    }
    if tab.becomesHittable(within: 5), tab.appears(within: 3) {
      tab.tap()
      if tab.becomesSelected(within: 3) { return }
    }
    let selected = tabBars.buttons.matching(NSPredicate(format: "selected == true")).firstMatch
    if selected.exists, selected.label != label { selected.tap() }
    if tab.becomesHittable(within: 3), tab.appears(within: 3) {
      tab.tap()
      if tab.becomesSelected(within: 3) { return }
    }
    let toggle = buttons.matching(NSPredicate(format: "label CONTAINS[c] %@", "sidebar"))
      .firstMatch
    XCTAssertTrue(
      toggle.appears(within: 5), "the \(label) tab is out of reach and there is no sidebar",
      file: file, line: line)
    toggle.tap()
    let row = cells[label].firstMatch
    XCTAssertTrue(row.appears(within: 5), "the sidebar has no \(label)", file: file, line: line)
    row.tap()
    let storage = descendants(matching: .any)["shell.storage"]
    guard storage.becomesHittable(within: 3), storage.appears(within: 3), storage.isHittable
    else { return }
    toggle.tap()
    XCTAssertTrue(
      storage.becomesUnhittable(within: 5), "the tab sidebar did not close", file: file, line: line)
  }

  func tapToolbarItem(
    _ identifier: String, title: String, file: StaticString = #filePath, line: UInt = #line
  ) {
    let item = buttons[identifier].firstMatch
    let overflow = buttons.matching(
      NSPredicate(
        format: "identifier CONTAINS %@ OR (label == %@ AND identifier != %@)",
        "OverflowBarButtonItem", title, identifier)
    ).firstMatch
    let deadline = Date.now.addingTimeInterval(15 * XCUIElement.timeoutScale)
    while !item.isHittable, !overflow.isHittable, Date.now < deadline {
      _ = item.becomesHittable(within: 0.5)
    }
    if item.isHittable, item.appears(within: 3) { return item.tap() }
    XCTAssertTrue(overflow.isHittable, "the toolbar has no \(title)", file: file, line: line)
    _ = overflow.appears(within: 3)
    let opensMenu = overflow.identifier.contains("OverflowBarButtonItem")
    overflow.tap()
    guard opensMenu else { return }
    let entry = collectionViews.buttons[title].firstMatch
    XCTAssertTrue(entry.appears(within: 5), "the overflow has no \(title)", file: file, line: line)
    entry.tap()
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

  func submenuAction(
    _ title: String, in submenu: String, file: StaticString = #filePath, line: UInt = #line
  ) -> XCUIElement {
    let submenuID = "item-action.\(submenu.lowercased())-menu"
    let row = buttons.matching(
      NSPredicate(format: "identifier == %@ OR label == %@", submenuID, submenu)
    ).firstMatch
    XCTAssertTrue(
      row.appears(within: 5), "the menu has no \(submenu) submenu", file: file, line: line)
    row.tap()
    let matches = buttons.matching(
      NSPredicate(format: "label == %@ AND identifier != %@", title, submenuID))
    let child = matches.matching(NSPredicate(format: "identifier BEGINSWITH %@", "item-action."))
      .firstMatch
    let unnamed = matches.matching(
      NSPredicate(format: "NOT identifier BEGINSWITH %@", "item-action."))
    let shown = child.appears(within: 5, unless: "an unnamed \(title) shows") {
      unnamed.allElementsBoundByIndex.contains(where: \.isHittable)
    }
    if shown { return child }
    return matches.allElementsBoundByIndex.filter(\.isHittable)
      .max { $0.frame.minY < $1.frame.minY } ?? matches.firstMatch
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
