import XCTest

final class BoardCaptureTests: XCTestCase {
  private var app: XCUIApplication!

  override func setUpWithError() throws {
    try super.setUpWithError()
    continueAfterFailure = false
    app = XCUIApplication()
    app.launchArguments = ["--putio-harness-scenario", "files-browser"]
    app.launchEnvironment["PUTIO_HARNESS_MEDIA_BASE_URL"] = try XCTUnwrap(
      ProcessInfo.processInfo.environment["PUTIO_HARNESS_MEDIA_BASE_URL"]
    )
  }

  override func tearDown() {
    XCUIDevice.shared.orientation = .portrait
    super.tearDown()
  }

  func testFolder() throws {
    XCUIDevice.shared.orientation = .portrait
    app.launch()
    openSeasonFolder()
    try captureBoard("rd-ios-02-folder")
  }

  func testRowActions() throws {
    XCUIDevice.shared.orientation = .portrait
    app.launch()
    openSeasonFolder()
    openItemMenu("files.item.442")
    try captureBoard("rd-ios-03-row-actions")
  }

  func testVLCMenu() throws {
    XCUIDevice.shared.orientation = .portrait
    app.launchArguments.append("--putio-harness-vlc-installed")
    app.launch()
    openSeasonFolder()
    openItemMenu("files.item.442")
    XCTAssertTrue(app.buttons["Open in VLC"].exists, "the menu has no Open in VLC")
    try captureBoard("rd-ios-64-vlc-menu")
  }

  func testSwipeActions() throws {
    XCUIDevice.shared.orientation = .portrait
    app.launch()
    openSeasonFolder()
    let row = element("files.item.442")
    XCTAssertTrue(row.appears(within: 5), "the watched episode never appeared")
    row.swipeLeft()
    XCTAssertTrue(app.buttons["Trash"].appears(within: 5), "the swipe showed no Trash")
    try captureBoard("rd-ios-11-swipe")
  }

  func testFolderLongPress() throws {
    XCUIDevice.shared.orientation = .portrait
    app.launch()
    reachFilesRoot()
    openItemMenu("files.item.410")
    try captureBoard("rd-ios-17-folder-long-press")
  }

  func testFileMenu() throws {
    XCUIDevice.shared.orientation = .portrait
    app.launch()
    reachFilesRoot()
    XCTAssertTrue(app.revealed("files.item.407").exists, "the archive row never appeared")
    openItemMenu("files.item.407")
    try captureBoard("rd-ios-63-file-menu")
  }

  func testIPadSplit() throws {
    XCUIDevice.shared.orientation = .landscapeLeft
    app.launch()
    openHarnessFolder()
    try captureBoard("rd-ios-12-ipad-split")
  }

  func testFilesRoot() throws {
    XCUIDevice.shared.orientation = .portrait
    app.launch()
    reachFilesRoot()
    try captureBoard("Main")
  }

  func testHistoryTabHidden() throws {
    XCUIDevice.shared.orientation = .portrait
    app.launchArguments.append("--putio-harness-history-disabled")
    app.launch()
    reachFilesRoot()
    XCTAssertFalse(tabButton("History").exists, "disabled history remained in the tab bar")
    try captureBoard("rd-ios-hist-13-tab-hidden")
  }

  func testIPadSidebar() throws {
    XCUIDevice.shared.orientation = .landscapeLeft
    app.launch()
    openHarnessFolder()
    let toggle = sidebarToggle()
    XCTAssertTrue(toggle.appears(within: 5), "the top tabs have no sidebar button")
    toggle.tap()
    XCTAssertTrue(element("shell.storage").appears(within: 5), "the sidebar has no storage meter")
    XCTAssertTrue(element("files.screen.410").exists, "opening the sidebar reset the Files path")
    try captureBoard("rd-ios-13-ipad-sidebar")
  }

