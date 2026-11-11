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
    openHarnessFolder()
    try captureBoard("rd-ios-02-folder")
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
    openHarnessFolder()
    let toggle = sidebarToggle()
    XCTAssertTrue(toggle.appears(within: 5), "the top tabs have no sidebar button")
    toggle.tap()
    XCTAssertTrue(element("shell.storage").appears(within: 5))
    sidebarToggle().tap()
    XCTAssertTrue(
      element("shell.storage").becomesUnhittable(within: 5), "the sidebar did not close")
    XCUIDevice.shared.orientation = .portrait
    XCTAssertTrue(
      element("files.screen.410").appears(within: 5), "rotating reset the Files path")
    try captureBoard("rd-ios-14-ipad-portrait")
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

  private func reachFilesRoot() {
    let root = element("files.screen.0")
    let folderScreen = element("files.screen.410")
    let signIn = element("auth.sign-in")
    let deadline = Date.now.addingTimeInterval(15)
    while !root.exists, !signIn.exists, !folderScreen.exists, Date.now < deadline {
      _ = root.appears(within: 0.5)
    }
    if signIn.exists { signIn.tap() }
    if folderScreen.exists, !root.isHittable { app.navigationBars.buttons.firstMatch.tap() }
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

  private func captureBoard(_ board: String) throws {
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
