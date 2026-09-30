import XCTest

/// Streams the multi-audio fixture with WebVTT subtitle renditions, shaped the
/// way put.io serves them for the account's subtitle preferences.
final class SubtitlesJourneyTests: XCTestCase {
  private var app: XCUIApplication!

  override func setUpWithError() throws {
    try super.setUpWithError()
    continueAfterFailure = false
    app = XCUIApplication()
    app.launchArguments = [
      "--putio-harness-scenario", "files-browser", "--putio-harness-subtitled-stream",
      "--putio-harness-playback-preferences", "--putio-harness-reset-file-preferences",
    ]
    app.launchEnvironment["PUTIO_HARNESS_MEDIA_BASE_URL"] = try XCTUnwrap(
      ProcessInfo.processInfo.environment["PUTIO_HARNESS_MEDIA_BASE_URL"])
  }

  func testSystemMenuSelectsSubtitlesWithoutChangingAudioAndFollowsPreferences() throws {
    app.launch()
    let signIn = element("auth.sign-in")
    XCTAssertTrue(signIn.waitForExistence(timeout: 10))
    signIn.tap()
    XCTAssertTrue(element("files.screen.0").waitForExistence(timeout: 10))

    // Default preferences: the subtitle put.io marks as default is on.
    openVideo(retryingSeededFailure: true)
    let audio = element("video.audio-language")
    let subtitle = element("video.subtitle")
    XCTAssertTrue(waitForValue(audio, "en"), "audio: \(audio.value ?? "")")
    XCTAssertTrue(
      waitForValue(subtitle, "en"), "the default subtitle was not selected: \(subtitle.value ?? "")"
    )
    pausePlayback()

    // A non-default audio pick survives every subtitle change.
    openPlayerMenu("Audio Track")
    XCTAssertTrue(app.buttons["English"].waitForExistence(timeout: 5))
    app.buttons["Turkish"].tap()
    XCTAssertTrue(waitForValue(audio, "tr"), "audio: \(audio.value ?? "")")
    XCTAssertTrue(keepsValue(subtitle, "en"), "changing the audio changed the subtitle")

    openPlayerMenu("Subtitles")
    XCTAssertTrue(app.buttons["AVSubtitlesOnAction"].waitForExistence(timeout: 5))
    XCTAssertTrue(app.buttons["AVSubtitlesOffAction"].exists)
    app.buttons["AVLanguagesMenu"].tap()
    let turkishSubtitle = app.buttons["Turkish"]
    XCTAssertTrue(turkishSubtitle.waitForExistence(timeout: 5))
    XCTAssertTrue(app.buttons["English"].exists)
    screenshot("runtime-subtitles-menu")
    turkishSubtitle.tap()
    XCTAssertTrue(waitForValue(subtitle, "tr"), "subtitle: \(subtitle.value ?? "")")
    XCTAssertTrue(keepsValue(audio, "tr"), "enabling subtitles changed the audio track")
    // Cues render during playback, not on the paused frame, and are not
    // exposed to accessibility; the screenshot records the rendered cue.
    let position = element("video.current-position")
    let pausedAt = position.value as? String ?? ""
    let playPause = app.buttons["Play/Pause"]
    showControls(revealing: playPause)
    playPause.tap()
    XCTAssertTrue(
      waitFor(NSPredicate(format: "value != %@", pausedAt), position, timeout: 10),
      "playback did not resume")
    screenshot("runtime-subtitles-selected")
    pausePlayback()

    // Subtitles in a language other than the audio's leave the audio alone.
    openPlayerMenu("Subtitles")
    app.buttons["AVLanguagesMenu"].tap()
    let englishSubtitle = app.buttons["English"]
    XCTAssertTrue(englishSubtitle.waitForExistence(timeout: 5))
    englishSubtitle.tap()
    XCTAssertTrue(waitForValue(subtitle, "en"), "subtitle: \(subtitle.value ?? "")")
    XCTAssertTrue(keepsValue(audio, "tr"), "English subtitles changed the audio track")

    openPlayerMenu("Subtitles")
    let off = app.buttons["AVSubtitlesOffAction"]
    XCTAssertTrue(off.waitForExistence(timeout: 5))
    off.tap()
    XCTAssertTrue(waitForValue(subtitle, "off"), "subtitle: \(subtitle.value ?? "")")
    XCTAssertTrue(keepsValue(audio, "tr"), "turning subtitles off changed the audio track")
    element("video.done").tap()

    // "Do not select subtitles by default": the tracks stay offered, none is on.
    setPlaybackToggle("playback-settings.subtitle-selection", to: "1", retryingSeededFailure: true)
    openVideo(retryingSeededFailure: false)
    XCTAssertTrue(waitForValue(subtitle, "off"), "subtitle: \(subtitle.value ?? "")")
    XCTAssertTrue(waitForValue(audio, "en"), "audio: \(audio.value ?? "")")
    element("video.done").tap()

    // Hidden subtitles: put.io serves no subtitle renditions.
    setPlaybackToggle("playback-settings.subtitles", to: "0", retryingSeededFailure: false)
    openVideo(retryingSeededFailure: false)
    XCTAssertTrue(waitForValue(subtitle, "unavailable"), "subtitle: \(subtitle.value ?? "")")
    XCTAssertTrue(waitForValue(audio, "en"), "audio: \(audio.value ?? "")")
    element("video.done").tap()

    app.buttons["Account"].tap()
    app.navigationBars.buttons["BackButton"].tap()
    let signOut = app.revealed("auth.sign-out")
    XCTAssertTrue(signOut.waitForExistence(timeout: 5))
    if !signOut.isHittable { app.swipeUp() }
    signOut.tap()
    XCTAssertTrue(signIn.waitForExistence(timeout: 10))
  }

