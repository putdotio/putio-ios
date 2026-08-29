import XCTest

final class FilesBrowserJourneyTests: XCTestCase {
  private var app: XCUIApplication!

  override func setUp() {
    super.setUp()
    continueAfterFailure = false
    app = XCUIApplication()
    app.launchArguments = [
      "--putio-harness-scenario",
      "files-browser",
    ]
  }

  func testRootNestedFolderAndNativeBack() {
    app.launch()

    let root = element(identifier: "files.screen.0")
    let folder = element(identifier: "files.item.410")
    XCTAssertTrue(root.waitForExistence(timeout: 15), "root browser never appeared")
    XCTAssertTrue(folder.waitForExistence(timeout: 5), "seeded folder never appeared")
    XCTAssertTrue(folder.isHittable, "seeded folder is not tappable")
    addScreenshot(named: "files-browser-root")

    folder.tap()

    let nested = element(identifier: "files.screen.410")
    let nestedFile = element(identifier: "files.item.411")
    XCTAssertTrue(nested.waitForExistence(timeout: 10), "nested browser never appeared")
    XCTAssertTrue(nestedFile.waitForExistence(timeout: 5), "seeded nested file never appeared")
    addScreenshot(named: "files-browser-nested")

    nestedFile.tap()
    XCTAssertTrue(nested.waitForExistence(timeout: 5), "file selection left the browser")
    XCTAssertTrue(nestedFile.isHittable, "selected file is no longer available")

    let navigationBar = app.navigationBars["Harness Folder"]
    XCTAssertTrue(navigationBar.waitForExistence(timeout: 5), "nested navigation bar is missing")
    let backButton = navigationBar.buttons["Files"]
    XCTAssertTrue(backButton.isHittable, "native Files back button is not tappable")
    backButton.tap()

    XCTAssertTrue(root.waitForExistence(timeout: 5), "root browser did not return")
    XCTAssertTrue(folder.isHittable, "root folder is not tappable after returning")
    XCTAssertFalse(nestedFile.isHittable, "nested content remains visible after returning")
    addScreenshot(named: "files-browser-back")
  }

  private func element(identifier: String) -> XCUIElement {
    app.descendants(matching: .any)[identifier]
  }

  private func addScreenshot(named name: String) {
    let attachment = XCTAttachment(screenshot: app.screenshot())
    attachment.name = name
    attachment.lifetime = .keepAlways
    add(attachment)
  }
}
