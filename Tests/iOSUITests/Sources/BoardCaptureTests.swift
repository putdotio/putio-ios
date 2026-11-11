import XCTest

final class BoardCaptureTests: XCTestCase {
  private var app: XCUIApplication!

  override func setUpWithError() throws {
    try super.setUpWithError()
    continueAfterFailure = false
    app = XCUIApplication()
    app.launchArguments = ["--putio-harness-scenario", "signed-in"]
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

  private func openHarnessFolder() {
    let root = element("files.screen.0")
    XCTAssertTrue(root.appears(within: 15), "seeded session did not restore to Files")
    let folder = element("files.item.410")
    XCTAssertTrue(folder.appears(within: 10), "seeded folder row never appeared")
    folder.tap()
    XCTAssertTrue(element("files.screen.410").appears(within: 10), "folder did not open")
  }

  private func captureBoard(_ board: String) throws {
    let screenshot = XCUIScreen.main.screenshot()
    let image = XCTAttachment(screenshot: screenshot)
    image.name = board
    image.lifetime = .keepAlways
    add(image)

    let window = app.windows.firstMatch.frame
    let layout = try JSONSerialization.data(
      withJSONObject: [
        "width": Double(window.width),
        "height": Double(window.height),
        "scale": Double(screenshot.image.scale),
      ],
      options: [.sortedKeys])
    let data = XCTAttachment(data: layout, uniformTypeIdentifier: "public.json")
    data.name = "\(board).layout"
    data.lifetime = .keepAlways
    add(data)
  }

  private func element(_ identifier: String) -> XCUIElement {
    app.descendants(matching: .any)[identifier]
  }
}