  /// The seeded scenario fails the first playback attempt for retry proof.
  private func openVideo(retryingSeededFailure: Bool) {
    app.buttons["Files"].tap()
    let video = element("files.item.412")
    XCTAssertTrue(video.waitForExistence(timeout: 10))
    video.tap()
    if retryingSeededFailure {
      XCTAssertTrue(element("video.error").waitForExistence(timeout: 10))
      app.buttons["Try again"].tap()
    }
    XCTAssertTrue(element("video.ready").waitForExistence(timeout: 15))
  }

  /// The fixture lasts 20 seconds; pausing keeps the menus clear of the
  /// end-of-video suggestion.
  private func pausePlayback() {
    let position = element("video.current-position")
    XCTAssertTrue(position.waitForExistence(timeout: 10))
    let advanced = XCTNSPredicateExpectation(
      predicate: NSPredicate(format: "value != '0'"), object: position)
    XCTAssertEqual(XCTWaiter.wait(for: [advanced], timeout: 10), .completed)
    let playPause = app.buttons["Play/Pause"]
    showControls(revealing: playPause)
    if playPause.label == "Pause" { playPause.tap() }
    XCTAssertTrue(
      waitFor(NSPredicate(format: "label == 'Play'"), playPause, timeout: 5),
      "playback did not pause")
  }

  private func openPlayerMenu(_ entry: String) {
    let more = app.buttons["Overflow Menu"]
    showControls(revealing: more)
    more.tap()
    let item = app.buttons[entry]
    XCTAssertTrue(item.waitForExistence(timeout: 5), "\(entry) is missing from the player menu")
    item.tap()
  }

  /// Player controls hide on their own; a tap on the video brings them back.
  private func showControls(revealing control: XCUIElement) {
    if control.exists, control.isHittable { return }
    element("video.system-player").tap()
    XCTAssertTrue(
      waitFor(NSPredicate(format: "hittable == true"), control, timeout: 5),
      "player controls did not appear")
  }

  /// The playback-preferences fixture fails the first account save once.
  private func setPlaybackToggle(
    _ identifier: String, to value: String, retryingSeededFailure: Bool
  ) {
    app.buttons["Account"].tap()
    let entry = element("account.playback-preferences")
    if entry.waitForExistence(timeout: 5) { entry.tap() }
    let toggle = app.switches[identifier]
    XCTAssertTrue(
      waitFor(NSPredicate(format: "hittable == true AND enabled == true"), toggle, timeout: 10))
    // Form exposes the full row as the switch accessibility frame.
    toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
    if retryingSeededFailure {
      let retry = app.buttons["playback-settings.retry-save"]
      XCTAssertTrue(retry.waitForExistence(timeout: 10))
      retry.tap()
    }
    XCTAssertTrue(
      waitFor(NSPredicate(format: "value == %@ AND enabled == true", value), toggle, timeout: 10),
      "\(identifier) did not save \(value)")
  }

  private func waitForValue(_ element: XCUIElement, _ value: String) -> Bool {
    waitFor(NSPredicate(format: "value == %@", value), element, timeout: 10)
  }

  /// The probe already held `value` before the change, and audio and subtitle
  /// reports land independently, so the value must also hold through a settle
  /// window after the other probe moved.
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
