import XCTest

extension XCUIApplication {
  var selectionActions: XCUIElement {
    buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "selection.action."))
      .firstMatch
  }

  func tabBarHides() -> Bool {
    buttons.matching(NSPredicate(format: "label == %@", "Account")).firstMatch
      .becomesUnhittable(within: 5)
  }
}
