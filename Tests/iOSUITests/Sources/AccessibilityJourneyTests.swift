import UIKit
import XCTest

final class AccessibilityJourneyTests: XCTestCase {
  private var app: XCUIApplication!
  private var settings: XCUIApplication?
  private var originalReduceMotion: Bool?

  override func setUpWithError() throws {
    try super.setUpWithError()
    continueAfterFailure = false
    XCUIDevice.shared.orientation = .portrait
    let settings = XCUIApplication(bundleIdentifier: "com.apple.Preferences")
    self.settings = settings
    settings.launch()
    let reduceMotion = try reduceMotionSwitch(in: settings)
    let originalValue = try XCTUnwrap(reduceMotion.value as? String)
    XCTAssertTrue(["0", "1"].contains(originalValue))
    originalReduceMotion = originalValue == "1"
    if originalValue == "0" { tapSwitch(reduceMotion) }
    XCTAssertTrue(waitForValue(reduceMotion, "1"))
    app = XCUIApplication()
    app.launchArguments = [
      "--putio-harness-scenario", "files-browser", "--putio-harness-accessibility",
    ]
    app.launchEnvironment["PUTIO_HARNESS_MEDIA_BASE_URL"] = try XCTUnwrap(
      ProcessInfo.processInfo.environment["PUTIO_HARNESS_MEDIA_BASE_URL"])
    app.launch()
    let configuration = element("harness.accessibility")
    XCTAssertTrue(configuration.waitForExistence(timeout: 10))
    XCTAssertEqual(configuration.value as? String, "text=accessibility5;reduce-motion=true")
    let signIn = app.buttons["auth.sign-in"]
    XCTAssertTrue(signIn.waitForExistence(timeout: 10))
    signIn.tap()
    XCTAssertTrue(element("files.screen.0").waitForExistence(timeout: 10))
  }

  override func tearDownWithError() throws {
    XCUIDevice.shared.orientation = .portrait
    app?.terminate()
    app = nil
    defer { settings?.terminate() }
    if let settings, let originalReduceMotion {
      settings.activate()
      let reduceMotion = try reduceMotionSwitch(in: settings)
      let originalValue = originalReduceMotion ? "1" : "0"
      if reduceMotion.value as? String != originalValue { tapSwitch(reduceMotion) }
      XCTAssertTrue(waitForValue(reduceMotion, originalValue))
    }
    try super.tearDownWithError()
  }

  func testLongNamesSelectionAndDownloadPickerAtLargestTextSize() {
    let name = "Accessible archive with a very long name preserving the final chapter number 12345"
    app.buttons["files.menu"].tap()
    app.buttons["files.new-folder"].tap()
    let field = element("files.action-name")
    XCTAssertTrue(field.waitForExistence(timeout: 5))
    field.tap()
    field.typeText(name)
    app.buttons["files.action-submit"].tap()
    let folder = reachable(element("files.item.415"))
    XCTAssertEqual(folder.label, name)
    centerRow(folder)
    screenshot("runtime-accessibility-files")

    app.buttons["files.menu"].tap()
    app.buttons["files.selection.toggle"].tap()
    _ = reachable(folder)
    XCTAssertTrue(waitForValue(folder, "Not selected"))
    reachable(folder).tap()
    XCTAssertTrue(waitForValue(folder, "Selected"))
    XCTAssertEqual(folder.label, name)
    XCTAssertTrue(reachable(app.buttons["files.bulk.remove"]).isEnabled)
    centerRow(folder)
    screenshot("runtime-accessibility-selection")
    app.buttons["files.selection.toggle"].tap()

    selectTab("Downloads")
    XCTAssertTrue(app.staticTexts["No downloads"].waitForExistence(timeout: 5))
    screenshot("runtime-accessibility-downloads")
    selectTab("Files")
    reachable(element("files.item.412")).press(forDuration: 1)
    let download = app.buttons["files.download.412"]
    XCTAssertTrue(download.waitForExistence(timeout: 5))
    download.tap()
    let track = element("downloads.track.en")
    XCTAssertTrue(track.waitForExistence(timeout: 20))
    XCTAssertTrue(app.staticTexts["English"].exists)
    XCTAssertTrue(reachable(app.buttons["downloads.picker.confirm"]).isEnabled)
    screenshot("runtime-accessibility-download-picker")
    app.buttons["downloads.picker.cancel"].tap()
    XCTAssertTrue(element("files.screen.0").waitForExistence(timeout: 5))
    signOut()
  }

