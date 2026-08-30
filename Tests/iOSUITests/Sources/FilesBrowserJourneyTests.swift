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

  func testRunnableAlphaLoop() {
    app.launch()

    let signIn = element(identifier: "auth.sign-in")
    XCTAssertTrue(signIn.waitForExistence(timeout: 10), "sign-in screen never appeared")
    let root = element(identifier: "files.screen.0")
    let folder = element(identifier: "files.item.410")
    XCTAssertTrue(
      element(identifier: "journey.capture-recording").waitForExistence(timeout: 30),
      "harness never signaled that journey recording started"
    )
    addScreenshot(named: "runtime-sign-in")

    XCTAssertTrue(signIn.isHittable, "sign-in action is not tappable")
    signIn.tap()
    XCTAssertTrue(root.waitForExistence(timeout: 10), "signed-in root browser never appeared")
    XCTAssertTrue(folder.isHittable, "seeded folder is not tappable after sign-in")

    app.terminate()
    app.launch()

    XCTAssertTrue(root.waitForExistence(timeout: 10), "persisted session did not restore")
    XCTAssertFalse(signIn.exists, "restored session returned to sign-in")
    XCTAssertTrue(folder.isHittable, "seeded folder is not tappable after restore")

    let unsupportedFile = app.staticTexts["Document.pdf"]
    XCTAssertTrue(unsupportedFile.exists, "unsupported file row is missing")
    XCTAssertEqual(unsupportedFile.elementType, .staticText)
    XCTAssertFalse(app.buttons["files.item.413"].exists)
    if unsupportedFile.isHittable {
      unsupportedFile.tap()
    }
    XCTAssertTrue(root.exists, "unsupported file selection left the browser")
    XCTAssertFalse(element(identifier: "files.selection").exists)

    folder.tap()

    let nested = element(identifier: "files.screen.410")
    let nestedFile = element(identifier: "files.item.411")
    XCTAssertTrue(nested.waitForExistence(timeout: 10), "nested browser never appeared")
    XCTAssertTrue(nestedFile.waitForExistence(timeout: 5), "seeded nested file never appeared")
    nestedFile.tap()
    let done = element(identifier: "video.done")
    XCTAssertTrue(done.waitForExistence(timeout: 5), "video screen never appeared")
    let loading = element(identifier: "video.loading")
    XCTAssertTrue(loading.waitForNonExistence(timeout: 5), "video source never resolved")
    XCTAssertFalse(
      element(identifier: "video.conversion-required").exists,
      "video unexpectedly requires conversion"
    )
    let playbackError = element(identifier: "video.error")
    XCTAssertTrue(
      playbackError.waitForExistence(timeout: 10),
      "malformed HLS fixture did not produce a recoverable playback failure"
    )
    let retry = app.buttons["Try again"]
    XCTAssertTrue(retry.isHittable, "playback retry is not tappable")
    retry.tap()
    XCTAssertTrue(
      element(identifier: "video.ready").waitForExistence(timeout: 10),
      "bundled HLS fixture never became ready"
    )
    XCTAssertFalse(playbackError.exists, "playback error remained after retry")
    addScreenshot(named: "runtime-playback")
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

    let account = app.buttons["Account"]
    XCTAssertTrue(account.isHittable, "Account tab is not tappable")
    account.tap()
    let signOut = element(identifier: "auth.sign-out")
    XCTAssertTrue(signOut.waitForExistence(timeout: 5), "sign-out action never appeared")
    XCTAssertTrue(signOut.isHittable, "sign-out action is not tappable")
    signOut.tap()

    XCTAssertTrue(signIn.waitForExistence(timeout: 10), "sign-out did not return to sign-in")
    addScreenshot(named: "runtime-signed-out")

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
