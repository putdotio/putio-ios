import XCTest

/// Plays `runtime-proof-direct.mkv` from the loopback server: a Matroska
/// original AVPlayer cannot open, with AAC stereo and E-AC-3 5.1 audio.
final class DirectPlayJourneyTests: XCTestCase {
  private var app: XCUIApplication!

  override func setUpWithError() throws {
    try super.setUpWithError()
    continueAfterFailure = false
    app = XCUIApplication()
    app.launchArguments = [
      "--putio-harness-scenario", "files-browser", "--putio-harness-playback-preferences",
      "--putio-harness-reset-file-preferences", "--putio-harness-picture-in-picture",
    ]
    app.launchEnvironment["PUTIO_HARNESS_MEDIA_BASE_URL"] = try XCTUnwrap(
      ProcessInfo.processInfo.environment["PUTIO_HARNESS_MEDIA_BASE_URL"])
  }

  func testDirectPlayPlaysTheOriginalSeeksSwitchesAudioAndResumes() throws {
    app.launch()
    let signIn = element("auth.sign-in")
    if signIn.appears(within: 10) { signIn.tap() }
    XCTAssertTrue(app.buttons["Account"].appears(within: 10))

    // On Standard, the file menu plays this one video with Direct play.
    openMenu()
    let playWith = app.buttons["Play with Direct play"].firstMatch
    XCTAssertTrue(playWith.appears(within: 5), "the menu has no Play with Direct play")
    XCTAssertFalse(app.buttons["Play with Standard"].exists)
    screenshot("runtime-direct-play-menu")
    playWith.tap()
    startOverIfAsked()
    waitForOriginal()
    app.closeVideo()

    // The setting stays Standard: a plain tap streams HLS. The seeded
    // scenario fails the first stream once for retry proof.
    openVideo(startingOver: true, retryingSeededFailure: true)
    XCTAssertTrue(waitForValue(element("video.source"), "stream"), "a tap left Standard")
    app.closeVideo()

    setDirectPlay()
    openMenu()
    let playWithStandard = app.buttons["Play with Standard"].firstMatch
    XCTAssertTrue(playWithStandard.appears(within: 5), "the row did not follow the setting")
    XCTAssertFalse(app.buttons["Play with Direct play"].exists)
    playWithStandard.tap()
    startOverIfAsked()
    XCTAssertTrue(element("video.ready").appears(within: 30))
    XCTAssertTrue(waitForValue(element("video.source"), "stream"), "Play with Standard streamed")
    app.closeVideo()

    // Direct play: play, seek, switch audio, close and resume.
    let video = element("files.item.412")
    XCTAssertTrue(video.appears(within: 10))
    video.tap()
    startOverIfAsked()
    waitForOriginal()
    let audio = element("video.audio-language")
    XCTAssertTrue(waitForValue(audio, "en"), "audio: \(audio.value ?? "")")
    let position = element("video.current-position")
    XCTAssertTrue(
      waitFor(NSPredicate(format: "value.intValue >= 2"), position, timeout: 15),
      "the original is not playing: \(position.value ?? "")")
    let playPause = element("video.play-pause")
    app.setVideoPlaying(false, with: playPause)
    let audioChip = element("video.chip.audio")
    XCTAssertTrue(waitForLabel(audioChip, "Audio: English"), audioChip.label)
    screenshot("runtime-direct-play-controls")

    let before = Int(position.value as? String ?? "") ?? 0
    app.revealVideoControls(showing: element("video.skip-forward"))
    element("video.skip-forward").tap()
    XCTAssertTrue(
      waitFor(NSPredicate(format: "value.intValue >= %d", before + 9), position, timeout: 10),
      "the seek did not land: \(position.value ?? "")")

    app.revealVideoControls(showing: audioChip)
    audioChip.tap()
    let turkish = app.buttons["video.audio.2"]
    XCTAssertTrue(turkish.appears(within: 5), "the Audio chip opened no menu")
    XCTAssertTrue(app.buttons["video.audio.1"].exists)
    XCTAssertTrue(
      turkish.label.contains("E-AC3 · 5.1"), "the menu hid the codec: \(turkish.label)")
    XCTAssertTrue(
      app.buttons["video.audio.1"].label.contains("AAC · stereo"),
      app.buttons["video.audio.1"].label)
    screenshot("runtime-direct-play-audio")
    turkish.tap()
    XCTAssertTrue(waitForValue(audio, "tr"), "audio: \(audio.value ?? "")")
    XCTAssertTrue(waitForLabel(audioChip, "Audio: Turkish"), audioChip.label)
    let saved = Int(position.value as? String ?? "") ?? 0
    XCTAssertGreaterThan(saved, 0)
    app.closeVideo()

    openVideo(startingOver: false)
    waitForOriginal()
    let resumed = element("video.resume-position")
    XCTAssertTrue(resumed.appears(within: 10))
    let resumedAt = Int(resumed.value as? String ?? "") ?? 0
    XCTAssertGreaterThanOrEqual(resumedAt, saved - 1, "resumed at \(resumedAt), saved \(saved)")
    XCTAssertTrue(
      waitFor(NSPredicate(format: "value.intValue >= %d", resumedAt), position, timeout: 10),
      "playback did not start at the saved position: \(position.value ?? "")")
    app.closeVideo()

    app.showTabBar()
    app.buttons["Account"].tap()
    let signOut = app.revealed("auth.sign-out")
    XCTAssertTrue(signOut.appears(within: 5))
    if !signOut.isHittable { app.swipeUp() }
    signOut.tap()
    app.confirmSignOut()
    XCTAssertTrue(signIn.appears(within: 10))
  }

