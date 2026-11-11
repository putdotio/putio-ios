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
    let beforeLaunch = try screenshot()
    let signedOut = try launch(scenario: "signed-out", replacing: beforeLaunch)
    XCTAssertTrue(
      app.descendants(matching: .any)["auth.sign-in"].appears(within: 10),
      "the signed-out launch did not render sign-in")

    app.terminate()
    _ = try launch(scenario: "exercised", replacing: signedOut)
    XCTAssertTrue(
      app.staticTexts["Harness exercise complete"].appears(within: 12),
      "the app did not signal the harness exercise")

    let deadline = Date.now.addingTimeInterval(1)
    while Date.now < deadline {
      XCTAssertEqual(app.state, .runningForeground, "the app exited while it should stay running")
      RunLoop.current.run(until: min(deadline, Date.now.addingTimeInterval(0.25)))
    }
  }

  private func launch(scenario: String, replacing previous: Screenshot) throws -> Screenshot {
    app.launchArguments = ["--putio-harness-scenario", scenario]
    app.launch()
    let deadline = Date.now.addingTimeInterval(30)
    repeat {
      XCTAssertEqual(
        app.state, .runningForeground,
        "the \(scenario) launch exited before its first rendered frame")
      let frame = try screenshot()
      if frame.bytes != previous.bytes, frame.hasVisibleContent { return frame }
      RunLoop.current.run(until: Date.now.addingTimeInterval(0.25))
    } while Date.now < deadline
    throw LaunchFailure(
      description: "the \(scenario) launch did not change the screen to visible content in 30 s")
  }

  private func screenshot() throws -> Screenshot {
    let image = try XCTUnwrap(XCUIScreen.main.screenshot().image.cgImage)
    var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
    let drawn = bytes.withUnsafeMutableBytes { buffer -> Bool in
      guard
        let context = CGContext(
          data: buffer.baseAddress, width: image.width, height: image.height,
          bitsPerComponent: 8, bytesPerRow: image.width * 4,
          space: CGColorSpaceCreateDeviceRGB(),
          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            | CGBitmapInfo.byteOrder32Big.rawValue)
      else { return false }
      context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
      return true
    }
    XCTAssertTrue(drawn, "could not rasterize the screenshot")
    return Screenshot(bytes: bytes, width: image.width, height: image.height)
  }
}

private struct LaunchFailure: Error, CustomStringConvertible {
  let description: String
}

private struct Screenshot {
  let bytes: [UInt8]
  let width: Int
  let height: Int

  var hasVisibleContent: Bool {
    let columns = (width / 10)..<(width * 9 / 10)
    let rows = (height / 5)..<(height * 4 / 5)
    let minimum = max(128, columns.count * rows.count / 1_000)
    var visible = 0
    for y in rows {
      for x in columns {
        let index = (y * width + x) * 4
        if max(bytes[index], bytes[index + 1], bytes[index + 2]) >= 48 {
          visible += 1
          if visible >= minimum { return true }
        }
      }
    }
    return false
  }
}
