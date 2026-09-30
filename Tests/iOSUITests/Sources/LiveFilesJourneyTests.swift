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

    // The account's grants, read-only: this run's own grant is "This app".
    selectTab("Account", in: app)
    let security = app.revealed("account.security")
    XCTAssertTrue(security.waitForExistence(timeout: 10))
    security.tap()
    let apps = app.revealed("security.apps")
    XCTAssertTrue(apps.waitForExistence(timeout: 10))
    apps.tap()
    let thisApp = app.descendants(matching: .any).matching(
      NSPredicate(format: "identifier BEGINSWITH 'security.app.' AND value == 'This app'")
    ).firstMatch
    XCTAssertTrue(thisApp.waitForExistence(timeout: 30), "this run's grant is not listed")
    attach("live-authorized-apps")
    app.navigationBars.buttons["BackButton"].tap()
    app.navigationBars.buttons["BackButton"].tap()

    let signOut = app.revealed("auth.sign-out")
    XCTAssertTrue(signOut.waitForExistence(timeout: 10), "sign-out action never appeared")
    signOut.tap()
    XCTAssertTrue(signIn.waitForExistence(timeout: 20), "sign-out did not return to sign-in")
    attach("live-signed-out")
  }

  /// Scrolling a long listing collapses the tab bar to its selected tab.
  private func selectTab(_ name: String, in app: XCUIApplication) {
    let tab = app.buttons[name]
    if !tab.exists {
      app.tabBars.buttons.matching(NSPredicate(format: "selected == true")).firstMatch.tap()
    }
    XCTAssertTrue(tab.waitForExistence(timeout: 5), "\(name) tab never appeared")
    tab.tap()
  }

  private func attach(_ name: String) {
    let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
    attachment.name = name
    attachment.lifetime = .keepAlways
    add(attachment)
  }
}
