import XCTest

final class AudioSpeedJourneyTests: XCTestCase {
  private var app: XCUIApplication!

  override func setUpWithError() throws {
    try super.setUpWithError()
    continueAfterFailure = false
    app = XCUIApplication()
    app.launchArguments = [
      "--putio-harness-scenario", "files-browser", "--putio-harness-subtitled-stream",
    ]
    app.launchEnvironment["PUTIO_HARNESS_MEDIA_BASE_URL"] = try XCTUnwrap(
      ProcessInfo.processInfo.environment["PUTIO_HARNESS_MEDIA_BASE_URL"])
  }

  override func tearDown() {
    XCUIDevice.shared.orientation = .portrait
    super.tearDown()
  }

  func testAudioSwitchesTrackAndSpeedCarriesToTheNextFileAndTheNextLaunch() throws {
    app.launchArguments += ["--putio-harness-audio-tracks", "fast-forward"]
    launchAndSignIn()
    openRootVideo()
    let audio = element("video.audio-language")
    XCTAssertTrue(waitForValue(audio, "en"), "audio: \(audio.value ?? "")")
    pausePlayback()

    openChip("audio")
    let english = element("video.audio.0")
    let turkish = element("video.audio.1")
    XCTAssertTrue(english.appears(within: 5), "the Audio chip opened no menu")
    XCTAssertTrue(english.label.contains("English"), english.label)
    XCTAssertTrue(english.label.contains("AAC · mono"), english.label)
    XCTAssertTrue(turkish.label.contains("Turkish"), turkish.label)
    XCTAssertTrue(turkish.label.contains("AAC · mono"), turkish.label)
    screenshot("runtime-audio-menu")
    turkish.tap()
    XCTAssertTrue(waitForValue(audio, "tr"), "audio: \(audio.value ?? "")")
    let audioChip = element("video.chip.audio")
    XCTAssertTrue(waitForLabel(audioChip, "Audio: Turkish"), audioChip.label)
    let position = element("video.current-position")
    XCTAssertTrue(keepsValue(audio, "tr"), "the player left the Turkish track")

    let speedChip = element("video.chip.speed")
    openChip("speed")
    let fastest = element("video.speed.2.5")
    XCTAssertTrue(fastest.appears(within: 5), "the speed chip opened no menu")
    fastest.tap()
    XCTAssertTrue(waitForLabel(speedChip, "Playback speed 2.5×"), speedChip.label)
    app.closeVideo()

    openNestedMovie()
    XCTAssertEqual(shownLabel(of: speedChip), "Playback speed 2.5×", "the next file lost the speed")
    XCTAssertTrue(position.appears(within: 15), "the next file did not play at 2.5×")
    app.closeVideo()

    app.terminate()
    app.launchArguments.append("--putio-harness-keep-playback-speed")
    launchAndSignIn()
    openRootVideo()
    XCTAssertEqual(
      shownLabel(of: speedChip), "Playback speed 2.5×", "the next launch lost the speed")
    XCTAssertTrue(position.appears(within: 15), "the next launch did not play at 2.5×")
    screenshot("runtime-speed-kept")
    app.closeVideo()
  }

  func testSpeedMenuScrollsInsideTheSafeAreaInLandscape() throws {
    XCUIDevice.shared.orientation = .landscapeLeft
    launchAndSignIn()
    openRootVideo()
    pausePlayback()
    openChip("speed")
    let slowest = element("video.speed.0.25")
    let normal = element("video.speed.1")
    let fastest = element("video.speed.4")
    XCTAssertTrue(slowest.appears(within: 5), "the speed chip opened no menu")
    XCTAssertTrue(slowest.isHittable, "the menu does not start at 0.25×")
    XCTAssertFalse(fastest.isHittable, "the whole list fits, so nothing scrolls")
    let window = app.mainWindow.frame
    for _ in 0..<4 where !fastest.isHittable { normal.swipeUp(velocity: .slow) }
    XCTAssertTrue(fastest.isHittable, "4× never scrolled into view")
    XCTAssertTrue(window.contains(fastest.frame), "4× sits outside the window: \(fastest.frame)")
    screenshot("runtime-speed-menu-scrolled")
    fastest.tap()
    XCTAssertTrue(
      waitForLabel(element("video.chip.speed"), "Playback speed 4×"), "4× did not apply")
  }

