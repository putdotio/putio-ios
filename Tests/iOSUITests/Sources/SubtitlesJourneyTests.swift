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

  func testPlayerMenuSelectsSubtitlesWithoutChangingAudioAndFollowsPreferences() throws {
    app.launch()
    let signIn = element("auth.sign-in")
    XCTAssertTrue(signIn.appears(within: 10))
    signIn.tap()
    XCTAssertTrue(element("files.screen.0").appears(within: 10))

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
    openChip("audio")
    XCTAssertTrue(app.buttons["English"].appears(within: 5))
    app.buttons["Turkish"].tap()
    XCTAssertTrue(waitForValue(audio, "tr"), "audio: \(audio.value ?? "")")
    XCTAssertTrue(keepsValue(subtitle, "en"), "changing the audio changed the subtitle")

    openChip("subtitles")
    let turkishSubtitle = app.buttons["video.subtitles.1"]
    XCTAssertTrue(turkishSubtitle.appears(within: 5))
    XCTAssertTrue(app.buttons["video.subtitles.0"].exists)
    XCTAssertTrue(app.buttons["video.subtitles.off"].exists)
    screenshot("runtime-subtitles-menu")
    turkishSubtitle.tap()
    XCTAssertTrue(waitForValue(subtitle, "tr"), "subtitle: \(subtitle.value ?? "")")
    XCTAssertTrue(keepsValue(audio, "tr"), "enabling subtitles changed the audio track")
    // Cues render during playback, not on the paused frame, and are not
    // exposed to accessibility; the screenshot records the rendered cue.
    let position = element("video.current-position")
    let pausedAt = position.value as? String ?? ""
    app.setVideoPlaying(true, with: element("video.play-pause"))
    XCTAssertTrue(
      waitFor(NSPredicate(format: "value != %@", pausedAt), position, timeout: 10),
      "playback did not resume")
    screenshot("runtime-subtitles-selected")
    pausePlayback()

    // Subtitles in a language other than the audio's leave the audio alone.
    openChip("subtitles")
    let englishSubtitle = app.buttons["video.subtitles.0"]
    XCTAssertTrue(englishSubtitle.appears(within: 5))
    englishSubtitle.tap()
    XCTAssertTrue(waitForValue(subtitle, "en"), "subtitle: \(subtitle.value ?? "")")
    XCTAssertTrue(keepsValue(audio, "tr"), "English subtitles changed the audio track")

    openChip("subtitles")
    let off = app.buttons["video.subtitles.off"]
    XCTAssertTrue(off.appears(within: 5))
    off.tap()
    XCTAssertTrue(waitForValue(subtitle, "off"), "subtitle: \(subtitle.value ?? "")")
    XCTAssertTrue(keepsValue(audio, "tr"), "turning subtitles off changed the audio track")
    app.closeVideo()
    app.terminate()
    app.launch()
    XCTAssertTrue(element("files.screen.0").appears(within: 15))

    // "Pick matching subtitles" off: the tracks stay offered, none is on.
    setPlaybackToggle("playback-settings.subtitle-selection", to: "0", retryingSeededFailure: true)
    openVideo(retryingSeededFailure: true)
    XCTAssertTrue(waitForValue(subtitle, "off"), "subtitle: \(subtitle.value ?? "")")
    XCTAssertTrue(waitForValue(audio, "en"), "audio: \(audio.value ?? "")")
    app.closeVideo()

    // Hidden subtitles: put.io serves no subtitle renditions.
    setPlaybackToggle("playback-settings.subtitles", to: "0", retryingSeededFailure: false)
    openVideo(retryingSeededFailure: false)
    XCTAssertTrue(waitForValue(subtitle, "unavailable"), "subtitle: \(subtitle.value ?? "")")
    XCTAssertTrue(waitForValue(audio, "en"), "audio: \(audio.value ?? "")")
    app.closeVideo()

    app.buttons["Account"].tap()
    let signOut = app.revealed("auth.sign-out")
    XCTAssertTrue(signOut.appears(within: 5))
    if !signOut.isHittable { app.swipeUp() }
    signOut.tap()
    app.confirmSignOut()
    XCTAssertTrue(signIn.appears(within: 10))
  }

  func testChipsShowTheChoicesAndStayUpWithAMenuBesidePictureInPicture() throws {
    app.launchArguments.append("--putio-harness-picture-in-picture")
    app.launch()
    let signIn = element("auth.sign-in")
    XCTAssertTrue(signIn.appears(within: 10))
    signIn.tap()
    XCTAssertTrue(element("files.screen.0").appears(within: 10))

    openVideo(retryingSeededFailure: true, startingOver: true)
    let audio = element("video.audio-language")
    let subtitle = element("video.subtitle")
    XCTAssertTrue(waitForValue(audio, "en"), "audio: \(audio.value ?? "")")
    XCTAssertTrue(waitForValue(subtitle, "en"), "subtitle: \(subtitle.value ?? "")")

    let audioChip = element("video.chip.audio")
    let subtitlesChip = element("video.chip.subtitles")
    let speedChip = element("video.chip.speed")
    let playPause = element("video.play-pause")
    app.setVideoPlaying(false, with: playPause)
    XCTAssertTrue(waitForLabel(audioChip, "Audio: English"), "the Audio chip is missing")
    XCTAssertTrue(
      waitForLabel(subtitlesChip, "Subtitles: English"), "the Subtitles chip is missing")
    XCTAssertTrue(waitForLabel(speedChip, "Playback speed 1×"), "the speed chip is missing")
    screenshot("runtime-video-chips")

    // Playing controls hide after 3 seconds idle; an open menu holds them up.
    app.setVideoPlaying(true, with: playPause)
    openChip("subtitles")
    let turkish = app.buttons["video.subtitles.1"]
    XCTAssertTrue(turkish.appears(within: 5), "the Subtitles chip opened no menu")
    XCTAssertTrue(app.buttons["video.subtitles.off"].exists)
    XCTAssertFalse(turkish.disappears(within: 5), "the controls hid and closed the open menu")
    XCTAssertTrue(subtitlesChip.exists, "the controls hid behind the open menu")
    turkish.tap()
    XCTAssertTrue(waitForValue(subtitle, "tr"), "subtitle: \(subtitle.value ?? "")")
    XCTAssertTrue(waitForLabel(subtitlesChip, "Subtitles: Turkish"), subtitlesChip.label)

    openChip("speed")
    let faster = app.buttons["video.speed.1.5"]
    XCTAssertTrue(faster.appears(within: 5), "the speed chip opened no menu")
    faster.tap()
    XCTAssertTrue(waitForLabel(speedChip, "Playback speed 1.5×"), speedChip.label)

    app.setVideoPlaying(false, with: playPause)
    let pictureInPicture = element("video.picture-in-picture")
    app.revealVideoControls(showing: pictureInPicture)
    XCTAssertEqual(pictureInPicture.label, "Picture in Picture")
    let routeRow = pictureInPicture.frame.midY
    let cast = try XCTUnwrap(
      app.buttons.matching(identifier: "cast.button").allElementsBoundByIndex.first {
        abs($0.frame.midY - routeRow) < 4
      }, "the route group lost Cast")
    XCTAssertLessThan(
      pictureInPicture.frame.maxX, cast.frame.minX,
      "Picture in Picture does not lead the route group")
    XCTAssertEqual(audioChip.label, "Audio: English")
    XCTAssertEqual(subtitlesChip.label, "Subtitles: Turkish")
    screenshot("runtime-video-chips-changed")
    app.closeVideo()
  }

  func testMenuGroupsTracksBySourceRemembersTheLanguageAndTurnsAFailedTrackOff() throws {
    launch(tracks: "three", signingIn: true)
    openVideo(retryingSeededFailure: true, startingOver: true)
    let audio = element("video.audio-language")
    let subtitle = element("video.subtitle")
    let text = element("video.subtitle-text")
    let chip = element("video.chip.subtitles")
    XCTAssertTrue(waitForValue(subtitle, "en"), "subtitle: \(subtitle.value ?? "")")
    XCTAssertTrue(waitForValue(text, "English subtitle"), "shown: \(text.value ?? "")")
    XCTAssertTrue(waitForValue(audio, "en"), "audio: \(audio.value ?? "")")
    pausePlayback()

    openChip("subtitles")
    XCTAssertTrue(app.buttons["video.subtitles.2"].appears(within: 5), "the menu lacks Turkish")
    for heading in ["In this file", "Found by put.io"] {
      XCTAssertTrue(shows(heading), "the menu lacks \(heading)")
    }
    for (row, source) in [(0, "Embedded"), (1, "This folder"), (2, "OpenSubtitles")] {
      let label = app.buttons["video.subtitles.\(row)"].label
      XCTAssertTrue(label.contains(source), "row \(row) reads \(label)")
    }
    let sizeAndTiming = app.buttons["video.subtitles.size-and-timing"]
    XCTAssertTrue(sizeAndTiming.exists, "the menu lacks Size and timing")
    XCTAssertFalse(sizeAndTiming.isEnabled, "Size and timing is enabled before its issue")
    screenshot("runtime-subtitles-sources")
    app.buttons["video.subtitles.1"].tap()
    XCTAssertTrue(waitForLabel(chip, "Subtitles: Spanish"), chip.label)
    app.setVideoPlaying(true, with: element("video.play-pause"))
    XCTAssertTrue(waitForValue(text, "Subtítulo en español"), "shown: \(text.value ?? "")")
    XCTAssertTrue(keepsValue(audio, "en"), "the folder subtitle changed the audio track")
    pausePlayback()

    openChip("subtitles")
    let turkish = app.buttons["video.subtitles.2"]
    XCTAssertTrue(turkish.appears(within: 5))
    turkish.tap()
    XCTAssertTrue(waitForLabel(chip, "Subtitles: Turkish"), chip.label)
    app.setVideoPlaying(true, with: element("video.play-pause"))
    XCTAssertTrue(waitForValue(text, "Türkçe altyazı"), "shown: \(text.value ?? "")")
    XCTAssertTrue(keepsValue(audio, "en"), "Turkish subtitles changed the audio track")
    app.closeVideo()

    openVideo(retryingSeededFailure: false, startingOver: true)
    XCTAssertTrue(waitForValue(subtitle, "tr"), "the last language was not remembered")
    pausePlayback()
    openChip("subtitles")
    let off = app.buttons["video.subtitles.off"]
    XCTAssertTrue(off.appears(within: 5))
    off.tap()
    XCTAssertTrue(waitForLabel(chip, "Subtitles: Off"), chip.label)
    app.closeVideo()

    openVideo(retryingSeededFailure: false, startingOver: true)
    XCTAssertTrue(waitForValue(subtitle, "off"), "Off was not remembered")
    XCTAssertTrue(waitForLabel(chip, "Subtitles: Off"), chip.label)
    app.closeVideo()

    launch(tracks: "one", signingIn: false)
    openVideo(retryingSeededFailure: true, startingOver: true)
    XCTAssertTrue(waitForValue(subtitle, "en"), "subtitle: \(subtitle.value ?? "")")
    pausePlayback()
    openChip("subtitles")
    let english = app.buttons["video.subtitles.0"]
    XCTAssertTrue(english.appears(within: 5))
    XCTAssertTrue(english.label.contains("Embedded"), english.label)
    XCTAssertTrue(shows("In this file"), "the menu lacks In this file")
    XCTAssertFalse(shows("Found by put.io"), "one embedded track shows Found by put.io")
    XCTAssertFalse(app.buttons["video.subtitles.1"].exists)
    app.buttons["video.subtitles.off"].tap()
    app.closeVideo()

    launch(tracks: "none", signingIn: false)
    openVideo(retryingSeededFailure: true, startingOver: true)
    XCTAssertTrue(waitForValue(subtitle, "unavailable"), "subtitle: \(subtitle.value ?? "")")
    pausePlayback()
    XCTAssertTrue(waitForLabel(chip, "Subtitles: Off"), chip.label)
    openChip("subtitles")
    let none = app.buttons["video.subtitles.none"]
    XCTAssertTrue(none.appears(within: 5), "the menu does not say no captions are available")
    XCTAssertFalse(none.isEnabled, "No captions available is a choice")
    XCTAssertFalse(app.buttons["video.subtitles.size-and-timing"].exists)
    screenshot("runtime-subtitles-none")
    app.buttons["video.subtitles.off"].tap()
    app.closeVideo()

    launch(tracks: "failing", signingIn: false)
    openVideo(retryingSeededFailure: true, startingOver: true)
    XCTAssertTrue(waitForValue(subtitle, "en"), "subtitle: \(subtitle.value ?? "")")
    openChip("subtitles")
    let failing = app.buttons["video.subtitles.1"]
    XCTAssertTrue(failing.appears(within: 5))
    failing.tap()
    let toast = app.staticTexts["Couldn’t load subtitles"]
    XCTAssertTrue(toast.appears(within: 15), "a failed subtitle showed no toast")
    XCTAssertTrue(waitForLabel(chip, "Subtitles: Off"), chip.label)
    XCTAssertTrue(waitForValue(subtitle, "off"), "subtitle: \(subtitle.value ?? "")")
    screenshot("runtime-subtitles-failed")
    let position = element("video.current-position")
    let failedAt = position.value as? String ?? ""
    XCTAssertTrue(
      waitFor(NSPredicate(format: "value != %@", failedAt), position, timeout: 10),
      "playback stopped after the failed subtitle")
    XCTAssertTrue(keepsValue(audio, "en"), "the failed subtitle changed the audio track")
    app.closeVideo()

    app.buttons["Account"].tap()
    let signOut = app.revealed("auth.sign-out")
    XCTAssertTrue(signOut.appears(within: 5))
    if !signOut.isHittable { app.swipeUp() }
    signOut.tap()
    app.confirmSignOut()
    XCTAssertTrue(element("auth.sign-in").appears(within: 10))
  }

  private func launch(tracks: String, signingIn: Bool) {
    if !signingIn { app.terminate() }
    app.launchArguments = [
      "--putio-harness-scenario", "files-browser", "--putio-harness-subtitle-tracks", tracks,
    ]
    app.launch()
    if signingIn {
      let signIn = element("auth.sign-in")
      XCTAssertTrue(signIn.appears(within: 10))
      signIn.tap()
    }
    XCTAssertTrue(element("files.screen.0").appears(within: 10))
  }

  private func shows(_ label: String) -> Bool {
    app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", label)).firstMatch
      .exists
  }

  /// The seeded scenario fails the first playback attempt for retry proof.
  private func openVideo(retryingSeededFailure: Bool, startingOver: Bool = false) {
    app.showTabBar()
    app.buttons["Files"].tap()
    let video = element("files.item.412")
    XCTAssertTrue(video.appears(within: 10))
    video.tap()
    app.answerResumePrompt(startingOver: startingOver)
    if retryingSeededFailure {
      XCTAssertTrue(element("video.error").appears(within: 10))
      app.buttons["Try again"].tap()
    }
    XCTAssertTrue(element("video.ready").appears(within: 15))
  }

  /// The fixture lasts 20 seconds; pausing keeps the menus clear of the
  /// end-of-video suggestion.
  private func pausePlayback() {
    let position = element("video.current-position")
    XCTAssertTrue(position.appears(within: 10))
    let advanced = XCTNSPredicateExpectation(
      predicate: NSPredicate(format: "value != '0'"), object: position)
    XCTAssertEqual(XCTWaiter.wait(for: [advanced], timeout: 10), .completed)
    app.setVideoPlaying(false, with: element("video.play-pause"))
  }

  private func openChip(_ name: String) {
    let chip = element("video.chip.\(name)")
    app.revealVideoControls(showing: chip)
    chip.tap()
  }

  /// The playback-preferences fixture fails the first account save once.
  private func setPlaybackToggle(
    _ identifier: String, to value: String, retryingSeededFailure: Bool
  ) {
    app.buttons["Account"].tap()
    let toggle = app.switches[identifier]
    app.bringIntoView(toggle)
    XCTAssertTrue(
      waitFor(NSPredicate(format: "hittable == true AND enabled == true"), toggle, timeout: 10))
    // Form exposes the full row as the switch accessibility frame.
    toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
    if retryingSeededFailure {
      let toast = app.staticTexts["Couldn’t save this setting"]
      XCTAssertTrue(toast.appears(within: 10))
      XCTAssertTrue(toast.disappears(within: 10))
      XCTAssertTrue(
        waitFor(NSPredicate(format: "value != %@ AND enabled == true", value), toggle, timeout: 10),
        "\(identifier) did not revert after the failed save")
      app.bringIntoView(toggle)
      toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
    }
    XCTAssertTrue(
      waitFor(NSPredicate(format: "value == %@ AND enabled == true", value), toggle, timeout: 10),
      "\(identifier) did not save \(value)")
  }

  private func waitForLabel(_ element: XCUIElement, _ label: String) -> Bool {
    waitFor(NSPredicate(format: "label == %@", label), element, timeout: 10)
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
