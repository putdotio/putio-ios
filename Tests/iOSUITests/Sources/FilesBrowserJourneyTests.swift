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
    XCTAssertTrue(
      element(identifier: "journey.capture-recording").waitForExistence(timeout: 30),
      "harness never signaled that journey recording started"
    )
    XCTAssertTrue(root.exists, "capture started before the root browser appeared")
    XCTAssertTrue(folder.exists, "capture started before the seeded folder appeared")
    XCTAssertTrue(folder.isHittable, "seeded folder is not tappable")
    addScreenshot(named: "files-browser-root")

    folder.tap()

    let nested = element(identifier: "files.screen.410")
    let nestedFile = element(identifier: "files.item.411")
    XCTAssertTrue(nested.waitForExistence(timeout: 10), "nested browser never appeared")
    XCTAssertTrue(nestedFile.waitForExistence(timeout: 5), "seeded nested file never appeared")
    addScreenshot(named: "files-browser-nested")

    nestedFile.tap()
    let done = element(identifier: "video.done")
    XCTAssertTrue(done.waitForExistence(timeout: 5), "video screen never appeared")
    let loading = element(identifier: "video.loading")
    XCTAssertTrue(loading.waitForNonExistence(timeout: 5), "video source never resolved")
    XCTAssertFalse(element(identifier: "video.error").exists, "video source resolution failed")
    XCTAssertFalse(
      element(identifier: "video.conversion-required").exists,
      "video unexpectedly requires conversion"
    )
    XCTAssertTrue(
      element(identifier: "video.system-player").waitForExistence(timeout: 5),
      "system video player never attached"
    )
    XCTAssertTrue(done.isHittable, "video Done button is not tappable")
    done.tap()

    XCTAssertTrue(nested.waitForExistence(timeout: 5), "file selection left the browser")
    XCTAssertTrue(nestedFile.isHittable, "selected file is no longer available")
    let selection = element(identifier: "files.selection")
    XCTAssertEqual(selection.label, "Selected file route")
    XCTAssertEqual(selection.value as? String, "id=411;parent=410;kind=video")

    let navigationBar = app.navigationBars["Harness Folder"]
    XCTAssertTrue(navigationBar.waitForExistence(timeout: 5), "nested navigation bar is missing")
    let backButton = navigationBar.buttons["Files"]
    XCTAssertTrue(backButton.isHittable, "native Files back button is not tappable")
    backButton.tap()

    XCTAssertTrue(
      navigationBar.waitForNonExistence(timeout: 5),
      "native Back transition did not finish"
    )

    XCTAssertTrue(root.waitForExistence(timeout: 5), "root browser did not return")
    XCTAssertTrue(folder.isHittable, "root folder is not tappable after returning")
    XCTAssertFalse(nestedFile.isHittable, "nested content remains visible after returning")
    addScreenshot(named: "files-browser-back")

    let finishCapture = element(identifier: "journey.capture-finish")
    XCTAssertTrue(
      finishCapture.waitForExistence(timeout: 5),
      "app did not expose the journey finish action after returning to root"
    )
    XCTAssertTrue(finishCapture.isHittable, "journey finish action is not tappable")
    finishCapture.tap()

    XCTAssertTrue(
      element(identifier: "journey.capture-complete").waitForExistence(timeout: 5),
      "app did not finish the journey capture"
    )
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
