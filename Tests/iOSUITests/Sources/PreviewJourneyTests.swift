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

  override func tearDown() {
    XCUIDevice.shared.orientation = .portrait
    super.tearDown()
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
    let poster = app.images["Harness Poster.png"]
    XCTAssertTrue(poster.exists)
    assertImageGestures(poster)
    app.buttons["preview.back"].tap()
    XCTAssertTrue(element("preview.screen.406").disappears(within: 5))

    let document = element("files.item.413")
    XCTAssertTrue(document.appears(within: 5))
    XCTAssertEqual(document.value as? String, "Document")
    document.tap()
    XCTAssertTrue(element("preview.document").appears(within: 10))
    XCTAssertTrue(app.staticTexts["put.io harness page 1"].appears(within: 10))
    let pill = element("preview.page")
    XCTAssertTrue(pill.appears(within: 5), "a twelve-page document has no page pill")
    XCTAssertEqual(pill.label, "Page 1 of 12")
    screenshot("runtime-preview-document")
    assertDocumentScrollsAndZooms(pill)
    app.buttons["preview.back"].tap()
    XCTAssertTrue(element("preview.screen.413").disappears(within: 5))

    let loadedRequests = requests.value as? String
    assertCannotShow(rowID: 407, title: "Harness Bundle.zip", rowValue: "Unsupported file")
    assertCannotShow(
      rowID: 429, title: "ubuntu-24.04.3-desktop-amd64.iso", rowValue: "Unsupported file",
      screenshot: "runtime-preview-cannot-show")
    assertCannotShow(rowID: 430, title: "Harness Panorama.png", rowValue: "Image")
    XCTAssertEqual(requests.value as? String, loadedRequests)
    assertCannotShow(rowID: 431, title: "Harness Scan.pdf", rowValue: "Document")
    XCTAssertEqual(requests.value as? String, (loadedRequests ?? "") + ",431:loaded")
    assertTextPreviews()
    var swipes = 0
    while !element("files.item.412").isHittable, swipes < 3 {
      app.swipeDown()
      swipes += 1
    }
    XCTAssertTrue(element("files.item.412").isHittable, "row 412 stayed out of reach")

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
    XCTAssertTrue(element("preview.cannot-show").appears(within: 5))
    app.buttons["preview.back"].tap()
    XCTAssertTrue(element("preview.screen.407").disappears(within: 5))
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

    let vlcRequests = element("vlc.requests")
    XCTAssertTrue(vlcRequests.appears(within: 5))
    XCTAssertEqual(vlcRequests.value as? String, "0|")
    assertNoVLCAction(fileID: 407)
    assertNoVLCAction(fileID: 406)
    assertNoVLCAction(fileID: 412)
    XCTAssertEqual(vlcRequests.value as? String, "0|")

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

  private func assertImageGestures(_ image: XCUIElement) {
    let center = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
    XCTAssertTrue(waitForFit(image), "the image is not fitted to the window: \(image.frame)")
    let window = app.windows.firstMatch.frame
    XCTAssertEqual(image.frame.midY, window.midY, accuracy: 1, "the image is not centred")

    image.pinch(withScale: 3, velocity: 2)
    XCTAssertTrue(
      waitForFrame(image) { $0.width > window.width * 1.5 }, "pinch did not zoom: \(image.frame)")
    let zoomed = image.frame
    center.press(
      forDuration: 0.1,
      thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.2, dy: 0.5)))
    XCTAssertTrue(
      waitForFrame(image) { $0.minX < zoomed.minX - 40 }, "drag did not pan: \(image.frame)")
    center.doubleTap()
    XCTAssertTrue(waitForFit(image), "double tap did not reset zoom: \(image.frame)")
    center.doubleTap()
    XCTAssertTrue(
      waitForFrame(image) { $0.width > window.width * 1.5 },
      "double tap did not zoom in: \(image.frame)")
    center.doubleTap()
    XCTAssertTrue(waitForFit(image), "double tap did not reset zoom: \(image.frame)")

    let back = app.buttons["preview.back"]
    center.tap()
    XCTAssertTrue(back.disappears(within: 5), "a single tap did not hide the bars")
    XCTAssertTrue(waitForFit(image), "hiding the bars moved the image: \(image.frame)")
    center.tap()
    XCTAssertTrue(back.appears(within: 5), "a second tap did not show the bars")

    image.pinch(withScale: 3, velocity: 2)
    XCTAssertTrue(
      waitForFrame(image) { $0.width > window.width * 1.5 }, "pinch did not zoom: \(image.frame)")
    XCUIDevice.shared.orientation = .landscapeLeft
    XCTAssertTrue(
      waitForFrame(image) { _ in app.windows.firstMatch.frame.width > window.width },
      "the viewer did not rotate")
    XCTAssertTrue(waitForFit(image), "rotation did not reset zoom: \(image.frame)")
    XCTAssertTrue(back.isHittable, "the bars do not float over the landscape image")
    XCTAssertTrue(element("preview.title").exists)
    screenshot("runtime-preview-image-landscape")
    XCUIDevice.shared.orientation = .portrait
    XCTAssertTrue(
      waitForFrame(image) { _ in app.windows.firstMatch.frame.width == window.width },
      "the viewer did not rotate back")
    XCTAssertTrue(waitForFit(image), "rotating back did not fit the image: \(image.frame)")
    XCTAssertTrue(back.isHittable)
  }

  private func assertTextPreviews() {
    assertCannotShow(rowID: 433, title: "Harness Notes.txt", rowValue: "Document")

    let short = app.revealed("files.item.434")
    XCTAssertTrue(short.exists, "the short text row never appeared")
    short.tap()
    let text = element("preview.text")
    XCTAssertTrue(text.appears(within: 10), "the short text never loaded")
    XCTAssertEqual(element("preview.title").label, "Harness Subtitles.en.srt")
    XCTAssertTrue((text.value as? String ?? "").hasPrefix("1\n00:00:02,000 --> 00:00:05,000"))
    XCTAssertFalse(element("preview.text.truncated").exists, "a short file shows the end line")
    screenshot("runtime-preview-text")
    copyFirstWord(ofLine: 2, in: text)
    app.buttons["preview.back"].tap()
    XCTAssertTrue(element("preview.screen.434").disappears(within: 5))
    let pasteboard = element("harness.pasteboard")
    XCTAssertTrue(
      waitForValue(pasteboard, "Previously"),
      "the copied word is not on the pasteboard: \(pasteboard.value ?? "")")

    let long = app.revealed("files.item.432")
    XCTAssertTrue(long.exists, "the long text row never appeared")
    long.tap()
    let longText = element("preview.text")
    XCTAssertTrue(longText.appears(within: 10), "the long text never loaded")
    let notice = element("preview.text.truncated")
    XCTAssertFalse(notice.isHittable, "the end line shows before the end")
    longText.scrollTextToEnd(revealing: notice)
    XCTAssertTrue(notice.isHittable, "scrolling never reached the end line")
    XCTAssertEqual(notice.label, "Showing the first 250 kB.")
    XCTAssertTrue(app.buttons["preview.back"].isHittable)
    screenshot("runtime-preview-text-truncated")
    app.buttons["preview.back"].tap()
    XCTAssertTrue(element("preview.screen.432").disappears(within: 5))
  }

  private func copyFirstWord(ofLine line: Int, in text: XCUIElement) {
    let bar = app.navigationBars.firstMatch.frame
    let lineHeight: CGFloat = 14 * 1.45
    let lineMidY = bar.maxY + 16 + lineHeight * (CGFloat(line) + 0.5)
    text.coordinate(withNormalizedOffset: .zero)
      .withOffset(CGVector(dx: 40, dy: lineMidY - text.frame.minY))
      .doubleTap()
    let menuCopy = app.menuItems["Copy"]
    let buttonCopy = app.buttons["Copy"]
    let deadline = Date.now.addingTimeInterval(5)
    while !menuCopy.exists, !buttonCopy.exists, Date.now < deadline {
      RunLoop.current.run(until: Date.now.addingTimeInterval(0.1))
    }
    let copy = menuCopy.exists ? menuCopy : buttonCopy
    XCTAssertTrue(copy.exists, "selecting a word showed no Copy action")
    copy.tap()
  }

  private func assertDocumentScrollsAndZooms(_ pill: XCUIElement) {
    let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.7))
    let end = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.3))
    var drags = 0
    while pill.label == "Page 1 of 12", drags < 10 {
      start.press(forDuration: 0.05, thenDragTo: end)
      drags += 1
    }
    let middle = (2...11).map { "Page \($0) of 12" }
    XCTAssertTrue(
      waitForLabel(pill, in: middle), "scrolling did not move the pill: \(pill.label)")
    let number = pill.label.split(separator: " ")[1]
    let page = app.staticTexts["put.io harness page \(number)"]
    let window = app.windows.firstMatch.frame
    let bar = app.navigationBars.firstMatch.frame
    XCTAssertTrue(
      page.exists && page.frame.minY >= bar.maxY && page.frame.maxY <= window.maxY,
      "page \(number) is not on screen: \(page.frame)")
    XCTAssertTrue(app.buttons["preview.back"].isHittable)
    screenshot("runtime-preview-document-middle")

    XCUIDevice.shared.orientation = .landscapeLeft
    XCTAssertTrue(
      waitForFrame(pill) { _ in app.windows.firstMatch.frame.width > window.width },
      "the document did not rotate")
    XCTAssertTrue(app.buttons["preview.back"].isHittable)
    XCTAssertTrue(pill.exists, "the landscape document has no page pill")
    screenshot("runtime-preview-document-landscape")
    XCUIDevice.shared.orientation = .portrait
    XCTAssertTrue(
      waitForFrame(pill) { _ in app.windows.firstMatch.frame.width == window.width },
      "the document did not rotate back")

    let fitted = page.frame
    element("preview.document").pinch(withScale: 2.5, velocity: 2)
    XCTAssertTrue(
      waitForFrame(page) { $0.width > fitted.width * 1.5 },
      "pinch did not zoom the page: \(fitted) -> \(page.frame)")
  }

  private func waitForLabel(
    _ element: XCUIElement, in labels: [String], timeout: TimeInterval = 5
  ) -> Bool {
    let deadline = Date.now.addingTimeInterval(timeout)
    while Date.now < deadline {
      if labels.contains(element.label) { return true }
      RunLoop.current.run(until: Date.now.addingTimeInterval(0.1))
    }
    return labels.contains(element.label)
  }

  private func waitForFit(_ image: XCUIElement) -> Bool {
    waitForFrame(image) { frame in
      let window = app.windows.firstMatch.frame
      let fillsWidth = abs(frame.width - window.width) < 1 && frame.height <= window.height + 1
      let fillsHeight = abs(frame.height - window.height) < 1 && frame.width <= window.width + 1
      return (fillsWidth || fillsHeight) && abs(frame.midX - window.midX) < 1
        && abs(frame.midY - window.midY) < 1
    }
  }

  private func waitForFrame(
    _ element: XCUIElement, timeout: TimeInterval = 5, until condition: (CGRect) -> Bool
  ) -> Bool {
    let deadline = Date.now.addingTimeInterval(timeout)
    while Date.now < deadline {
      if element.exists, condition(element.frame) { return true }
      RunLoop.current.run(until: Date.now.addingTimeInterval(0.1))
    }
    return element.exists && condition(element.frame)
  }

  private func assertCannotShow(
    rowID: Int, title: String, rowValue: String, screenshot name: String? = nil
  ) {
    let row = app.revealed("files.item.\(rowID)")
    XCTAssertTrue(row.exists, "row \(rowID) never appeared")
    XCTAssertEqual(row.value as? String, rowValue)
    row.tap()
    XCTAssertTrue(element("preview.cannot-show").appears(within: 5))
    XCTAssertTrue(element("preview.screen.\(rowID)").exists)
    XCTAssertTrue(app.staticTexts["Can’t show this file here."].exists)
    XCTAssertTrue(app.staticTexts["Open it on put.io from a browser instead."].exists)
    XCTAssertEqual(element("preview.title").label, title)
    XCTAssertTrue(app.buttons["preview.back"].isHittable)
    XCTAssertFalse(app.buttons["preview.share"].isEnabled)
    XCTAssertTrue(app.buttons["preview.more"].exists)
    XCTAssertFalse(app.buttons["preview.retry"].exists)
    XCTAssertFalse(app.activityIndicators.firstMatch.exists)
    if let name { screenshot(name) }
    app.buttons["preview.back"].tap()
    XCTAssertTrue(element("preview.screen.\(rowID)").disappears(within: 5))
  }

  private func assertViewerToolbar(fileID: Int) {
    XCTAssertTrue(element("preview.screen.\(fileID)").exists)
    XCTAssertTrue(app.buttons["preview.back"].isHittable)
    let title = element("preview.title")
    XCTAssertTrue(title.exists)
    XCTAssertEqual(title.label, "document-scan-from-the-harness-weekend-2026.png")
    XCTAssertFalse(app.buttons["preview.share"].isEnabled)
    XCTAssertFalse(app.buttons["preview.more"].isEnabled)
  }

  private func assertNoVLCAction(fileID: Int) {
    let row = element("files.item.\(fileID)")
    XCTAssertTrue(row.appears(within: 5), "row \(fileID) never appeared")
    revealBelowNavigationBar(row)
    row.press(forDuration: 1)
    XCTAssertTrue(app.buttons["Rename"].appears(within: 5))
    XCTAssertFalse(app.buttons["Open in VLC"].exists)
    app.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.25)).tap()
    XCTAssertTrue(app.buttons["Rename"].disappears(within: 5))
  }

  private func revealBelowNavigationBar(_ row: XCUIElement) {
    let bar = app.navigationBars.firstMatch
    var swipes = 0
    while row.frame.minY < bar.frame.maxY, swipes < 3 {
      app.swipeDown()
      swipes += 1
    }
  }

  private func openInVLC(fileID: Int) {
    let row = element("files.item.\(fileID)")
    XCTAssertTrue(row.appears(within: 5))
    revealBelowNavigationBar(row)
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