  func testIPadPortrait() throws {
    XCUIDevice.shared.orientation = .landscapeLeft
    app.launch()
    openSeasonFolder()
    let toggle = sidebarToggle()
    XCTAssertTrue(toggle.appears(within: 5), "the top tabs have no sidebar button")
    toggle.tap()
    XCTAssertTrue(element("shell.storage").appears(within: 5))
    sidebarToggle().tap()
    XCTAssertTrue(
      element("shell.storage").becomesUnhittable(within: 5), "the sidebar did not close")
    XCUIDevice.shared.orientation = .portrait
    XCTAssertTrue(
      element("files.screen.440").appears(within: 5), "rotating reset the Files path")
    try captureBoard("rd-ios-14-ipad-portrait")
  }

  func testListDetailNothingSelected() throws {
    XCUIDevice.shared.orientation = .landscapeLeft
    launchListDetailGallery()
    XCTAssertTrue(
      app.staticTexts["No file selected"].appears(within: 5), "the empty detail has no title")
    XCTAssertTrue(app.staticTexts["Tap a file to see it here."].exists)
    XCTAssertFalse(listDetailRow(0).isSelected, "a row is open with nothing selected")
    try captureBoard("gallery-split-ipad-none")
  }

  func testListDetailKeepsSelectionAcrossRotation() throws {
    XCUIDevice.shared.orientation = .landscapeLeft
    launchListDetailGallery()
    let row = listDetailRow(0)
    row.tap()
    assertListDetailOpen(row, "selecting a row")
    XCUIDevice.shared.orientation = .portrait
    assertListDetailOpen(row, "rotating to portrait")
    XCUIDevice.shared.orientation = .landscapeLeft
    assertListDetailOpen(row, "rotating back to landscape")
    XCTAssertFalse(listDetailRow(1).isSelected, "a second row opened")
    try captureBoard("gallery-split-ipad-detail")
  }

  func testPreviewLoading() throws {
    XCUIDevice.shared.orientation = .portrait
    app.launchArguments.append("--putio-harness-previews")
    app.launch()
    openLongPreview()
    XCTAssertTrue(
      element("preview.loading").appears(within: 10), "the preview never showed loading")
    try captureBoard("rd-ios-pv-07-loading")
  }

  func testPreviewError() throws {
    XCUIDevice.shared.orientation = .portrait
    app.launchArguments.append("--putio-harness-previews")
    app.launch()
    openLongPreview()
    XCTAssertTrue(
      element("preview.loading").appears(within: 10), "the preview never showed loading")
    app.buttons["preview.back"].tap()
    XCTAssertTrue(
      element("preview.screen.428").disappears(within: 5), "Back did not close the preview")
    openLongPreview()
    XCTAssertTrue(
      app.staticTexts["Couldn’t load this"].appears(within: 10),
      "the failed load has no error state")
    try captureBoard("rd-ios-pv-08-error")
  }

  func testPreviewCannotShow() throws {
    XCUIDevice.shared.orientation = .portrait
    app.launchArguments.append("--putio-harness-previews")
    app.launch()
    reachFilesRoot()
    let row = app.revealed("files.item.429")
    XCTAssertTrue(row.exists, "the disk image row never appeared")
    row.tap()
    XCTAssertTrue(
      element("preview.cannot-show").appears(within: 10), "the disk image has no cannot-show state")
    try captureBoard("rd-ios-pv-05-unsupported")
  }

  func testPreviewImage() throws {
    XCUIDevice.shared.orientation = .portrait
    openPosterPreview()
    try captureBoard("rd-ios-pv-01-image")
  }

  func testPreviewLandscapeImage() throws {
    XCUIDevice.shared.orientation = .portrait
    openPosterPreview()
    XCUIDevice.shared.orientation = .landscapeLeft
    let window = app.windows.firstMatch
    let deadline = Date.now.addingTimeInterval(10)
    while window.frame.width < window.frame.height, Date.now < deadline {
      RunLoop.current.run(until: Date.now.addingTimeInterval(0.1))
    }
    XCTAssertGreaterThan(window.frame.width, window.frame.height, "the viewer did not rotate")
    XCTAssertTrue(
      app.images["Harness Poster.png"].appears(within: 5), "the image did not settle")
    try captureBoard("rd-ios-pv-13-landscape-image")
  }

