import XCTest

final class DeepLinkJourneyTests: XCTestCase {
  private var app: XCUIApplication!

  override func setUpWithError() throws {
    try super.setUpWithError()
    continueAfterFailure = false
    app = XCUIApplication()
    app.launchArguments = [
      "--putio-harness-scenario", "files-browser", "--putio-harness-deep-links",
    ]
    app.launchEnvironment["PUTIO_HARNESS_MEDIA_BASE_URL"] = try XCTUnwrap(
      ProcessInfo.processInfo.environment["PUTIO_HARNESS_MEDIA_BASE_URL"])
  }

  func testColdWarmAndSignedOutLinksUseExistingScreens() throws {
    try openCold("putio:///files/410")
    signIn()
    XCTAssertTrue(element("link.loading").waitForExistence(timeout: 5))
    screenshot("runtime-deep-link-loading")
    XCTAssertTrue(app.staticTexts["Cannot open link"].waitForExistence(timeout: 10))
    screenshot("runtime-deep-link-error")
    app.buttons["link.retry"].tap()
    XCTAssertTrue(element("files.screen.410").waitForExistence(timeout: 10))
    XCTAssertTrue(element("files.item.411").exists)
    screenshot("runtime-deep-link-folder")

    try open("putio://put.io/settings")
    XCTAssertTrue(app.navigationBars["Account"].waitForExistence(timeout: 10))
    try open("putio:///files/411")
    XCTAssertTrue(element("video.error").waitForExistence(timeout: 10))
    app.buttons["Try again"].tap()
    XCTAssertTrue(element("video.ready").waitForExistence(timeout: 15))
    try open("putio:///history")
    XCTAssertTrue(element("history.item.810").waitForExistence(timeout: 10))
    XCTAssertTrue(element("video.ready").waitForNonExistence(timeout: 5))

    try open("putio:///files/413")
    XCTAssertTrue(element("preview.screen.413").waitForExistence(timeout: 10))
    XCTAssertTrue(element("preview.document").waitForExistence(timeout: 10))
    app.buttons["preview.done"].tap()
    XCTAssertTrue(element("preview.screen.413").waitForNonExistence(timeout: 5))
    try open("putio:///downloads/411")
    XCTAssertTrue(
      app.staticTexts["This link cannot be opened in this app yet."].waitForExistence(timeout: 5))
    app.buttons["link.close"].tap()

    // The PDF lives in the root, so its link resets the Files stack to root.
    app.buttons["Files"].tap()
    XCTAssertTrue(element("files.screen.0").waitForExistence(timeout: 5))
    XCTAssertFalse(app.navigationBars.buttons["BackButton"].exists)
    element("files.item.410").tap()
    XCTAssertTrue(element("files.screen.410").waitForExistence(timeout: 5))

    app.terminate()
    app.launchArguments.append("--putio-harness-link-restoration")
    try openCold("putio:///files/412")
    XCTAssertTrue(element("video.error").waitForExistence(timeout: 10))
    app.buttons["Try again"].tap()
    XCTAssertTrue(element("video.ready").waitForExistence(timeout: 15))
    element("video.done").tap()
    XCTAssertTrue(element("files.screen.0").waitForExistence(timeout: 5))
    XCTAssertFalse(app.navigationBars.buttons["BackButton"].exists)
    // Outwait the seeded restoration response to detect a late path overwrite.
    let staleRestoration = XCTNSPredicateExpectation(
      predicate: NSPredicate(format: "exists == true"), object: element("files.screen.410"))
    staleRestoration.isInverted = true
    XCTAssertEqual(XCTWaiter.wait(for: [staleRestoration], timeout: 6), .completed)

    app.terminate()
    app.launchArguments.removeAll { $0 == "--putio-harness-link-restoration" }
    try openCold("putio:///account")
    XCTAssertTrue(app.navigationBars["Account"].waitForExistence(timeout: 10))
    XCTAssertFalse(element("auth.sign-in").exists)
    signOut()
    try open("putio:///history")
    XCTAssertTrue(element("auth.sign-in").waitForExistence(timeout: 5))
    XCTAssertFalse(element("history.item.810").exists)
    signIn()
    XCTAssertTrue(element("history.item.810").waitForExistence(timeout: 10))
    try open("putio:///account")
    signOut()
  }

  private func openCold(_ value: String) throws {
    app.open(try XCTUnwrap(URL(string: value)))
  }

  private func open(_ value: String) throws {
    XCTAssertEqual(app.state, .runningForeground)
    XCUIDevice.shared.system.open(try XCTUnwrap(URL(string: value)))
  }

  private func signIn() {
    let button = element("auth.sign-in")
    XCTAssertTrue(button.waitForExistence(timeout: 10))
    button.tap()
  }

  private func signOut() {
    let button = app.revealed("auth.sign-out")
    XCTAssertTrue(button.waitForExistence(timeout: 5))
    button.tap()
    XCTAssertTrue(element("auth.sign-in").waitForExistence(timeout: 10))
  }

  private func element(_ identifier: String) -> XCUIElement {
    app.descendants(matching: .any)[identifier]
  }

  private func screenshot(_ name: String) {
    let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
    attachment.name = name
    attachment.lifetime = .keepAlways
    add(attachment)
  }
}
