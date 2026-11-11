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

  func testVLCHandoffRetriesAfterResolutionFailure() {
    app.launchArguments += [
      "--putio-harness-vlc-installed", "--putio-harness-vlc-resolution-fails-once",
    ]
    app.launch()
    signIn()

    assertVLCRetry()
  }

  private func assertVLCRetry() {
    openInVLC(fileID: 412)
    let failure = app.alerts["Could not open in VLC"]
    XCTAssertTrue(failure.appears(within: 10))
    let requests = element("vlc.requests")
    XCTAssertEqual(requests.value as? String, "0|")
    failure.buttons["Try again"].tap()
    XCTAssertTrue(
      waitForValue(
        requests,
        "1|vlc-x-callback://x-callback-url/stream?url=https://api.put.io/v2/files/412/download"
          + "&x-success=putio:///files/0"),
      "retry did not hand the file to VLC: \(requests.value ?? "")")
    XCTAssertFalse(failure.exists)
  }

  func testImagePDFUnsupportedAndVLCHandoffOutcomes() {
    app.launch()
    signIn()

    // A long-named image: its first lookup never answers, so Back cancels it.
    let longImage = element("files.item.428")
    XCTAssertTrue(longImage.appears(within: 10))
    XCTAssertEqual(longImage.value as? String, "Image")
    longImage.tap()
    XCTAssertTrue(element("preview.loading").appears(within: 10))
    assertViewerToolbar(fileID: 428)
    screenshot("runtime-preview-loading")
    let requests = element("preview.requests")
    XCTAssertEqual(requests.value as? String ?? "", "")
    app.buttons["preview.back"].tap()
    XCTAssertTrue(element("preview.screen.428").disappears(within: 5))
    XCTAssertTrue(
      waitForValue(requests, "428:cancelled"),
      "leaving did not cancel the load: \(requests.value ?? "")")

    // The second lookup fails; Try again reloads in place.
    longImage.tap()
    XCTAssertTrue(app.staticTexts["Couldn’t load this"].appears(within: 10))
    XCTAssertTrue(app.staticTexts["Check your connection and try again."].exists)
    assertViewerToolbar(fileID: 428)
    screenshot("runtime-preview-error")
    app.buttons["preview.retry"].tap()
    XCTAssertTrue(element("preview.image").appears(within: 10))
    XCTAssertTrue(element("preview.screen.428").exists)
    XCTAssertTrue(
      waitForValue(requests, "428:cancelled,428:failed,428:loaded"),
      "retry did not reload in place: \(requests.value ?? "")")
    screenshot("runtime-preview-image")
    app.buttons["preview.back"].tap()
    XCTAssertTrue(element("preview.screen.428").disappears(within: 5))

    let image = element("files.item.406")
    XCTAssertTrue(image.appears(within: 5))
    XCTAssertEqual(image.value as? String, "Image")
    image.tap()
    XCTAssertTrue(element("preview.image").appears(within: 10))
    XCTAssertTrue(app.images["Harness Poster.png"].exists)
    app.buttons["preview.back"].tap()
    XCTAssertTrue(element("preview.screen.406").disappears(within: 5))

    // PDF renders through PDFKit with the page count exposed to accessibility.
    let document = element("files.item.413")
    XCTAssertTrue(document.appears(within: 5))
    XCTAssertEqual(document.value as? String, "Document")
    document.tap()
    XCTAssertTrue(element("preview.document").appears(within: 10))
    XCTAssertTrue(app.staticTexts["put.io harness page 1"].appears(within: 10))
    screenshot("runtime-preview-document")
    app.buttons["preview.back"].tap()
    XCTAssertTrue(element("preview.screen.413").disappears(within: 5))

    // Unsupported: an explanation surface instead of a dead row.
    let archive = element("files.item.407")
    XCTAssertTrue(archive.appears(within: 5))
    XCTAssertEqual(archive.value as? String, "Unsupported file")
    archive.tap()
    XCTAssertTrue(element("unsupported.screen.407").appears(within: 5))
    XCTAssertTrue(app.staticTexts["Unsupported file type"].exists)
    XCTAssertFalse(app.activityIndicators.firstMatch.exists)
    screenshot("runtime-preview-unsupported")
    app.buttons["unsupported.done"].tap()
    XCTAssertTrue(element("unsupported.screen.407").disappears(within: 5))

    // Search and History dispatch through the same routing table.
    app.buttons["Search"].tap()
    let search = app.searchFields.firstMatch
    XCTAssertTrue(search.appears(within: 5))
    search.tap()
    search.typeText("poster\n")
    let searchImage = element("files.search-item.406")
    XCTAssertTrue(searchImage.appears(within: 10))
    searchImage.tap()
    XCTAssertTrue(element("preview.image").appears(within: 10))
    app.buttons["preview.back"].tap()
    let searchArchive = element("files.search-item.407")
    XCTAssertTrue(searchArchive.appears(within: 5))
    searchArchive.tap()
    XCTAssertTrue(element("unsupported.screen.407").appears(within: 5))
    app.buttons["unsupported.done"].tap()
    // The Search tab collapses the tab bar; Files restores it.
    app.buttons["Files"].tap()
    XCTAssertTrue(element("files.screen.0").appears(within: 5))
    let history = app.buttons["History"]
    XCTAssertTrue(history.appears(within: 5))
    history.tap()
    let historyImage = element("history.item.811")
    XCTAssertTrue(historyImage.appears(within: 10))
    historyImage.tap()
    XCTAssertTrue(element("preview.image").appears(within: 10))
    app.buttons["preview.back"].tap()
    XCTAssertTrue(element("preview.screen.406").disappears(within: 5))
    app.buttons["Files"].tap()
    XCTAssertTrue(element("files.screen.0").appears(within: 5))

    // VLC handoff without VLC: the explicit not-installed outcome with a store link.
    let vlcRequests = element("vlc.requests")
    XCTAssertTrue(vlcRequests.appears(within: 5))
    XCTAssertEqual(vlcRequests.value as? String, "0|")
    assertNoVLCAction(fileID: 407)
    assertNoVLCAction(fileID: 406)
    openInVLC(fileID: 412)
    XCTAssertTrue(app.staticTexts["VLC is not installed"].appears(within: 5))
    screenshot("runtime-vlc-missing")
    app.buttons["Get VLC"].tap()
    XCTAssertTrue(
      waitForValue(vlcRequests, "1|https://apps.apple.com/app/id650377962"),
      "store link was not requested: \(vlcRequests.value ?? "")")

    // VLC handoff with VLC: the tokened stream URL leaves the app once, with a
    // return link to the file's folder. The relaunch starts a fresh request log.
    app.terminate()
    app.launchArguments.append("--putio-harness-vlc-installed")
    app.launch()
    XCTAssertTrue(element("files.item.412").appears(within: 10))
    openInVLC(fileID: 408)
    XCTAssertTrue(
      waitForValue(
        vlcRequests,
        "1|vlc-x-callback://x-callback-url/stream?url=https://api.put.io/v2/files/408/download"
          + "&x-success=putio:///files/0"),
      "handoff was not requested: \(vlcRequests.value ?? "")")
    XCTAssertFalse(app.staticTexts["VLC is not installed"].exists)
    XCTAssertTrue(element("files.screen.0").exists)

    app.terminate()
    app.launchArguments.append("--putio-harness-vlc-resolution-fails-once")
    app.launch()
    XCTAssertTrue(element("files.screen.0").appears(within: 10))
    assertVLCRetry()

    app.buttons["Account"].tap()
    let signOut = app.revealed("auth.sign-out")
    XCTAssertTrue(signOut.appears(within: 5))
    if !signOut.isHittable { app.swipeUp() }
    signOut.tap()
    app.confirmSignOut()
    XCTAssertTrue(element("auth.sign-in").appears(within: 10))
  }

  /// Back, the title cut in the middle, and Share and More, both inert until loaded.
  private func assertViewerToolbar(fileID: Int) {
    XCTAssertTrue(element("preview.screen.\(fileID)").exists)
    XCTAssertTrue(app.buttons["preview.back"].isHittable)
    let title = element("preview.title")
    XCTAssertTrue(title.exists)
    XCTAssertEqual(title.label, "document-scan-from-the-harness-weekend-2026.png")
    XCTAssertFalse(app.buttons["preview.share"].isEnabled)
    XCTAssertFalse(app.buttons["preview.more"].isEnabled)
  }

  /// Preview and unsupported rows show a context menu without the handoff.
  private func assertNoVLCAction(fileID: Int) {
    let row = element("files.item.\(fileID)")
    XCTAssertTrue(row.appears(within: 5))
    row.press(forDuration: 1)
    XCTAssertTrue(app.buttons["Rename"].appears(within: 5))
    XCTAssertFalse(app.buttons["Open in VLC"].exists)
    app.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.25)).tap()
    XCTAssertTrue(app.buttons["Rename"].disappears(within: 5))
  }

  private func openInVLC(fileID: Int) {
    let row = element("files.item.\(fileID)")
    XCTAssertTrue(row.appears(within: 5))
    row.press(forDuration: 1)
    let action = app.buttons["Open in VLC"]
    XCTAssertTrue(action.appears(within: 5), "Open in VLC never appeared")
    action.tap()
  }

  private func signIn() {
    let button = element("auth.sign-in")
    XCTAssertTrue(button.appears(within: 10))
    button.tap()
    XCTAssertTrue(element("files.screen.0").appears(within: 10))
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
