import XCTest

final class PreviewJourneyTests: XCTestCase {
  private var app: XCUIApplication!

  override func setUpWithError() throws {
    try super.setUpWithError()
    continueAfterFailure = false
    app = XCUIApplication()
    app.launchArguments = [
      "--putio-harness-scenario", "files-browser", "--putio-harness-previews",
    ]
    app.launchEnvironment["PUTIO_HARNESS_MEDIA_BASE_URL"] = try XCTUnwrap(
      ProcessInfo.processInfo.environment["PUTIO_HARNESS_MEDIA_BASE_URL"])
  }

  func testImagePDFUnsupportedAndVLCHandoffOutcomes() {
    app.launch()
    signIn()

    // Image: the seeded lookup fails once, so the error state and retry are
    // exercised before the fixture renders.
    let image = element("files.item.406")
    XCTAssertTrue(image.waitForExistence(timeout: 10))
    XCTAssertEqual(image.value as? String, "Image")
    image.tap()
    XCTAssertTrue(app.staticTexts["Could not open image"].waitForExistence(timeout: 10))
    screenshot("runtime-preview-error")
    app.buttons["preview.retry"].tap()
    XCTAssertTrue(element("preview.image").waitForExistence(timeout: 10))
    XCTAssertTrue(app.images["Harness Poster.png"].exists)
    screenshot("runtime-preview-image")
    app.buttons["preview.done"].tap()
    XCTAssertTrue(element("preview.screen.406").waitForNonExistence(timeout: 5))

    // PDF renders through PDFKit with the page count exposed to accessibility.
    let document = element("files.item.413")
    XCTAssertTrue(document.waitForExistence(timeout: 5))
    XCTAssertEqual(document.value as? String, "Document")
    document.tap()
    XCTAssertTrue(element("preview.document").waitForExistence(timeout: 10))
    XCTAssertTrue(app.staticTexts["put.io harness page 1"].waitForExistence(timeout: 10))
    screenshot("runtime-preview-document")
    app.buttons["preview.done"].tap()
    XCTAssertTrue(element("preview.screen.413").waitForNonExistence(timeout: 5))

    // Unsupported: an explanation surface instead of a dead row.
    let archive = element("files.item.407")
    XCTAssertTrue(archive.waitForExistence(timeout: 5))
    XCTAssertEqual(archive.value as? String, "Unsupported file")
    archive.tap()
    XCTAssertTrue(element("unsupported.screen.407").waitForExistence(timeout: 5))
    XCTAssertTrue(app.staticTexts["Cannot open this file"].exists)
    XCTAssertFalse(app.activityIndicators.firstMatch.exists)
    screenshot("runtime-preview-unsupported")
    app.buttons["unsupported.done"].tap()
    XCTAssertTrue(element("unsupported.screen.407").waitForNonExistence(timeout: 5))

    // Search and History dispatch through the same routing table.
    app.buttons["Search"].tap()
    let search = app.searchFields.firstMatch
    XCTAssertTrue(search.waitForExistence(timeout: 5))
    search.tap()
    search.typeText("poster\n")
    let searchImage = element("files.search-item.406")
    XCTAssertTrue(searchImage.waitForExistence(timeout: 10))
    searchImage.tap()
    XCTAssertTrue(element("preview.image").waitForExistence(timeout: 10))
    app.buttons["preview.done"].tap()
    let searchArchive = element("files.search-item.407")
    XCTAssertTrue(searchArchive.waitForExistence(timeout: 5))
    searchArchive.tap()
    XCTAssertTrue(element("unsupported.screen.407").waitForExistence(timeout: 5))
    app.buttons["unsupported.done"].tap()
    // The Search tab collapses the tab bar; Files restores it.
    app.buttons["Files"].tap()
    XCTAssertTrue(element("files.screen.0").waitForExistence(timeout: 5))
    let history = app.buttons["History"]
    XCTAssertTrue(history.waitForExistence(timeout: 5))
    history.tap()
    let historyImage = element("history.item.811")
    XCTAssertTrue(historyImage.waitForExistence(timeout: 10))
    historyImage.tap()
    XCTAssertTrue(element("preview.image").waitForExistence(timeout: 10))
    app.buttons["preview.done"].tap()
    XCTAssertTrue(element("preview.screen.406").waitForNonExistence(timeout: 5))
    app.buttons["Files"].tap()
    XCTAssertTrue(element("files.screen.0").waitForExistence(timeout: 5))

    // VLC handoff without VLC: the explicit not-installed outcome with a store link.
    let requests = element("vlc.requests")
    XCTAssertTrue(requests.waitForExistence(timeout: 5))
    XCTAssertEqual(requests.value as? String, "0|")
    assertNoVLCAction(fileID: 407)
    assertNoVLCAction(fileID: 406)
    openInVLC(fileID: 412)
    XCTAssertTrue(app.staticTexts["VLC is not installed"].waitForExistence(timeout: 5))
    screenshot("runtime-vlc-missing")
    app.buttons["Get VLC"].tap()
    XCTAssertTrue(
      waitForValue(requests, "1|https://apps.apple.com/app/id650377962"),
      "store link was not requested: \(requests.value ?? "")")

    // VLC handoff with VLC: the tokened stream URL leaves the app once, with a
    // return link to the file's folder. The relaunch starts a fresh request log.
    app.terminate()
    app.launchArguments.append("--putio-harness-vlc-installed")
    app.launch()
    XCTAssertTrue(element("files.item.412").waitForExistence(timeout: 10))
    openInVLC(fileID: 408)
    XCTAssertTrue(
      waitForValue(
        requests,
        "1|vlc-x-callback://x-callback-url/stream?url=https://api.put.io/v2/files/408/download"
          + "&x-success=putio:///files/0"),
      "handoff was not requested: \(requests.value ?? "")")
    XCTAssertFalse(app.staticTexts["VLC is not installed"].exists)
    XCTAssertTrue(element("files.screen.0").exists)

    app.buttons["Account"].tap()
    let signOut = app.revealed("auth.sign-out")
    XCTAssertTrue(signOut.waitForExistence(timeout: 5))
    if !signOut.isHittable { app.swipeUp() }
    signOut.tap()
    XCTAssertTrue(element("auth.sign-in").waitForExistence(timeout: 10))
  }

