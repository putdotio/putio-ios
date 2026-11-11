import XCTest

final class LaunchSmokeTests: XCTestCase {
  private let app = XCUIApplication()

  override func setUpWithError() throws {
    try super.setUpWithError()
    continueAfterFailure = false
  }

  func testLaunchRendersAndTheExerciseChangesTheFrameWhileTheAppStaysAlive() throws {
    let beforeLaunch = XCUIScreen.main.screenshot().image
    let signedOut = try launch(scenario: "signed-out", replacing: beforeLaunch)
    XCTAssertTrue(
      app.descendants(matching: .any)["auth.sign-in"].waitForExistence(timeout: 30),
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
    XCTAssertTrue(
      app.wait(for: .runningForeground, timeout: 30),
      "the \(scenario) launch exited before its first rendered frame")
    let previousPixels = try pixels(of: previous)
    let deadline = Date.now.addingTimeInterval(30)
    repeat {
      XCTAssertEqual(app.state, .runningForeground, "the \(scenario) launch exited")
      let frame = XCUIScreen.main.screenshot().image
      let framePixels = try pixels(of: frame)
      if framePixels.bytes != previousPixels.bytes,
        framePixels.visibleContent >= framePixels.minimumContent
      {
        return frame
      }
      RunLoop.current.run(until: Date.now.addingTimeInterval(0.25))
    } while Date.now < deadline
    XCTFail("the \(scenario) launch did not change the screen to visible content within 30 s")
    return previous
  }

  private func pixels(of image: UIImage) throws -> (
    bytes: [UInt8], visibleContent: Int, minimumContent: Int
  ) {
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
    let columns = (width / 10)..<(width * 9 / 10)
    let rows = (height / 5)..<(height * 4 / 5)
    var visibleContent = 0
    for y in rows {
      for x in columns {
        let index = (y * width + x) * 4
        if max(bytes[index], bytes[index + 1], bytes[index + 2]) >= 48 { visibleContent += 1 }
      }
    }
    return (bytes, visibleContent, max(128, columns.count * rows.count / 1_000))
  }
}
