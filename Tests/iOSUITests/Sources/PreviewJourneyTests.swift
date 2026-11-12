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

  func testVLCFailureToastsAndTheNextTapHandsOff() {
    app.launchArguments += [
      "--putio-harness-vlc-installed", "--putio-harness-vlc-resolution-fails-once",
    ]
    app.launch()
    signIn()

    assertVLCFailureThenHandoff()
    signOut()
  }

  func testVLCNotInstalledOffersTheAppStore() {
    app.launchArguments.append("--putio-harness-vlc-removed")
    app.launch()
    signIn()

    let requests = element("vlc.requests")
    openInVLC(fileID: 412)
    let missing = app.putioAlert("VLC is not installed")
    XCTAssertTrue(missing.appears(within: 10), "a missing VLC raised no alert")
    XCTAssertTrue(
      missing.staticTexts["Install VLC for iOS from the App Store to stream this file there."]
        .exists)
    XCTAssertTrue(missing.buttons["Cancel"].exists)
    screenshot("runtime-preview-vlc-missing")
    XCTAssertEqual(requests.value as? String, "0|")
    missing.buttons["Get VLC"].tap()
    XCTAssertTrue(
      waitForValue(requests, "1|https://apps.apple.com/app/id650377962"),
      "Get VLC did not open the App Store: \(requests.value ?? "")")
    XCTAssertTrue(missing.disappears(within: 5))

    openInVLC(fileID: 412)
    XCTAssertTrue(
      waitForValue(
        requests,
        "2|vlc-x-callback://x-callback-url/stream?url=https://api.put.io/v2/files/412/download"
          + "&x-success=putio:///files/0"),
      "the handoff after installing VLC did not open: \(requests.value ?? "")")
    XCTAssertFalse(app.putioAlert("VLC is not installed").exists)
    signOut()
  }

  func testVLCFailureToastNamesTheCause() {
    app.launchArguments += [
      "--putio-harness-vlc-installed", "--putio-harness-download-token-missing",
    ]
    app.launch()
    signIn()

    let requests = element("vlc.requests")
    openInVLC(fileID: 412)
    XCTAssertTrue(
      app.staticTexts["Couldn’t prepare “Root Movie.mkv” for VLC. Sign in again."]
        .appears(within: 10), "a missing download token showed no toast")
    screenshot("runtime-preview-vlc-failed")
    XCTAssertEqual(app.putioAlerts.count, 0)
    XCTAssertEqual(requests.value as? String, "0|")

    app.terminate()
    app.launchArguments =
      app.launchArguments.filter {
        $0 != "--putio-harness-download-token-missing"
      } + ["--putio-harness-vlc-refuses-once"]
    app.launch()
    XCTAssertTrue(element("files.screen.0").appears(within: 10))
    openInVLC(fileID: 412)
    XCTAssertTrue(
      app.staticTexts["Install VLC to open “Root Movie.mkv”."].appears(within: 10),
      "a refused handoff showed no toast")
    XCTAssertEqual(app.putioAlerts.count, 0)
    openInVLC(fileID: 412)
    XCTAssertTrue(
      waitForValue(
        requests,
        "2|vlc-x-callback://x-callback-url/stream?url=https://api.put.io/v2/files/412/download"
          + "&x-success=putio:///files/0"),
      "the second tap did not hand off: \(requests.value ?? "")")
    signOut()
  }

  private func assertVLCFailureThenHandoff() {
    openInVLC(fileID: 412)
    let failure = app.staticTexts[
      "Couldn’t prepare “Root Movie.mkv” for VLC. Check your connection and try again."]
    XCTAssertTrue(failure.appears(within: 10), "the failed handoff showed no toast")
    XCTAssertEqual(app.putioAlerts.count, 0)
    let requests = element("vlc.requests")
    XCTAssertEqual(requests.value as? String, "0|")
    openInVLC(fileID: 412)
    XCTAssertTrue(
      waitForValue(
        requests,
        "1|vlc-x-callback://x-callback-url/stream?url=https://api.put.io/v2/files/412/download"
          + "&x-success=putio:///files/0"),
      "the next tap did not hand the file to VLC: \(requests.value ?? "")")
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
    assertShares("Harness Poster.png", from: app.buttons["preview.share"], capture: "image")
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
    assertShares("Document.pdf", from: app.buttons["preview.share"], capture: "document")
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
    assertVLCFailureThenHandoff()

    app.buttons["Account"].tap()
    let signOut = app.revealed("auth.sign-out")
    XCTAssertTrue(signOut.appears(within: 5))
    if !signOut.isHittable { app.swipeUp() }
    signOut.tap()
    app.confirmSignOut()
    XCTAssertTrue(element("auth.sign-in").appears(within: 10))
  }

  func testSwipesBetweenFilesOfTheSameKind() {
    app.launch()
    signIn()

    let gallery = app.revealed("files.item.470", maximumSwipes: 8)
    XCTAssertTrue(gallery.exists, "the gallery folder never appeared")
    gallery.tap()
    let first = element("files.item.471")
    XCTAssertTrue(first.appears(within: 10))
    first.tap()
    XCTAssertTrue(element("preview.image").appears(within: 10))
    let title = element("preview.title")
    let position = element("preview.position")
    XCTAssertEqual(title.label, "Gallery 1.png")
    XCTAssertTrue(position.appears(within: 5), "a folder of images shows no position")
    XCTAssertEqual(position.label, "1 of 3 or more", "the set does not say more files remain")
    XCTAssertTrue(
      waitForLabel(position, in: ["1 of 4"], timeout: 10),
      "the preview did not load the next folder page: \(position.label)")

    app.swipeLeft()
    XCTAssertTrue(waitForLabel(title, in: ["Gallery 2.png"]), "the swipe skipped past the video")
    XCTAssertEqual(position.label, "2 of 4")
    XCTAssertTrue(app.images["Gallery 2.png"].appears(within: 10))
    app.swipeLeft()
    XCTAssertTrue(waitForLabel(title, in: ["Gallery 3.png"]), "the second swipe did not page")
    XCTAssertEqual(position.label, "3 of 4")
    let image = app.images["Gallery 3.png"]
    XCTAssertTrue(image.appears(within: 10))
    XCTAssertTrue(waitForFit(image), "the third image is not fitted: \(image.frame)")
    screenshot("runtime-preview-position")

    let window = app.windows.firstMatch.frame
    image.pinch(withScale: 3, velocity: 2)
    XCTAssertTrue(
      waitForFrame(image) { $0.width > window.width * 1.5 }, "pinch did not zoom: \(image.frame)")
    let zoomed = image.frame
    let center = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
    center.press(
      forDuration: 0.1,
      thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.1, dy: 0.5)))
    XCTAssertTrue(
      waitForFrame(image) { $0.minX < zoomed.minX - 40 }, "a zoomed swipe did not pan")
    XCTAssertEqual(title.label, "Gallery 3.png", "a zoomed swipe paged")
    XCTAssertEqual(position.label, "3 of 4")
    center.doubleTap()
    XCTAssertTrue(waitForFit(image), "double tap did not reset zoom: \(image.frame)")
    app.buttons["preview.back"].tap()
    XCTAssertTrue(element("preview.screen.474").disappears(within: 5))

    app.buttons["Search"].tap()
    let search = app.searchFields.firstMatch
    XCTAssertTrue(search.appears(within: 5))
    search.tap()
    search.typeText("gallery\n")
    let found = element("files.search-item.471")
    XCTAssertTrue(found.appears(within: 10))
    found.tap()
    XCTAssertTrue(app.images["Gallery 1.png"].appears(within: 10))
    XCTAssertFalse(position.exists, "a preview from Search shows a position")
    app.swipeLeft()
    XCTAssertEqual(title.label, "Gallery 1.png", "a preview from Search paged")
    app.buttons["preview.back"].tap()
    XCTAssertTrue(element("preview.screen.471").disappears(within: 5))
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
    copyLine(2, in: text)
    app.buttons["preview.back"].tap()
    XCTAssertTrue(element("preview.screen.434").disappears(within: 5))
    let pasteboard = element("harness.pasteboard")
    XCTAssertTrue(
      waitForValue(pasteboard, matching: #"Previously on Blue Lights\.\n?"#),
      "the copied line is not on the pasteboard: \(pasteboard.value ?? "")")

    let long = app.revealed("files.item.432")
    XCTAssertTrue(long.exists, "the long text row never appeared")
    long.tap()
    let longText = element("preview.text")
    XCTAssertTrue(longText.appears(within: 10), "the long text never loaded")
    let notice = element("preview.text.truncated")
    XCTAssertFalse(notice.isOnScreen, "the end line shows before the end")
    longText.scrollTextToEnd(revealing: notice)
    XCTAssertTrue(
      notice.isOnScreen, "scrolling never reached the end line: \(notice.debugDescription)")
    XCTAssertEqual(notice.label, "Showing the first 250 kB.")
    XCTAssertTrue(app.buttons["preview.back"].isHittable)
    let row = app.buttons["preview.text.share"]
    XCTAssertTrue(row.isOnScreen, "the Share row is off screen: \(row.frame)")
    XCTAssertGreaterThan(row.frame.minY, notice.frame.maxY)
    screenshot("runtime-preview-text-truncated")
    assertShares("Blue.Lights.S04.en.srt", from: row, capture: "text")
    assertShares("Blue.Lights.S04.en.srt", from: app.buttons["preview.share"])
    app.buttons["preview.back"].tap()
    XCTAssertTrue(element("preview.screen.432").disappears(within: 5))
  }

  private func assertShares(_ name: String, from control: XCUIElement, capture: String? = nil) {
    let sheet = app.openShareSheet(from: control, sharing: name)
    if let capture { screenshot("runtime-preview-share-\(capture)") }
    app.dismissShareSheet(sheet)
  }

  private func copyLine(_ line: Int, in text: XCUIElement) {
    let bar = app.navigationBars.firstMatch.frame
    let lineHeight: CGFloat = 14 * 1.45
    let lineMidY = bar.maxY + 16 + lineHeight * (CGFloat(line) + 0.5)
    let origin = text.coordinate(withNormalizedOffset: .zero)
    origin.withOffset(CGVector(dx: 20, dy: lineMidY - text.frame.minY))
      .press(
        forDuration: 0.8,
        thenDragTo: origin.withOffset(
          CGVector(dx: text.frame.width - 20, dy: lineMidY - text.frame.minY)))
    let menuCopy = app.menuItems["Copy"]
    let buttonCopy = app.buttons["Copy"]
    let deadline = Date.now.addingTimeInterval(5)
    while !menuCopy.exists, !buttonCopy.exists, Date.now < deadline {
      RunLoop.current.run(until: Date.now.addingTimeInterval(0.1))
    }
    let copy = menuCopy.exists ? menuCopy : buttonCopy
    XCTAssertTrue(copy.exists, "selecting a line showed no Copy action")
    copy.tap()
    XCTAssertTrue(copy.disappears(within: 5), "the Copy action stayed on screen")
    text.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.8)).tap()
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
      if element.exists, labels.contains(element.label) { return true }
      RunLoop.current.run(until: Date.now.addingTimeInterval(0.1))
    }
    return element.exists && labels.contains(element.label)
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

  func testMoreMenuRenamesAndMovesTheShownFile() {
    app.launch()
    signIn()

    let document = app.revealed("files.item.413")
    XCTAssertTrue(document.exists, "the document row never appeared")
    document.tap()
    XCTAssertTrue(app.staticTexts["put.io harness page 1"].appears(within: 10))
    assertMoreMenu()
    screenshot("runtime-preview-more-pdf")
    dismissMenu()
    app.buttons["preview.back"].tap()
    XCTAssertTrue(element("preview.screen.413").disappears(within: 5))

    let gallery = app.revealed("files.item.470", maximumSwipes: 8)
    XCTAssertTrue(gallery.exists, "the gallery folder never appeared")
    gallery.tap()
    let first = element("files.item.471")
    XCTAssertTrue(first.appears(within: 10))
    first.tap()
    XCTAssertTrue(app.images["Gallery 1.png"].appears(within: 10))
    let title = element("preview.title")
    assertMoreMenu()
    screenshot("runtime-preview-more-image")

    app.buttons["Rename"].firstMatch.tap()
    let alert = app.alerts["Rename"]
    XCTAssertTrue(alert.appears(within: 5), "Rename never opened over the viewer")
    XCTAssertTrue(app.keyboards.firstMatch.appears(within: 5), "the name field never took focus")
    XCTAssertEqual(alert.textFields.firstMatch.value as? String, "Gallery 1.png")
    screenshot("runtime-preview-rename")
    app.typeText("Gallery One")
    XCTAssertEqual(
      alert.textFields.firstMatch.value as? String, "Gallery One.png",
      "typing did not replace only the stem")
    alert.buttons["Rename"].firstMatch.tap()
    XCTAssertTrue(alert.disappears(within: 5), "the alert stayed open after Rename")
    XCTAssertTrue(app.staticTexts["Couldn’t rename."].appears(within: 15), "no failure toast")
    XCTAssertEqual(title.label, "Gallery 1.png", "the failed rename changed the title")
    screenshot("runtime-preview-rename-failed")
    app.buttons["Try again"].tap()
    XCTAssertTrue(
      waitForLabel(title, in: ["Gallery One.png"], timeout: 10),
      "the title did not take the new name: \(title.label)")
    XCTAssertTrue(element("preview.screen.471").exists)

    app.buttons["preview.more"].tap()
    app.buttons["Move"].firstMatch.tap()
    XCTAssertTrue(element("files.move-screen.0").appears(within: 5), "Move never opened")
    let harness = element("files.move-folder.410")
    XCTAssertTrue(harness.appears(within: 10), "the move sheet lists no Harness Folder")
    harness.tap()
    XCTAssertTrue(element("files.move-screen.410").appears(within: 5))
    let moveHere = app.buttons["Move to Harness Folder"]
    XCTAssertTrue(moveHere.appears(within: 5))
    moveHere.tap()
    XCTAssertTrue(element("files.move-picker").disappears(within: 10))
    let moved = app.descendants(matching: .any)
      .matching(NSPredicate(format: "label == %@", "1 item is in the selected folder.")).firstMatch
    XCTAssertTrue(moved.appears(within: 10), "the move showed no toast")
    XCTAssertTrue(element("preview.screen.471").exists, "the viewer left the moved file")
    XCTAssertEqual(title.label, "Gallery One.png")
    screenshot("runtime-preview-moved")

    app.buttons["preview.back"].tap()
    XCTAssertTrue(element("preview.screen.471").disappears(within: 5))
    XCTAssertTrue(element("files.item.473").appears(within: 10))
    XCTAssertTrue(first.disappears(within: 10), "the gallery still lists the moved file")
    signOutFromFiles()
  }

  private func signOutFromFiles() {
    let back = app.navigationBars.buttons["BackButton"].firstMatch
    for _ in 0..<4 where !element("files.screen.0").appears(within: 2) && back.exists {
      back.tap()
    }
    XCTAssertTrue(element("files.screen.0").appears(within: 5), "Back did not reach Files")
    signOut()
  }

  func testTrashShowsTheNextFileAndUndoBringsItBack() {
    app.launch()
    signIn()

    let title = element("preview.title")
    let position = element("preview.position")
    openGalleryImage(474, title: "Gallery 3.png")
    XCTAssertTrue(
      waitForLabel(position, in: ["3 of 4"], timeout: 10), "position: \(position.label)")
    removeShownFile(row: "Move to trash")
    XCTAssertTrue(app.staticTexts["Moved to trash"].appears(within: 10), "no trash toast")
    XCTAssertTrue(waitForLabel(title, in: ["Gallery 4.png"]), "the viewer did not move on")
    XCTAssertTrue(
      waitForLabel(position, in: ["3 of 3", "3 of 3 or more"]),
      "the set still counts the trashed file: \(position.label)")
    XCTAssertTrue(app.images["Gallery 4.png"].appears(within: 5))
    screenshot("runtime-preview-trashed")

    app.buttons["Undo"].firstMatch.tap()
    XCTAssertTrue(
      waitForLabel(title, in: ["Gallery 3.png"], timeout: 15),
      "Undo did not bring the file back: \(title.label)")
    XCTAssertTrue(
      waitForLabel(position, in: ["3 of 4"], timeout: 10), "position: \(position.label)")
    app.buttons["preview.back"].tap()
    XCTAssertTrue(element("preview.screen.474").disappears(within: 5))
    XCTAssertTrue(element("files.item.474").appears(within: 10), "the folder lost the file")

    let album = element("files.item.496")
    XCTAssertTrue(album.appears(within: 5), "the album folder never appeared")
    app.bringIntoView(album)
    album.tap()
    let cover = element("files.item.497")
    XCTAssertTrue(cover.appears(within: 10), "the album never loaded")
    cover.tap()
    XCTAssertTrue(app.images["Album Cover.png"].appears(within: 10))
    XCTAssertFalse(position.exists, "a single image shows a position")
    removeShownFile(row: "Move to trash")
    XCTAssertTrue(element("preview.screen.497").disappears(within: 10), "the viewer stayed open")
    XCTAssertTrue(app.staticTexts["Moved to trash"].appears(within: 5), "no toast over the folder")
    XCTAssertTrue(element("files.screen.496").exists, "the viewer did not land in the folder")
    XCTAssertTrue(cover.disappears(within: 10), "the folder still lists the trashed file")
    screenshot("runtime-preview-trashed-last")
    app.buttons["Undo"].firstMatch.tap()
    XCTAssertTrue(cover.appears(within: 15), "Undo did not restore the file to its folder")
    signOutFromFiles()
  }

  func testTrashOffDeletesTheShownFileAfterAsking() {
    app.launchArguments.append("--putio-harness-trash-disabled")
    app.launch()
    signIn()

    let title = element("preview.title")
    let position = element("preview.position")
    openGalleryImage(474, title: "Gallery 3.png")
    XCTAssertTrue(
      waitForLabel(position, in: ["3 of 4"], timeout: 10), "position: \(position.label)")
    app.buttons["preview.more"].tap()
    let delete = app.buttons["Delete permanently"].firstMatch
    XCTAssertTrue(delete.appears(within: 5), "More has no Delete permanently")
    XCTAssertFalse(app.buttons["Move to trash"].exists, "trash off still offers Move to trash")
    screenshot("runtime-preview-more-trash-off")
    delete.tap()
    let alert = app.alerts["Delete 1 item permanently?"]
    XCTAssertTrue(alert.appears(within: 5), "the delete did not ask first")
    XCTAssertTrue(
      alert.staticTexts["Trash is off for this account, so this can’t be undone."].exists)
    screenshot("runtime-preview-delete-confirm")
    alert.buttons["Cancel"].firstMatch.tap()
    XCTAssertTrue(alert.disappears(within: 5))
    XCTAssertEqual(title.label, "Gallery 3.png", "Cancel removed the file")

    removeShownFile(row: "Delete permanently")
    XCTAssertTrue(alert.appears(within: 5))
    alert.buttons["Delete"].firstMatch.tap()
    XCTAssertTrue(app.staticTexts["Item deleted"].appears(within: 10), "no delete message")
    XCTAssertFalse(app.buttons["Undo"].exists, "a permanent delete offers Undo")
    XCTAssertTrue(waitForLabel(title, in: ["Gallery 4.png"]), "the viewer did not move on")
    XCTAssertTrue(
      waitForLabel(position, in: ["3 of 3"], timeout: 10), "position: \(position.label)")
    app.buttons["preview.back"].tap()
    XCTAssertTrue(element("preview.screen.475").disappears(within: 5))
    XCTAssertTrue(element("files.item.473").appears(within: 10))
    XCTAssertTrue(element("files.item.474").disappears(within: 10), "the folder kept the file")
    signOutFromFiles()
  }

  func testTrashLimitAsksBeforeDeletingTheShownFile() {
    app.launchArguments.append("--putio-harness-trash-limit")
    app.launch()
    signIn()

    let gallery = app.revealed("files.item.470", maximumSwipes: 8)
    XCTAssertTrue(gallery.exists, "the gallery folder never appeared")
    gallery.tap()
    let album = element("files.item.496")
    XCTAssertTrue(album.appears(within: 10), "the album folder never appeared")
    app.bringIntoView(album)
    album.tap()
    let cover = element("files.item.497")
    XCTAssertTrue(cover.appears(within: 10), "the album never loaded")
    cover.tap()
    XCTAssertTrue(app.images["Album Cover.png"].appears(within: 10))

    removeShownFile(row: "Move to trash")
    let limit = app.alerts["We couldn’t send these files to trash"]
    XCTAssertTrue(limit.appears(within: 10), "the refused Trash move did not ask")
    XCTAssertTrue(
      limit.staticTexts["This folder contains too many files. Delete it permanently?"].exists)
    XCTAssertFalse(app.buttons["Undo"].exists, "the refused Trash move offered Undo")
    screenshot("runtime-preview-trash-limit")
    limit.buttons["Cancel"].firstMatch.tap()
    XCTAssertTrue(limit.disappears(within: 5))
    XCTAssertTrue(element("preview.screen.497").exists, "Cancel closed the viewer")

    removeShownFile(row: "Move to trash")
    XCTAssertTrue(limit.appears(within: 10))
    limit.buttons["Delete permanently"].firstMatch.tap()
    XCTAssertTrue(element("preview.screen.497").disappears(within: 10), "the viewer stayed open")
    XCTAssertTrue(app.staticTexts["Item deleted"].appears(within: 5), "no delete message")
    XCTAssertFalse(app.buttons["Undo"].exists, "a permanent delete offers Undo")
    XCTAssertTrue(cover.disappears(within: 10), "the folder kept the file")
    signOutFromFiles()
  }

  private func openGalleryImage(_ id: Int, title: String) {
    let gallery = app.revealed("files.item.470", maximumSwipes: 8)
    XCTAssertTrue(gallery.exists, "the gallery folder never appeared")
    gallery.tap()
    let row = element("files.item.\(id)")
    XCTAssertTrue(row.appears(within: 10), "row \(id) never appeared")
    row.tap()
    XCTAssertTrue(app.images[title].appears(within: 10), "\(title) never loaded")
  }

  private func removeShownFile(row: String) {
    let more = app.buttons["preview.more"]
    XCTAssertTrue(more.isEnabled, "More is disabled")
    more.tap()
    let button = app.buttons[row].firstMatch
    XCTAssertTrue(button.appears(within: 5), "More has no \(row)")
    XCTAssertTrue(button.isEnabled, "\(row) is disabled")
    button.tap()
  }

  func testShareFetchesCancelsRetriesAndSharesDownloads() {
    app.launch()
    signIn()
    let requests = element("preview.requests")

    shareFromMenu(rowID: 406, sharing: "Harness Poster.png", capture: "image")
    XCTAssertTrue(waitForValue(requests, "406:shared"), "\(requests.value ?? "")")
    shareFromMenu(rowID: 413, sharing: "Document.pdf", capture: "document")
    XCTAssertTrue(waitForValue(requests, "406:shared,413:shared"), "\(requests.value ?? "")")

    assertNoShare(rowID: 430, capture: "over-cap")
    assertNoShare(rowID: 409)

    let held = app.revealed("files.item.428")
    openMenu(on: held).tap()
    let preparing = app.staticTexts["Preparing…"]
    XCTAssertTrue(preparing.appears(within: 5), "the fetch showed no Preparing toast")
    screenshot("runtime-share-preparing")
    app.buttons["Cancel"].firstMatch.tap()
    XCTAssertTrue(
      waitForValue(requests, "406:shared,413:shared,428:cancelled"),
      "Cancel did not stop the fetch: \(requests.value ?? "")")
    XCTAssertFalse(app.otherElements["ActivityListView"].exists)

    openMenu(on: held).tap()
    let failed = app.staticTexts["Couldn’t load this"]
    XCTAssertTrue(failed.appears(within: 10), "the failed fetch showed no toast")
    XCTAssertTrue(held.exists, "the failed fetch changed the list")
    screenshot("runtime-share-failed")
    let sheet = app.openShareSheet(
      from: app.buttons["Try again"].firstMatch, sharing: longPreviewName, anchoredTo: held)
    app.dismissShareSheet(sheet)
    XCTAssertTrue(
      waitForValue(requests, "406:shared,413:shared,428:cancelled,428:failed,428:shared"),
      "Try again did not share: \(requests.value ?? "")")

    let track = app.revealed("files.item.408")
    openMenu(on: track, action: "Download").tap()
    let downloads = app.buttons["Downloads"].firstMatch
    app.scrollDown(toHit: downloads)
    downloads.tap()
    let downloaded = element("downloads.item.408")
    XCTAssertTrue(
      waitForValue(downloaded, "completed", timeout: 60), "the track never finished downloading")
    app.buttons["Files"].firstMatch.tap()
    let shared = requests.value as? String
    shareFromMenu(rowID: 408, sharing: "Harness Track.m4a", capture: "downloaded")
    XCTAssertEqual(requests.value as? String, shared, "a downloaded file was fetched again")
  }

  private let longPreviewName = "document-scan-from-the-harness-weekend-2026.png"

  private func openMenu(on row: XCUIElement, action: String = "Share") -> XCUIElement {
    XCTAssertTrue(row.appears(within: 10), "\(row) never appeared")
    revealBelowNavigationBar(row)
    row.press(forDuration: 1)
    let button = app.buttons[action].firstMatch
    XCTAssertTrue(button.appears(within: 5), "the menu has no \(action)")
    return button
  }

  private func shareFromMenu(rowID: Int, sharing name: String, capture: String) {
    let row = app.revealed("files.item.\(rowID)")
    let share = openMenu(on: row)
    screenshot("runtime-share-menu-\(capture)")
    let sheet = app.openShareSheet(from: share, sharing: name, anchoredTo: row)
    screenshot("runtime-share-sheet-\(capture)")
    app.dismissShareSheet(sheet)
  }

  private func assertNoShare(rowID: Int, capture: String? = nil) {
    let row = app.revealed("files.item.\(rowID)")
    XCTAssertTrue(row.appears(within: 10), "row \(rowID) never appeared")
    revealBelowNavigationBar(row)
    row.press(forDuration: 1)
    XCTAssertTrue(app.buttons["Select"].firstMatch.appears(within: 5), "the menu never opened")
    XCTAssertFalse(app.buttons["Share"].exists, "row \(rowID) offers Share")
    if let capture { screenshot("runtime-share-menu-\(capture)") }
    app.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.25)).tap()
    XCTAssertTrue(app.buttons["Select"].firstMatch.disappears(within: 5))
  }

  private func assertMoreMenu() {
    let more = app.buttons["preview.more"]
    XCTAssertTrue(more.isEnabled, "More is disabled")
    more.tap()
    let rename = app.buttons["Rename"].firstMatch
    XCTAssertTrue(rename.appears(within: 5), "More never opened")
    XCTAssertTrue(app.buttons["Move"].firstMatch.exists)
    for absent in ["Play", "Select", "Pin", "Make a copy", "Mark as watched", "Download"] {
      XCTAssertFalse(app.buttons[absent].exists, "More lists \(absent)")
    }
  }

  private func dismissMenu() {
    app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.9)).tap()
    XCTAssertTrue(app.buttons["Rename"].firstMatch.disappears(within: 5))
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
    XCTAssertTrue(app.buttons["preview.more"].isEnabled)
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

  private func signOut() {
    let account = app.buttons["Account"]
    app.scrollDown(toHit: account)
    if !account.exists { app.tabBars.buttons["Files"].firstMatch.tap() }
    XCTAssertTrue(account.appears(within: 5), "the tab bar stayed minimized")
    account.tap()
    let signOut = app.revealed("auth.sign-out")
    XCTAssertTrue(signOut.appears(within: 5))
    if !signOut.isHittable { app.swipeUp() }
    signOut.tap()
    app.confirmSignOut()
    XCTAssertTrue(element("auth.sign-in").appears(within: 10))
  }

  private func signIn() {
    let button = element("auth.sign-in")
    XCTAssertTrue(button.appears(within: 10))
    button.tap()
    XCTAssertTrue(element("files.screen.0").appears(within: 10))
  }

  private func waitForValue(
    _ element: XCUIElement, matching pattern: String, timeout: TimeInterval = 5
  ) -> Bool {
    let expectation = XCTNSPredicateExpectation(
      predicate: NSPredicate(format: "value MATCHES %@", pattern), object: element)
    return XCTWaiter.wait(for: [expectation], timeout: timeout) == .completed
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