  private func waitForOriginal() {
    XCTAssertTrue(element("video.ready").appears(within: 30), "the original never played")
    XCTAssertTrue(
      waitForValue(element("video.source"), "original-engine"),
      "source: \(element("video.source").value ?? "")")
  }

  private func openMenu() {
    app.showTabBar()
    app.buttons["Files"].tap()
    let video = element("files.item.412")
    XCTAssertTrue(video.appears(within: 10))
    video.press(forDuration: 1)
  }

  private func openVideo(startingOver: Bool, retryingSeededFailure: Bool = false) {
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
    XCTAssertTrue(element("video.ready").appears(within: 30))
  }

  /// A video closed in its first second saved no position and asks nothing.
  private func startOverIfAsked() {
    let startOver = app.buttons["video.resume.start-over"].firstMatch
    if startOver.waitForExistence(timeout: 5) { startOver.tap() }
  }

  /// The playback-preferences fixture fails the first method save once.
  private func setDirectPlay() {
    app.showTabBar()
    app.buttons["Account"].tap()
    let method = app.revealed("playback-settings.method")
    XCTAssertTrue(method.appears(within: 10))
    method.tap()
    let directPlay = app.buttons.matching(
      NSPredicate(format: "label BEGINSWITH %@", "Direct play")
    ).firstMatch
    XCTAssertTrue(directPlay.appears(within: 5))
    directPlay.tap()
    let toast = app.staticTexts["Couldn’t save this setting"]
    XCTAssertTrue(toast.appears(within: 10))
    XCTAssertTrue(toast.disappears(within: 10))
    directPlay.tap()
    XCTAssertTrue(
      waitFor(NSPredicate(format: "selected == true"), directPlay, timeout: 10),
      "Direct play did not save")
    app.navigationBars.buttons["BackButton"].tap()
    XCTAssertTrue(
      waitFor(NSPredicate(format: "label ENDSWITH %@", "Direct play"), method, timeout: 5))
  }

  private func element(_ identifier: String) -> XCUIElement {
    app.descendants(matching: .any)[identifier]
  }

  private func waitForValue(_ element: XCUIElement, _ value: String) -> Bool {
    waitFor(NSPredicate(format: "value == %@", value), element, timeout: 15)
  }

  private func waitForLabel(_ element: XCUIElement, _ label: String) -> Bool {
    waitFor(NSPredicate(format: "label == %@", label), element, timeout: 10)
  }

  private func waitFor(_ predicate: NSPredicate, _ element: XCUIElement, timeout: TimeInterval)
    -> Bool
  {
    let expectation = XCTNSPredicateExpectation(predicate: predicate, object: element)
    return XCTWaiter.wait(for: [expectation], timeout: timeout) == .completed
  }

  private func screenshot(_ name: String) {
    let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
    attachment.name = name
    attachment.lifetime = .keepAlways
    add(attachment)
  }
}