  func testPreviewDocument() throws {
    XCUIDevice.shared.orientation = .portrait
    app.launchArguments.append("--putio-harness-previews")
    app.launch()
    reachFilesRoot()
    let row = app.revealed("files.item.413")
    XCTAssertTrue(row.exists, "the document row never appeared")
    row.tap()
    XCTAssertTrue(
      app.staticTexts["put.io harness page 1"].appears(within: 10), "the document never loaded")
    let pill = element("preview.page")
    XCTAssertTrue(pill.appears(within: 5), "the document has no page pill")
    let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.6))
    let end = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.45))
    var drags = 0
    while pill.label != "Page 2 of 12", drags < 12 {
      start.press(forDuration: 0.05, thenDragTo: end)
      drags += 1
    }
    XCTAssertEqual(pill.label, "Page 2 of 12", "the document did not reach page 2")
    try captureBoard("rd-ios-pv-03-pdf")
  }

  func testPreviewText() throws {
    XCUIDevice.shared.orientation = .portrait
    app.launchArguments.append("--putio-harness-previews")
    app.launch()
    openSeasonFolder()
    let row = app.revealed("files.item.445")
    XCTAssertTrue(row.exists, "the subtitle row never appeared")
    row.tap()
    XCTAssertTrue(element("preview.text").appears(within: 10), "the subtitle never loaded")
    try captureBoard("rd-ios-pv-04-text")
  }

  func testPreviewTextTruncated() throws {
    XCUIDevice.shared.orientation = .portrait
    app.launchArguments.append("--putio-harness-previews")
    app.launch()
    reachFilesRoot()
    let row = app.revealed("files.item.432", maximumSwipes: 6)
    XCTAssertTrue(row.exists, "the long text row never appeared")
    row.tap()
    let text = element("preview.text")
    XCTAssertTrue(text.appears(within: 10), "the long text never loaded")
    let notice = element("preview.text.truncated")
    var swipes = 0
    while !notice.isHittable, swipes < 120 {
      text.swipeUp(velocity: XCUIGestureVelocity(12_000))
      swipes += 1
    }
    XCTAssertTrue(notice.isHittable, "scrolling never reached the end line")
    XCTAssertTrue(notice.appears(within: 5))
    try captureBoard("rd-ios-pv-10-text-truncated")
  }

  private func openPosterPreview() {
    app.launchArguments.append("--putio-harness-previews")
    app.launch()
    reachFilesRoot()
    let row = app.revealed("files.item.406")
    XCTAssertTrue(row.exists, "the image row never appeared")
    row.tap()
    XCTAssertTrue(element("preview.image").appears(within: 10), "the image never loaded")
    XCTAssertTrue(
      app.images["Harness Poster.png"].appears(within: 5), "the image did not settle")
  }

  private func openLongPreview() {
    reachFilesRoot()
    let row = element("files.item.428")
    XCTAssertTrue(row.appears(within: 10), "the long-named image row never appeared")
    row.tap()
    XCTAssertTrue(
      element("preview.screen.428").appears(within: 10), "the preview did not open")
  }

  func testAccountTop() throws {
    openAccount()
    try captureBoard("rd-ios-acc-02-account")
  }

  func testAccountPlayback() throws {
    openAccount()
    scrollAccount(untilNearTop: "playback-settings.autoplay")
    try captureBoard("rd-ios-acc-03-account-middle")
  }

  func testAccountSecurity() throws {
    openAccount()
    scrollAccount(untilNearTop: "playback-settings.subtitles")
    try captureBoard("rd-ios-acc-22-account-security")
  }

  func testAccountEnd() throws {
    openAccount()
    let destroy = element("account.destroy-account")
    var swipes = 0
    while !(destroy.exists && destroy.isHittable), swipes < 8 {
      app.swipeUp()
      swipes += 1
    }
    XCTAssertTrue(destroy.appears(within: 5))
    XCTAssertTrue(destroy.isHittable, "the end of Account never scrolled into view")
    try captureBoard("rd-ios-acc-04-account-end")
  }

  func testAnalyticsPrompt() throws {
    XCUIDevice.shared.orientation = .portrait
    launchAnalyticsPrompt()
    try captureBoard("rd-ios-ses-10-analytics")
  }

  func testAnalyticsPromptSaving() throws {
    XCUIDevice.shared.orientation = .portrait
    launchAnalyticsPrompt()
    let allow = app.buttons["analytics-prompt.allow"]
    allow.tap()
    let saving = XCTNSPredicateExpectation(
      predicate: NSPredicate(format: "isEnabled == false"), object: allow)
    XCTAssertEqual(XCTWaiter.wait(for: [saving], timeout: 2), .completed, "Allow never started")
    try captureBoard("rd-ios-ses-17-analytics-saving")
  }

  func testAnalyticsPromptFailed() throws {
    XCUIDevice.shared.orientation = .portrait
    launchAnalyticsPrompt()
    app.buttons["analytics-prompt.allow"].tap()
    XCTAssertTrue(
      element("analytics-prompt.failure").appears(within: 10), "the first save never failed")
    try captureBoard("rd-ios-ses-18-analytics-failed")
  }

  func testIPadAnalyticsPrompt() throws {
    XCUIDevice.shared.orientation = .landscapeLeft
    launchAnalyticsPrompt()
    try captureBoard("rd-ios-ses-25-ipad-analytics")
  }

  func testGalleryPage() throws {
    let environment = ProcessInfo.processInfo.environment
    let board = try XCTUnwrap(environment["PUTIO_BOARD_ID"])
    let page = try XCTUnwrap(environment["PUTIO_GALLERY_PAGE"])
    XCUIDevice.shared.orientation = .portrait
    app.launchArguments = [
      "--putio-harness-scenario", "gallery", "--putio-harness-gallery-page", page,
    ]
    app.launch()
    XCTAssertTrue(app.staticTexts.firstMatch.appears(within: 15), "gallery page never rendered")
    try captureBoard(board)
  }

  private func launchAnalyticsPrompt() {
    app.launchArguments += [
      "--putio-harness-analytics-prompt", "--putio-harness-file-preferences",
      "--putio-harness-reset-file-preferences",
    ]
    app.launch()
    let prompt = element("analytics-prompt")
    let signIn = element("auth.sign-in")
    let deadline = Date.now.addingTimeInterval(15)
    while !prompt.exists, !signIn.exists, Date.now < deadline {
      _ = prompt.appears(within: 0.5)
    }
    if signIn.exists { signIn.tap() }
    XCTAssertTrue(prompt.appears(within: 15), "the analytics prompt never appeared")
    XCTAssertTrue(
      app.buttons["analytics-prompt.allow"].appears(within: 5), "the prompt has no Allow")
  }

  private static let listDetailFileName = "Blue.Lights.S04E01.1080p.HDTV.H264-ORGANiC.mkv"

  private func launchListDetailGallery() {
    app.launchArguments = [
      "--putio-harness-scenario", "gallery", "--putio-harness-gallery-page", "split",
    ]
    app.launch()
    XCTAssertTrue(listDetailRow(0).appears(within: 15), "the list and detail page never rendered")
  }

  private func listDetailRow(_ index: Int) -> XCUIElement {
    element("gallery.split.row.\(index)").firstMatch
  }

  private func assertListDetailOpen(_ row: XCUIElement, _ step: String) {
    let title = element("gallery.split.detail-title").firstMatch
    XCTAssertTrue(title.appears(within: 5), "no detail after \(step)")
    XCTAssertEqual(title.label, Self.listDetailFileName, "the detail changed after \(step)")
    XCTAssertTrue(row.appears(within: 5), "the list column is hidden after \(step)")
    XCTAssertTrue(row.isSelected, "the open row lost its selection after \(step)")
    XCTAssertFalse(app.staticTexts["No file selected"].exists, "the detail emptied after \(step)")
  }

  private func openAccount() {
    XCUIDevice.shared.orientation = .portrait
    app.launch()
    reachFilesRoot()
    tabButton("Account").tap()
    XCTAssertTrue(element("account.profile").appears(within: 10), "Account never opened")
    XCTAssertTrue(element("account.storage-used").exists, "Account has no storage row")
  }

  private func scrollAccount(untilNearTop identifier: String) {
    let target = element(identifier)
    let window = app.windows.firstMatch.frame
    let ceiling = window.minY + window.height * 0.24
    var steps = 0
    while !(target.exists && target.frame.minY < ceiling), steps < 60 {
      let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.6))
      let end = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.52))
      start.press(forDuration: 0.05, thenDragTo: end, withVelocity: .slow, thenHoldForDuration: 0.3)
      steps += 1
    }
    XCTAssertTrue(target.exists, "\(identifier) never scrolled into view")
    XCTAssertLessThan(target.frame.minY, ceiling, "\(identifier) did not reach the top")
    XCTAssertTrue(target.appears(within: 5))
  }

  private func reachFilesRoot() {
    let root = element("files.screen.0")
    let folderScreens = ["files.screen.410", "files.screen.440"].map(element)
    let signIn = element("auth.sign-in")
    let deadline = Date.now.addingTimeInterval(15)
    while !root.exists, !signIn.exists, !folderScreens.contains(where: \.exists),
      Date.now < deadline
    {
      _ = root.appears(within: 0.5)
    }
    if signIn.exists { signIn.tap() }
    for _ in folderScreens where !root.isHittable && folderScreens.contains(where: \.exists) {
      app.navigationBars.buttons.firstMatch.tap()
      _ = root.appears(within: 2)
    }
    XCTAssertTrue(root.appears(within: 15), "seeded session never reached Files")
  }

  private func tabButton(_ label: String) -> XCUIElement {
    app.buttons.matching(NSPredicate(format: "label == %@", label)).firstMatch
  }

  private func sidebarToggle() -> XCUIElement {
    app.buttons.matching(NSPredicate(format: "label CONTAINS[c] %@", "sidebar")).firstMatch
  }

  private func openHarnessFolder() {
    let root = element("files.screen.0")
    let folderScreen = element("files.screen.410")
    let signIn = element("auth.sign-in")
    let deadline = Date.now.addingTimeInterval(15)
    while !root.exists, !folderScreen.exists, !signIn.exists, Date.now < deadline {
      _ = root.appears(within: 0.5)
    }
    if signIn.exists { signIn.tap() }
    if !folderScreen.exists {
      XCTAssertTrue(root.appears(within: 15), "seeded session never reached Files")
      let folder = element("files.item.410")
      XCTAssertTrue(folder.appears(within: 10), "seeded folder row never appeared")
      folder.tap()
    }
    XCTAssertTrue(folderScreen.appears(within: 10), "folder did not open")
  }

  private func openSeasonFolder() {
    if !element("files.screen.440").appears(within: 5) {
      if !element("files.screen.410").exists { openHarnessFolder() }
      let folder = element("files.item.440")
      XCTAssertTrue(folder.appears(within: 10), "seeded season folder never appeared")
      folder.tap()
    }
    XCTAssertTrue(element("files.header.440").appears(within: 10), "season folder has no header")
  }

  private func openItemMenu(_ identifier: String) {
    let row = element(identifier)
    XCTAssertTrue(row.appears(within: 10), "\(identifier) never appeared")
    row.press(forDuration: 1)
    XCTAssertTrue(app.buttons["Rename"].appears(within: 5), "the item menu never opened")
  }

  private func captureBoard(_ defaultBoard: String) throws {
    let board = ProcessInfo.processInfo.environment["PUTIO_BOARD_ID"] ?? defaultBoard
    try requireBoardDevicePosture()
    if ProcessInfo.processInfo.environment["PUTIO_BOARD_TEXT_AUDIT"] == "1" {
      try app.performAccessibilityAudit(for: .textClipped) { issue in
        guard let element = issue.element else { return false }
        return Self.isMiddleTruncatedFileName(element.label)
          && element.frame.height >= Self.minimumXXLargeLineHeight
      }
    }
    let window = app.windows.firstMatch.frame
    let screen = XCUIScreen.main.screenshot().image
    let capture = Self.oriented(screen, toMatch: window.size)
    let image = XCTAttachment(image: capture)
    image.name = board
    image.lifetime = .keepAlways
    add(image)

    let layout = try JSONSerialization.data(
      withJSONObject: [
        "width": Double(window.width),
        "height": Double(window.height),
        "scale": Double(capture.scale),
      ],
      options: [.sortedKeys])
    let data = XCTAttachment(data: layout, uniformTypeIdentifier: "public.json")
    data.name = "\(board)-layout"
    data.lifetime = .keepAlways
    add(data)
  }

  private func requireBoardDevicePosture() throws {
    guard ProcessInfo.processInfo.environment["PUTIO_BOARD_DEVICE"] == "duo-folded" else { return }
    let window = app.windows.firstMatch
    XCTAssertTrue(window.appears(within: 10), "app window never appeared")
    XCTAssertLessThan(
      window.frame.width, Self.regularWidthThreshold,
      "folded iPhone Duo window is \(window.frame.width) pt wide")
  }

  private static let regularWidthThreshold: CGFloat = 600

  private static func oriented(_ screen: UIImage, toMatch size: CGSize) -> UIImage {
    let upright = UIGraphicsImageRenderer(size: screen.size, format: rendererFormat(screen)).image {
      _ in screen.draw(in: CGRect(origin: .zero, size: screen.size))
    }
    return rotated(upright, toMatch: size)
  }

  private static func rendererFormat(_ image: UIImage) -> UIGraphicsImageRendererFormat {
    let format = UIGraphicsImageRendererFormat()
    format.scale = image.scale
    return format
  }

  private static func rotated(_ image: UIImage, toMatch size: CGSize) -> UIImage {
    let landscapeImage = image.size.width > image.size.height
    guard landscapeImage != (size.width > size.height) else { return image }
    let clockwise = XCUIDevice.shared.orientation == .landscapeRight
    let rotated = CGSize(width: image.size.height, height: image.size.width)
    return UIGraphicsImageRenderer(size: rotated, format: rendererFormat(image)).image {
      context in
      let cg = context.cgContext
      cg.translateBy(x: rotated.width / 2, y: rotated.height / 2)
      cg.rotate(by: clockwise ? .pi / 2 : -.pi / 2)
      image.draw(
        in: CGRect(
          x: -image.size.width / 2, y: -image.size.height / 2, width: image.size.width,
          height: image.size.height))
    }
  }

  private static let minimumXXLargeLineHeight: CGFloat = 24

  private static func isMiddleTruncatedFileName(_ label: String?) -> Bool {
    guard let label, let dot = label.lastIndex(of: "."), dot != label.startIndex else {
      return false
    }
    let fileExtension = label[label.index(after: dot)...]
    return (1...5).contains(fileExtension.count)
      && fileExtension.allSatisfy { $0.isLetter || $0.isNumber }
      && fileExtension.contains(where: \.isLetter)
  }

  private func element(_ identifier: String) -> XCUIElement {
    app.descendants(matching: .any)[identifier]
  }
}
