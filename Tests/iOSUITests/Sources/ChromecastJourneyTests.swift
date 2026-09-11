import XCTest

final class ChromecastJourneyTests: XCTestCase {
  private var app: XCUIApplication!

  override func setUpWithError() throws {
    try super.setUpWithError()
    continueAfterFailure = false
    app = XCUIApplication()
    app.launchArguments = [
      "--putio-harness-scenario", "files-browser", "--putio-harness-cast-load-fails-once",
    ]
    app.launchEnvironment["PUTIO_HARNESS_MEDIA_BASE_URL"] = try XCTUnwrap(
      ProcessInfo.processInfo.environment["PUTIO_HARNESS_MEDIA_BASE_URL"])
  }

  func testCastSettingsSessionControlsSubtitlesAndPositionSync() throws {
    app.launch()
    signIn()

    // Settings: the first save fails and is retried; the receiver override
    // validates and round-trips through the footer copy.
    app.buttons["Account"].tap()
    let entry = element("account.chromecast")
    XCTAssertTrue(entry.waitForExistence(timeout: 5))
    entry.tap()
    let playbackType = element("cast-settings.playback-type")
    XCTAssertTrue(playbackType.waitForExistence(timeout: 10))
    XCTAssertEqual(playbackType.value as? String, "HLS")
    pick(playbackType, "MP4")
    XCTAssertTrue(element("cast-settings.save-failure").waitForExistence(timeout: 10))
    XCTAssertEqual(playbackType.value as? String, "HLS", "a failed save flipped the local value")
    pick(playbackType, "MP4", expecting: "MP4")
    XCTAssertTrue(element("cast-settings.save-failure").waitForNonExistence(timeout: 5))
    let receiver = element("cast-settings.receiver")
    XCTAssertTrue(receiver.waitForExistence(timeout: 5))
    XCTAssertEqual(receiver.value as? String, "CC1AD845")
    screenshot("runtime-cast-settings")
    app.navigationBars.buttons["BackButton"].tap()

    // Connect through the stub picker from the Files toolbar.
    app.buttons["Files"].tap()
    let castButton = app.buttons["cast.button"]
    XCTAssertTrue(castButton.waitForExistence(timeout: 5))
    castButton.tap()
    let device = app.buttons["cast.picker.device"]
    XCTAssertTrue(device.waitForExistence(timeout: 5))
    device.tap()
    XCTAssertTrue(
      waitUntil(timeout: 5) { castButton.label == "Cast, connected" },
      "session never connected: \(castButton.label)")

    // Tapping a video while connected casts it; the first load fails on the
    // receiver and retry recovers into playing controls.
    let row = element("files.item.412")
    XCTAssertTrue(row.waitForExistence(timeout: 5))
    row.tap()
    let retry = app.buttons["cast.retry"]
    XCTAssertTrue(retry.waitForExistence(timeout: 15))
    XCTAssertTrue(app.staticTexts["Could not cast"].exists)
    XCTAssertFalse(element("video.ready").exists, "the local player opened while casting")
    screenshot("runtime-cast-error")
    retry.tap()
    let toggle = app.buttons["cast.toggle"]
    XCTAssertTrue(toggle.waitForExistence(timeout: 15))
    XCTAssertEqual(toggle.label, "Pause")
    XCTAssertEqual(element("cast.title").label, "Root Movie.mkv")

    // Subtitles: MP4 casting lists put.io subtitles; English is the default.
    let subtitles = element("cast.subtitles")
    XCTAssertTrue(subtitles.waitForExistence(timeout: 5))
    XCTAssertEqual(subtitles.value as? String, "English")
    pick(subtitles, "Turkish · Turkish.srt", expecting: "Turkish")
    pick(subtitles, "Off", expecting: "Off")

    // Transport and the throttled position report (seeded start-from is 589).
    toggle.tap()
    XCTAssertTrue(waitUntil(timeout: 5) { toggle.label == "Play" })
    let reported = element("cast.position-reported")
    XCTAssertTrue(reported.waitForExistence(timeout: 10), "no position report while paused")
    let firstReport = reported.value as? String ?? ""
    let firstSeconds = Int(firstReport.split(separator: "=").last ?? "") ?? 0
    XCTAssertTrue(firstReport.hasPrefix("id=412;seconds="), firstReport)
    XCTAssertGreaterThan(firstSeconds, 589, "report never advanced past the seeded start")
    toggle.tap()
    XCTAssertTrue(waitUntil(timeout: 5) { toggle.label == "Pause" })
    app.buttons["cast.forward"].tap()
    XCTAssertTrue(
      waitUntil(timeout: 10) { (reported.value as? String ?? "") != firstReport },
      "position report did not advance after seeking")
    screenshot("runtime-cast-controls")
    app.buttons["cast.controls.done"].tap()

    // The bar stays above the tabs while casting and reopens the controls.
    let bar = element("cast.bar")
    XCTAssertTrue(bar.waitForExistence(timeout: 5))
    XCTAssertEqual(element("cast.bar.title").label, "Root Movie.mkv")
    XCTAssertTrue(element("cast.bar.status").label.hasPrefix("Playing on Harness TV"))
    app.buttons["Downloads"].tap()
    XCTAssertTrue(bar.waitForExistence(timeout: 5))
    app.buttons["Files"].tap()
    bar.tap()
    XCTAssertTrue(toggle.waitForExistence(timeout: 5))
    tapAction("cast.stop")
    XCTAssertTrue(bar.waitForNonExistence(timeout: 5), "stopping did not clear the bar")

    // Explicit row action while connected, then disconnect drops everything.
    row.press(forDuration: 1)
    let castAction = app.buttons["files.cast.412"]
    XCTAssertTrue(castAction.waitForExistence(timeout: 5))
    castAction.tap()
    XCTAssertTrue(toggle.waitForExistence(timeout: 15))
    tapAction("cast.disconnect")
    XCTAssertTrue(bar.waitForNonExistence(timeout: 5))
    XCTAssertTrue(waitUntil(timeout: 5) { castButton.label == "Cast" })

    // Disconnected: the row opens the local player again. The seeded first
    // local resolution fails by contract; retry reaches the ready player.
    row.tap()
    let videoRetry = app.buttons["video.error"]
    XCTAssertTrue(videoRetry.waitForExistence(timeout: 20))
    videoRetry.tap()
    XCTAssertTrue(element("video.ready").waitForExistence(timeout: 20))
    element("video.done").tap()

    app.buttons["Account"].tap()
    let signOut = element("auth.sign-out")
    XCTAssertTrue(signOut.waitForExistence(timeout: 5))
    if !signOut.isHittable { app.swipeUp() }
    signOut.tap()
    XCTAssertTrue(element("auth.sign-in").waitForExistence(timeout: 10))
  }