  func testOneTrackDisablesTheAudioChipAndAFailedSwitchKeepsThePreviousTrack() throws {
    app.launchArguments += ["--putio-harness-audio-tracks", "one"]
    launchAndSignIn()
    openRootVideo()
    let audio = element("video.audio-language")
    XCTAssertTrue(waitForValue(audio, "en"), "audio: \(audio.value ?? "")")
    pausePlayback()
    let audioChip = element("video.chip.audio")
    app.revealVideoControls(showing: audioChip)
    XCTAssertEqual(audioChip.label, "Audio: English")
    XCTAssertFalse(audioChip.isEnabled, "one audio track left the Audio chip enabled")
    screenshot("runtime-audio-one-track")
    app.closeVideo()

    app.terminate()
    app.launchArguments = app.launchArguments.filter { $0 != "one" } + ["failing"]
    launchAndSignIn()
    openRootVideo()
    XCTAssertTrue(waitForValue(audio, "en"), "audio: \(audio.value ?? "")")
    pausePlayback()
    openChip("audio")
    let turkish = element("video.audio.1")
    XCTAssertTrue(turkish.appears(within: 5), "the menu lacks the failing track")
    turkish.tap()
    let toast = app.staticTexts["Couldn’t switch audio track"]
    XCTAssertTrue(toast.appears(within: 15), "a failed audio switch showed no message")
    screenshot("runtime-audio-switch-failed")
    XCTAssertTrue(keepsValue(audio, "en"), "the failed switch lost the previous track")
    XCTAssertTrue(waitForLabel(audioChip, "Audio: English"), audioChip.label)
    XCTAssertFalse(element("video.error").exists, "the failed switch stopped playback")
    XCTAssertTrue(toast.disappears(within: 15), "the message stayed")
  }

  private func launchAndSignIn() {
    app.launch()
    let signIn = element("auth.sign-in")
    let root = element("files.screen.0")
    if signIn.appears(within: 5) { signIn.tap() }
    for _ in 0..<3 where !root.appears(within: 3) {
      app.scrollDown(toHit: app.tabBars.buttons["Files"].firstMatch)
      app.tabBars.buttons["Files"].firstMatch.tap()
    }
    XCTAssertTrue(root.appears(within: 10))
  }

  private func openRootVideo() {
    app.scrollDown(toHit: app.tabBars.buttons["Files"].firstMatch)
    app.tabBars.buttons["Files"].firstMatch.tap()
    let video = element("files.item.412")
    XCTAssertTrue(video.appears(within: 10))
    video.tap()
    app.answerResumePrompt()
    XCTAssertTrue(element("video.error").appears(within: 10))
    app.buttons["Try again"].tap()
    XCTAssertTrue(element("video.ready").appears(within: 15))
  }

  private func openNestedMovie() {
    app.scrollDown(toHit: app.tabBars.buttons["Files"].firstMatch)
    app.tabBars.buttons["Files"].firstMatch.tap()
    let folder = element("files.item.410")
    XCTAssertTrue(folder.appears(within: 10), "the Harness Folder never appeared")
    folder.tap()
    let video = element("files.item.411")
    XCTAssertTrue(video.appears(within: 10), "the nested video never appeared")
    video.tap()
    XCTAssertTrue(element("video.error").appears(within: 10), "the conversion never failed")
    app.buttons["Try again"].tap()
    let resume = app.buttons["video.resume.resume"].firstMatch
    if resume.appears(within: 10) { resume.tap() }
    XCTAssertTrue(element("video.ready").appears(within: 20), "the nested video never played")
  }

  private func pausePlayback() {
    let position = element("video.current-position")
    XCTAssertTrue(position.appears(within: 10))
    let advanced = XCTNSPredicateExpectation(
      predicate: NSPredicate(format: "value != '0'"), object: position)
    XCTAssertEqual(XCTWaiter.wait(for: [advanced], timeout: 10), .completed)
    setPlaying(false)
  }

  private func setPlaying(_ playing: Bool) {
    let playPause = element("video.play-pause")
    let target = playing ? "Pause" : "Play"
    for _ in 0..<5 {
      _ = playPause.waitForNonExistence(timeout: 5)
      app.mainWindow.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.3)).tap()
      guard playPause.waitForExistence(timeout: 2) else { continue }
      if playPause.label == target { return }
      playPause.tap()
      if waitFor(NSPredicate(format: "label == %@", target), playPause, timeout: 3) { return }
    }
    XCTFail("the player never showed \(target)")
  }

  private func shownLabel(of chip: XCUIElement) -> String? {
    for _ in 0..<15 {
      if chip.exists { return chip.label }
      if !element("video.play-pause").exists {
        app.mainWindow.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.3)).tap()
      }
      _ = chip.waitForExistence(timeout: 1)
    }
    return nil
  }

  private func openChip(_ name: String) {
    let chip = element("video.chip.\(name)")
    let firstRow = element(name == "speed" ? "video.speed.0.25" : "video.\(name).0")
    for _ in 0..<3 {
      app.revealVideoControls(showing: chip)
      chip.tap()
      if firstRow.waitForExistence(timeout: 3) { return }
    }
  }

  private func waitForLabel(_ element: XCUIElement, _ label: String) -> Bool {
    waitFor(NSPredicate(format: "label == %@", label), element, timeout: 10)
  }

  private func waitForValue(_ element: XCUIElement, _ value: String) -> Bool {
    waitFor(NSPredicate(format: "value == %@", value), element, timeout: 10)
  }

  private func keepsValue(_ element: XCUIElement, _ value: String) -> Bool {
    guard waitForValue(element, value) else { return false }
    return !waitFor(NSPredicate(format: "value != %@", value), element, timeout: 3)
  }

  private func waitFor(_ predicate: NSPredicate, _ element: XCUIElement, timeout: TimeInterval)
    -> Bool
  {
    let expectation = XCTNSPredicateExpectation(predicate: predicate, object: element)
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