  func testAudioSliderAndControlsAtLargestTextSizeInBothOrientations() {
    reachable(element("files.item.408")).tap()
    let state = element("audio.state")
    XCTAssertTrue(waitForValue(state, "id=408;state=playing", timeout: 15))
    let playPause = app.buttons["audio.play-pause"]
    reachable(playPause).tap()
    XCTAssertTrue(waitForValue(state, "id=408;state=paused"))
    XCTAssertEqual(playPause.label, "Play")

    for (orientation, name) in [
      (UIDeviceOrientation.portrait, "runtime-accessibility-audio-portrait"),
      (.landscapeLeft, "runtime-accessibility-audio-landscape"),
    ] {
      XCUIDevice.shared.orientation = orientation
      let rotated = XCTNSPredicateExpectation(
        predicate: NSPredicate { _, _ in
          let frame = self.app.frame
          return orientation.isLandscape ? frame.width > frame.height : frame.height > frame.width
        }, object: app)
      XCTAssertEqual(XCTWaiter.wait(for: [rotated], timeout: 5), .completed)
      let slider = reachable(app.sliders["audio.scrubber"])
      XCTAssertEqual(slider.label, "Playback position")
      XCTAssertTrue(slider.isEnabled)
      let previousElapsed = element("audio.elapsed").label
      // XCUITest drives a drag here; this does not exercise VoiceOver gestures.
      slider.adjust(toNormalizedSliderPosition: orientation == .portrait ? 0.4 : 0.7)
      let seek = XCTNSPredicateExpectation(
        predicate: NSPredicate(format: "label != %@", previousElapsed),
        object: element("audio.elapsed"))
      XCTAssertEqual(XCTWaiter.wait(for: [seek], timeout: 5), .completed)
      XCTAssertTrue(waitForValue(state, "id=408;state=paused"))
      screenshot(name)
      for identifier in ["audio.speed", "audio.play-pause", "audio.next", "audio.done"] {
        let control = reachable(app.buttons[identifier])
        XCTAssertTrue(control.isEnabled, "Disabled audio control: \(identifier)")
        XCTAssertFalse(control.label.isEmpty)
        XCTAssertGreaterThanOrEqual(control.frame.minX, 0)
        XCTAssertLessThanOrEqual(control.frame.maxX, app.frame.width)
      }
      screenshot(name + "-controls")
    }
    app.buttons["audio.done"].tap()
    XCTAssertTrue(element("files.screen.0").waitForExistence(timeout: 5))
    signOut()
  }

  private func element(_ identifier: String) -> XCUIElement {
    app.descendants(matching: .any)[identifier]
  }

  private func selectTab(_ name: String) {
    let tab = app.buttons[name]
    if !tab.exists {
      app.tabBars.buttons.matching(NSPredicate(format: "selected == true")).firstMatch.tap()
    }
    XCTAssertTrue(tab.waitForExistence(timeout: 5))
    tab.tap()
  }

  private func signOut() {
    XCUIDevice.shared.orientation = .portrait
    selectTab("Account")
    reachable(app.buttons["auth.sign-out"], maximumSwipes: 12).tap()
    XCTAssertTrue(app.buttons["auth.sign-in"].waitForExistence(timeout: 10))
  }

  private func reduceMotionSwitch(in settings: XCUIApplication) throws -> XCUIElement {
    let toggle = settings.switches["Reduce Motion"]
    if toggle.waitForExistence(timeout: 2) { return toggle }
    let motion = settings.staticTexts["Motion"].firstMatch
    if !motion.exists {
      let accessibility = settings.staticTexts["Accessibility"].firstMatch
      for _ in 0..<5 {
        if accessibility.exists && accessibility.isHittable { break }
        settings.swipeUp()
      }
      XCTAssertTrue(accessibility.exists && accessibility.isHittable)
      accessibility.tap()
    }
    XCTAssertTrue(motion.waitForExistence(timeout: 5))
    if !motion.isHittable { settings.swipeUp() }
    motion.tap()
    XCTAssertTrue(toggle.waitForExistence(timeout: 5))
    return toggle
  }

  private func tapSwitch(_ toggle: XCUIElement) {
    // Settings exposes the whole row as a switch; its center is the label.
    toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
  }

  private func reachable(_ target: XCUIElement, maximumSwipes: Int = 4) -> XCUIElement {
    let scroll = app.scrollViews.firstMatch
    let collection = app.collectionViews.firstMatch
    let surface: XCUIElement = scroll.exists ? scroll : (collection.exists ? collection : app)
    for _ in 0..<maximumSwipes {
      if target.exists && target.isHittable { return target }
      surface.swipeUp()
    }
    for _ in 0..<maximumSwipes {
      if target.exists && target.isHittable { return target }
      surface.swipeDown()
    }
    XCTAssertTrue(target.exists && target.isHittable, "Target remained unreachable after scrolling")
    return target
  }

  private func centerRow(_ row: XCUIElement) {
    _ = reachable(row)
    let top = app.navigationBars.firstMatch.frame.maxY + 8
    let bottom = app.frame.maxY - 100
    for _ in 0..<4 {
      let frame = row.frame
      if frame.minY >= top && frame.maxY <= bottom { return }
      let center = (top + bottom) / 2
      let shift = min(max(frame.midY - center, -150), 150)
      let origin = app.coordinate(withNormalizedOffset: .zero)
      let start = origin.withOffset(CGVector(dx: app.frame.midX, dy: center))
      let end = origin.withOffset(CGVector(dx: app.frame.midX, dy: center - shift))
      start.press(forDuration: 0.05, thenDragTo: end)
    }
    XCTAssertGreaterThanOrEqual(row.frame.minY, top)
    XCTAssertLessThanOrEqual(row.frame.maxY, bottom)
  }

  private func waitForValue(_ target: XCUIElement, _ value: String, timeout: TimeInterval = 5)
    -> Bool
  {
    let expectation = XCTNSPredicateExpectation(
      predicate: NSPredicate(format: "value == %@", value), object: target)
    return XCTWaiter.wait(for: [expectation], timeout: timeout) == .completed
  }

  private func screenshot(_ name: String) {
    let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
    attachment.name = name
    attachment.lifetime = .keepAlways
    add(attachment)
  }
}