  /// Menu pickers occasionally swallow the first item tap while their
  /// presentation settles; one retry keeps the proof about the feature.
  private func pick(_ picker: XCUIElement, _ option: String, expecting value: String? = nil) {
    for attempt in 0..<2 {
      XCTAssertTrue(waitUntilHittable(picker, timeout: 5))
      picker.tap()
      let item = app.buttons[option].firstMatch
      XCTAssertTrue(waitUntilHittable(item, timeout: 5), "\(option) never became hittable")
      item.tap()
      guard let value else { return }
      if waitForValue(picker, value, timeout: 5) { return }
      if item.exists { item.tap() }
      XCTAssertEqual(attempt, 0, "\(option) did not apply: \(picker.value ?? "")")
    }
  }

  private func tapAction(_ identifier: String) {
    let item = app.buttons[identifier]
    XCTAssertTrue(waitUntilHittable(item, timeout: 5), "\(identifier) never became hittable")
    item.tap()
  }

  private func waitUntilHittable(_ element: XCUIElement, timeout: TimeInterval) -> Bool {
    let expectation = XCTNSPredicateExpectation(
      predicate: NSPredicate(format: "hittable == true"), object: element)
    return XCTWaiter.wait(for: [expectation], timeout: timeout) == .completed
  }

  private func signIn() {
    let button = element("auth.sign-in")
    XCTAssertTrue(button.waitForExistence(timeout: 10))
    button.tap()
    XCTAssertTrue(element("files.screen.0").waitForExistence(timeout: 10))
  }

  private func waitUntil(timeout: TimeInterval, _ condition: @escaping () -> Bool) -> Bool {
    let expectation = XCTNSPredicateExpectation(
      predicate: NSPredicate { _, _ in condition() }, object: nil)
    return XCTWaiter.wait(for: [expectation], timeout: timeout) == .completed
  }

  private func waitForValue(_ element: XCUIElement, _ value: String, timeout: TimeInterval)
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
