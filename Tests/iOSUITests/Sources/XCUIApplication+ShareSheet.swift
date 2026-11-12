import XCTest

extension XCUIApplication {
  func openShareSheet(
    from control: XCUIElement, sharing name: String,
    file: StaticString = #filePath, line: UInt = #line
  ) -> XCUIElement {
    XCTAssertTrue(control.isEnabled, "Share is disabled for \(name)", file: file, line: line)
    let anchor = control.frame
    let anchorName = control.identifier
    control.tap()
    let sheet = otherElements["ActivityListView"]
    XCTAssertTrue(sheet.appears(within: 10), "no share sheet for \(name)", file: file, line: line)
    let labels = sheet.descendants(matching: .any)
    let item = labels.matching(NSPredicate(format: "label == %@", name)).firstMatch
    XCTAssertTrue(
      item.appears(within: 20), "the share sheet does not name \(name): \(sheet.debugDescription)",
      file: file, line: line)
    let several = labels.matching(
      NSPredicate(format: "label MATCHES[c] %@", "^[0-9]+ (items|documents|files|images|photos)$"))
    XCTAssertFalse(
      several.firstMatch.exists, "the share sheet lists more than one item: \(several.firstMatch)",
      file: file, line: line)
    XCTAssertFalse(
      labels.matching(NSPredicate(format: "label CONTAINS 'put.io'")).firstMatch.exists,
      "the share sheet shows a put.io link", file: file, line: line)
    if UIDevice.current.userInterfaceIdiom == .pad {
      assertAnchored(sheet, to: anchor, named: anchorName, file: file, line: line)
    }
    return sheet
  }

  func dismissShareSheet(_ sheet: XCUIElement, file: StaticString = #filePath, line: UInt = #line) {
    let close = sheet.buttons["Close"]
    if close.exists {
      close.tap()
    } else if UIDevice.current.userInterfaceIdiom == .pad {
      coordinate(withNormalizedOffset: CGVector(dx: 0.05, dy: 0.95)).tap()
    } else {
      coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.92)).tap()
    }
    XCTAssertTrue(
      sheet.disappears(within: 5), "the share sheet stayed open", file: file, line: line)
  }

  private func assertAnchored(
    _ sheet: XCUIElement, to anchor: CGRect, named anchorName: String, file: StaticString,
    line: UInt
  ) {
    let window = windows.firstMatch.frame
    let popover = sheet.frame
    let reach: CGFloat = 32
    let beside =
      popover.minY >= anchor.maxY - reach || popover.maxY <= anchor.minY + reach
    let aligned =
      anchor.midX >= popover.minX - reach && anchor.midX <= popover.maxX + reach
      || popover.midX >= anchor.minX && popover.midX <= anchor.maxX
    XCTAssertTrue(
      popover.width < window.width * 0.8 && beside && aligned,
      "the share sheet is not anchored to \(anchorName) at \(anchor): \(popover) in \(window)",
      file: file, line: line)
  }
}
