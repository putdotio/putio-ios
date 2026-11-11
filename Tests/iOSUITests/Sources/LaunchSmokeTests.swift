import XCTest

final class LaunchSmokeTests: XCTestCase {
  private var app: XCUIApplication!

  override func setUpWithError() throws {
    try super.setUpWithError()
    continueAfterFailure = false
    app = XCUIApplication()
  }

  override func tearDown() {
    app.terminate()
    super.tearDown()
  }

  func testLaunchRendersAndTheExerciseChangesTheFrameWhileTheAppStaysAlive() throws {
    let beforeLaunch = XCUIScreen.main.screenshot().image
    let signedOut = try launch(scenario: "signed-out", replacing: beforeLaunch)
    XCTAssertTrue(
      app.descendants(matching: .any)["auth.sign-in"].waitForExistence(timeout: 10),
      "the signed-out launch did not render sign-in")

    app.terminate()
    _ = try launch(scenario: "exercised", replacing: signedOut)
    XCTAssertTrue(
      app.staticTexts["Harness exercise complete"].waitForExistence(timeout: 12),
      "the app did not signal the harness exercise")

    let deadline = Date.now.addingTimeInterval(1)
    while Date.now < deadline {
      XCTAssertEqual(app.state, .runningForeground, "the app exited while it should stay running")
      RunLoop.current.run(until: min(deadline, Date.now.addingTimeInterval(0.25)))
    }
  }

  private func launch(scenario: String, replacing previous: UIImage) throws -> UIImage {
    app.launchArguments = ["--putio-harness-scenario", scenario]
    app.launch()
    let previousBytes = try rgba(of: previous).bytes
    let deadline = Date.now.addingTimeInterval(30)
    repeat {
      XCTAssertEqual(
        app.state, .runningForeground,
        "the \(scenario) launch exited before its first rendered frame")
      let frame = XCUIScreen.main.screenshot().image
      let pixels = try rgba(of: frame)
      if pixels.bytes != previousBytes, hasVisibleContent(pixels) {
        return frame
      }
      RunLoop.current.run(until: Date.now.addingTimeInterval(0.25))
    } while Date.now < deadline
    return try XCTUnwrap(
      nil as UIImage?,
      "the \(scenario) launch did not change the screen to visible content in 30 s")
  }

  private func rgba(of image: UIImage) throws -> (bytes: [UInt8], width: Int, height: Int) {
    let cgImage = try XCTUnwrap(image.cgImage)
    let width = cgImage.width
    let height = cgImage.height
    var bytes = [UInt8](repeating: 0, count: width * height * 4)
    let drawn = bytes.withUnsafeMutableBytes { buffer -> Bool in
      guard
        let context = CGContext(
          data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
          bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            | CGBitmapInfo.byteOrder32Big.rawValue)
      else { return false }
      context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
      return true
    }
    XCTAssertTrue(drawn, "could not rasterize the screenshot")
    return (bytes, width, height)
  }

  private func hasVisibleContent(_ pixels: (bytes: [UInt8], width: Int, height: Int)) -> Bool {
    let columns = (pixels.width / 10)..<(pixels.width * 9 / 10)
    let rows = (pixels.height / 5)..<(pixels.height * 4 / 5)
    let minimum = max(128, columns.count * rows.count / 1_000)
    var visible = 0
    for y in rows {
      for x in columns {
        let index = (y * pixels.width + x) * 4
        if max(pixels.bytes[index], pixels.bytes[index + 1], pixels.bytes[index + 2]) >= 48 {
          visible += 1
          if visible >= minimum { return true }
        }
      }
    }
    return false
  }
}
