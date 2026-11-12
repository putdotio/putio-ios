import XCTest

final class SharedItemsJourneyTests: XCTestCase {
  private var app: XCUIApplication!
  private let video = "Tears.of.Steel.2012.mkv"

  override func setUpWithError() throws {
    try super.setUpWithError()
    continueAfterFailure = false
    XCUIDevice.shared.orientation = .portrait
    app = XCUIApplication()
    app.launchArguments = [
      "--putio-harness-scenario", "files-browser", "--putio-harness-shared-items",
      "--putio-harness-copy-results", "done,done,unconfirmed,concurrent,too-many",
    ]
    app.launchEnvironment["PUTIO_HARNESS_MEDIA_BASE_URL"] = try XCTUnwrap(
      ProcessInfo.processInfo.environment["PUTIO_HARNESS_MEDIA_BASE_URL"]
    )
  }

  func testSharedFoldersOfferNothingAndASharedFileCopiesIntoAnyFolder() {
    app.launch()
    let signIn = element("auth.sign-in")
    XCTAssertTrue(signIn.appears(within: 10))
    signIn.tap()
    XCTAssertTrue(element("files.screen.0").appears(within: 10))

    let sharedRoot = app.revealed("files.item.520", maximumSwipes: 12)
    XCTAssertTrue(sharedRoot.exists, "Items shared with you never appeared")
    assertNoActions(on: "files.item.520")
    sharedRoot.tap()
    XCTAssertTrue(element("files.item.522").appears(within: 10), "selin never appeared")
    assertNoActions(on: "files.item.521")
    addScreenshot(named: "shared-root")

    element("files.item.521").tap()
    XCTAssertTrue(element("files.item.524").appears(within: 10), "the shared video is missing")
    assertNoActions(on: "files.item.523")

    openMenu()
    XCTAssertTrue(app.buttons["Play"].exists, "the shared video cannot play")
    XCTAssertTrue(app.staticTexts["Shared by deniz"].exists, "the row never named deniz")
    for owned in ["Select", "Rename", "Move", "Move to trash", "Delete permanently"] {
      XCTAssertFalse(app.buttons[owned].exists, "a guest was offered \(owned)")
    }
    addScreenshot(named: "shared-file-menu")

    app.buttons["Make a copy"].tap()
    XCTAssertTrue(app.staticTexts["Copy 1 item"].appears(within: 5), "Copy never opened")
    XCTAssertTrue(element("files.move-folder.410").appears(within: 10), "Files lists no folders")
    XCTAssertFalse(
      element("files.move-folder.520").exists, "Items shared with you is offered as a target")
    addScreenshot(named: "shared-copy-sheet")
    copy(to: "Files")
    openMenu()
    XCTAssertFalse(
      app.buttons["Make a copy"].isEnabled, "a second copy could start while one runs")
    app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.08)).tap()
    expectToast("Copied “\(video)” to Files.")
    addScreenshot(named: "shared-copied")

    openMenu()
    app.buttons["Make a copy"].tap()
    let folder = element("files.move-folder.410")
    XCTAssertTrue(folder.appears(within: 10), "Harness Folder is not offered")
    folder.tap()
    XCTAssertTrue(
      element("files.move-screen.410").appears(within: 5), "Harness Folder never opened")
    copy(to: "Harness Folder")
    expectToast("Copied “\(video)” to Harness Folder.")

    copyFromMenu()
    expectToast("Couldn’t confirm the copy of “\(video)”. It may still show up in Files.")
    copyFromMenu()
    expectToast(
      "You’re already copying as much as put.io allows at once. Try again when that copy finishes."
    )
    copyFromMenu()
    expectToast("That’s too many files to copy at once.")
  }

  private func assertNoActions(on identifier: String) {
    let row = element(identifier)
    XCTAssertTrue(row.appears(within: 10), "\(identifier) never appeared")
    row.swipeLeft()
    XCTAssertFalse(
      element("item-swipe.more").shows(within: 2), "\(identifier) offered swipe actions")
    row.press(forDuration: 1)
    let actions = app.buttons.matching(
      NSPredicate(format: "identifier BEGINSWITH %@", "item-action.")
    ).firstMatch
    XCTAssertFalse(actions.shows(within: 2), "\(identifier) opened a menu")
    let opened = element(identifier.replacingOccurrences(of: "files.item.", with: "files.screen."))
    if opened.exists {
      app.navigationBars.buttons.firstMatch.tap()
      XCTAssertTrue(row.appears(within: 10), "\(identifier) never came back")
    }
  }

  private func openMenu() {
    let row = element("files.item.524")
    XCTAssertTrue(row.appears(within: 10), "the shared video is missing")
    row.press(forDuration: 1)
    XCTAssertTrue(app.buttons["Make a copy"].appears(within: 5), "the menu has no Make a copy")
  }

  private func copyFromMenu() {
    openMenu()
    app.buttons["Make a copy"].tap()
    XCTAssertTrue(app.staticTexts["Copy 1 item"].appears(within: 5), "Copy never opened")
    copy(to: "Files")
  }

  private func copy(to folder: String) {
    let button = app.buttons["Copy to \(folder)"]
    XCTAssertTrue(button.appears(within: 10), "Copy to \(folder) never enabled")
    button.tap()
    XCTAssertTrue(element("files.move-picker").disappears(within: 5), "the sheet stayed open")
  }

  private func expectToast(_ text: String) {
    XCTAssertTrue(app.staticTexts[text].appears(within: 15), "no toast: \(text)")
  }

  private func element(_ identifier: String) -> XCUIElement {
    app.descendants(matching: .any)[identifier]
  }

  private func addScreenshot(named name: String) {
    let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
    attachment.name = name
    attachment.lifetime = .keepAlways
    add(attachment)
  }
}
