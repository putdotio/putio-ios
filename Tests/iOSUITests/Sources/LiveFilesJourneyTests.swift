import XCTest

/// Signs in to the devs-auto put.io account, opens the harness fixture folder
/// and its image, and signs out. Only `journey --scenario live-files-browser`
/// runs it: the harness provisions the fixture and approves the device code
/// the app reports while this test waits.
final class LiveFilesJourneyTests: XCTestCase {
  func testSignInOpenFixtureFolderPreviewAndSignOut() throws {
    let environment = ProcessInfo.processInfo.environment
    try XCTSkipUnless(
      environment["PUTIO_HARNESS_LIVE"] == "1", "live journeys run only from the harness")
    let folderID = try XCTUnwrap(environment["PUTIO_HARNESS_LIVE_FOLDER_ID"])
    let fileID = try XCTUnwrap(environment["PUTIO_HARNESS_LIVE_FILE_ID"])
    continueAfterFailure = false
    let app = XCUIApplication()
    app.launchArguments = ["--putio-harness-scenario", "live"]
    app.launch()

    let signIn = app.descendants(matching: .any)["auth.sign-in"]
    XCTAssertTrue(signIn.waitForExistence(timeout: 15), "sign-in screen never appeared")
    signIn.tap()
    let root = app.descendants(matching: .any)["files.screen.0"]
    XCTAssertTrue(root.waitForExistence(timeout: 180), "the approved device code never signed in")
    attach("live-signed-in")

    let folder = app.revealed("files.item.\(folderID)", maximumSwipes: 8)
    XCTAssertTrue(folder.waitForExistence(timeout: 5), "fixture folder is not in the root listing")
    folder.tap()
    XCTAssertTrue(
      app.descendants(matching: .any)["files.screen.\(folderID)"].waitForExistence(timeout: 20))
    let file = app.descendants(matching: .any)["files.item.\(fileID)"]
    XCTAssertTrue(file.waitForExistence(timeout: 20), "fixture file is not in the folder listing")
    XCTAssertEqual(file.value as? String, "Image")
    attach("live-fixture-folder")

    file.tap()
    XCTAssertTrue(
      app.descendants(matching: .any)["preview.image"].waitForExistence(timeout: 30),
      "fixture image never rendered")
    attach("live-preview")
    app.buttons["preview.done"].tap()
    XCTAssertTrue(
      app.descendants(matching: .any)["preview.screen.\(fileID)"].waitForNonExistence(timeout: 5))

    app.buttons["Account"].tap()
    let signOut = app.revealed("auth.sign-out")
    XCTAssertTrue(signOut.waitForExistence(timeout: 10), "sign-out action never appeared")
    signOut.tap()
    XCTAssertTrue(signIn.waitForExistence(timeout: 20), "sign-out did not return to sign-in")
    attach("live-signed-out")
  }

  private func attach(_ name: String) {
    let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
    attachment.name = name
    attachment.lifetime = .keepAlways
    add(attachment)
  }
}