  /// Preview and unsupported rows show a context menu without the handoff.
  private func assertNoVLCAction(fileID: Int) {
    let row = element("files.item.\(fileID)")
    XCTAssertTrue(row.waitForExistence(timeout: 5))
    row.press(forDuration: 1)
    XCTAssertTrue(app.buttons["files.rename.\(fileID)"].waitForExistence(timeout: 5))
    XCTAssertFalse(app.buttons["files.open-in-vlc.\(fileID)"].exists)
    app.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.25)).tap()
    XCTAssertTrue(app.buttons["files.rename.\(fileID)"].waitForNonExistence(timeout: 5))
  }

  private func openInVLC(fileID: Int) {
    let row = element("files.item.\(fileID)")
    XCTAssertTrue(row.waitForExistence(timeout: 5))
    row.press(forDuration: 1)
    let action = app.buttons["files.open-in-vlc.\(fileID)"]
    XCTAssertTrue(action.waitForExistence(timeout: 5), "Open in VLC never appeared")
    action.tap()
  }

  private func signIn() {
    let button = element("auth.sign-in")
    XCTAssertTrue(button.waitForExistence(timeout: 10))
    button.tap()
    XCTAssertTrue(element("files.screen.0").waitForExistence(timeout: 10))
  }

  private func waitForValue(_ element: XCUIElement, _ value: String, timeout: TimeInterval = 5)
    -> Bool
  {
    let expectation = XCTNSPredicateExpectation(
      predicate: NSPredicate(format: "value == %@", value), object: element)
    return XCTWaiter.wait(for: [expectation], timeout: timeout) == .completed
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
