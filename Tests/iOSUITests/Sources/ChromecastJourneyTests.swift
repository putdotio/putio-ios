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

  func testCastingLoadsFailsRetriesPlaysAndHandsBackTheReceiverPosition() throws {
    app.launch()
    signIn()

    let castButton = app.buttons["cast.button"]
    XCTAssertFalse(castButton.exists, "the Files toolbar still offers Cast")
    let row = element("files.item.412")
    XCTAssertTrue(row.appears(within: 5))
    let folder = element("files.item.410")
    XCTAssertTrue(folder.becomesHittable(within: 10), "the Harness Folder is not tappable")
    folder.tap()
    let nested = element("files.item.411")
    XCTAssertTrue(nested.appears(within: 10), "the nested video never appeared")
    openLocally(nested)
    connectFromPlayer()
    app.closeVideo()
    app.navigationBars.buttons["BackButton"].tap()
    XCTAssertTrue(row.appears(within: 10), "Back never returned to the root folder")

    row.tap()
    let failed = element("cast.failed")
    XCTAssertTrue(failed.appears(within: 15), "the failed load showed no failure")
    XCTAssertTrue(app.staticTexts["Can’t play this on Living Room TV."].exists)
    XCTAssertTrue(app.buttons["cast.stop"].exists, "the failure offers no Stop casting")
    XCTAssertFalse(element("video.ready").exists, "the local player opened while casting")
    screenshot("runtime-cast-failed")

    app.buttons["cast.retry"].tap()
    let playing = element("cast.playing")
    XCTAssertTrue(playing.appears(within: 15), "Try again never played")
    XCTAssertTrue(app.staticTexts["Playing on Living Room TV"].exists)
    let loads = element("cast.load-requests")
    XCTAssertEqual(
      loads.value as? String,
      "/v2/files/412/hls/media.m3u8,/v2/files/412/hls/media.m3u8",
      "a load request carried something other than the HLS stream")
    XCTAssertEqual(castButton.label, "Cast, connected")
    XCTAssertFalse(element("video.picture-in-picture").exists, "casting kept Picture in Picture")
    XCTAssertFalse(element("video.chip.speed").exists, "casting kept Speed")
    let toggle = app.buttons["cast.toggle"]
    XCTAssertEqual(toggle.label, "Pause")
    screenshot("runtime-cast-playing")

    let reported = element("cast.position-reported")
    app.buttons["video.skip-back"].tap()
    XCTAssertTrue(reported.appears(within: 5), "a seek saved no position")
    app.buttons["video.skip-back"].tap()
    XCTAssertTrue(waitUntil(timeout: 5) { self.reportedSeconds(reported) ?? 600 < 560 })
    let afterSeek = try XCTUnwrap(reportedSeconds(reported))
    XCTAssertTrue(
      waitUntil(timeout: 15) { self.reportedSeconds(reported) != afterSeek },
      "no save followed receiver playback")
    let firstTick = try XCTUnwrap(reportedSeconds(reported))
    let firstSaved = Date()
    XCTAssertTrue(
      waitUntil(timeout: 15) { self.reportedSeconds(reported) != firstTick },
      "no save followed 10 seconds of receiver playback")
    let interval = Date().timeIntervalSince(firstSaved)
    let secondTick = try XCTUnwrap(reportedSeconds(reported))
    XCTAssertGreaterThan(secondTick, firstTick, "the timed save went backwards")
    XCTAssertTrue((8...12).contains(interval), "timed saves came \(interval) s apart")
    toggle.tap()
    XCTAssertTrue(waitUntil(timeout: 5) { toggle.label == "Play" })
    switchesReceiverTracks()
    toggle.tap()
    XCTAssertTrue(waitUntil(timeout: 5) { toggle.label == "Pause" })

    app.closeVideo()
    let bar = element("cast.bar")
    XCTAssertTrue(bar.appears(within: 5))
    XCTAssertEqual(element("cast.bar.title").label, "Root Movie.mkv")
    XCTAssertTrue(element("cast.bar.status").label.hasPrefix("Playing on Living Room TV"))
    XCTAssertTrue(
      waitForValue(element("cast.receiver-state"), "connected=true;loaded=true", timeout: 5))
    bar.tap()
    XCTAssertTrue(playing.appears(within: 5), "the bar did not reopen the casting layout")

    app.buttons["cast.stop"].tap()
    XCTAssertTrue(element("video.ready").appears(within: 20), "the phone never took over")
    let handedBack = try XCTUnwrap(reportedSeconds(reported))
    XCTAssertEqual(element("video.resume-position").value as? String, "\(handedBack)")
    XCTAssertFalse(app.buttons["video.resume.resume"].exists, "the hand-back asked where to start")
    XCTAssertTrue(
      waitForValue(element("cast.receiver-state"), "connected=true;loaded=false", timeout: 5))
    app.closeVideo()
    XCTAssertFalse(bar.exists, "stopping kept the bar")

    // Sign-out must stop the receiver, not just remove its layout with the shell.
    row.tap()
    XCTAssertTrue(playing.appears(within: 15))
    app.closeVideo()
    XCTAssertTrue(bar.appears(within: 5))
    row.tap()
    XCTAssertTrue(playing.appears(within: 15), "casting the same video did not reopen the player")
    app.closeVideo()
    let receiverState = element("cast.receiver-state")
    XCTAssertTrue(waitForValue(receiverState, "connected=true;loaded=true", timeout: 5))
    app.buttons["Account"].tap()
    let signOut = app.revealed("auth.sign-out")
    XCTAssertTrue(signOut.appears(within: 5))
    if !signOut.isHittable { app.swipeUp() }
    signOut.tap()
    app.confirmSignOut()
    XCTAssertTrue(element("auth.sign-in").appears(within: 10))
    XCTAssertTrue(waitForValue(receiverState, "connected=false;loaded=false", timeout: 5))
    screenshot("runtime-cast-signed-out")
  }

  private func switchesReceiverTracks() {
    let tracks = element("cast.active-tracks")
    let subtitles = element("video.chip.subtitles")
    let audio = element("video.chip.audio")
    XCTAssertTrue(waitForValue(tracks, "1,1000", timeout: 5), "loaded with \(tracks.value ?? "")")
    XCTAssertEqual(subtitles.label, "Subtitles: English")
    XCTAssertEqual(audio.label, "Audio: English")

    choose("video.subtitles.off", from: subtitles)
    XCTAssertFalse(
      app.buttons["video.subtitles.size-and-timing"].exists, "casting offered Size and timing")
    XCTAssertTrue(waitForValue(tracks, "1", timeout: 5), "Off left \(tracks.value ?? "")")
    XCTAssertTrue(waitUntil(timeout: 5) { subtitles.label == "Subtitles: Off" })
    choose("video.subtitles.1000", from: subtitles)
    XCTAssertTrue(waitForValue(tracks, "1,1000", timeout: 5), "on left \(tracks.value ?? "")")
    choose("video.subtitles.1001", from: subtitles)
    XCTAssertTrue(waitForValue(tracks, "1,1001", timeout: 5), "Turkish left \(tracks.value ?? "")")
    XCTAssertTrue(waitUntil(timeout: 5) { subtitles.label == "Subtitles: Turkish" })
    screenshot("runtime-cast-tracks")
    choose("video.audio.2", from: audio)
    XCTAssertTrue(waitForValue(tracks, "2,1001", timeout: 5), "audio left \(tracks.value ?? "")")
    XCTAssertTrue(waitUntil(timeout: 5) { audio.label == "Audio: Turkish" })
    choose("video.subtitles.off", from: subtitles)
    XCTAssertTrue(waitForValue(tracks, "2", timeout: 5), "Off left \(tracks.value ?? "")")
  }

  private func choose(_ identifier: String, from chip: XCUIElement) {
    let row = app.buttons[identifier]
    for _ in 0..<3 where !row.exists {
      chip.tap()
      _ = row.waitForExistence(timeout: 3)
    }
    XCTAssertTrue(row.exists, "\(chip.identifier) opened no \(identifier)")
    row.tap()
  }

  private func reportedSeconds(_ reported: XCUIElement) -> Int? {
    guard let value = reported.value as? String, value.hasPrefix("id=412;seconds=") else {
      return nil
    }
    return Int(value.dropFirst("id=412;seconds=".count))
  }

  func testRouteGroupFollowsCastDiscoveryAndLocalNetwork() throws {
    app.launchArguments.append("--putio-harness-picture-in-picture")
    let row = element("files.item.412")
    let castButton = app.buttons["cast.button"]

    launchSignedIn()
    openLocally(row)
    XCTAssertEqual(
      app.videoRouteGroup(), ["video.picture-in-picture", "video.airplay", "cast.button"])
    screenshot("runtime-cast-routes")
    app.closeVideo()

    app.terminate()
    app.launchArguments.append("--putio-harness-cast-no-device")
    launchSignedIn()
    openLocally(row)
    XCTAssertEqual(app.videoRouteGroup(), ["video.picture-in-picture", "video.airplay"])
    XCTAssertFalse(castButton.exists, "Cast showed with no device")
    screenshot("runtime-cast-routes-no-device")
    app.closeVideo()

    app.terminate()
    app.launchArguments.removeAll { $0 == "--putio-harness-cast-no-device" }
    app.launchArguments.append("--putio-harness-cast-local-network-denied")
    launchSignedIn()
    openLocally(row)
    XCTAssertEqual(
      app.videoRouteGroup(), ["video.picture-in-picture", "video.airplay", "cast.button"])
    castButton.tap()
    XCTAssertTrue(
      app.staticTexts["Local network access is off"].appears(within: 5),
      "Cast did not explain Local Network")
    XCTAssertTrue(app.staticTexts["Turn it on in Settings to find Cast devices."].exists)
    XCTAssertTrue(app.buttons["cast.local-network.settings"].exists, "no Open Settings")
    XCTAssertFalse(element("cast.picker").exists, "the picker opened anyway")
    screenshot("runtime-cast-local-network-off")
    app.buttons["cast.local-network.cancel"].tap()
    XCTAssertTrue(
      app.staticTexts["Local network access is off"].disappears(within: 5),
      "Cancel kept the alert")
    app.closeVideo()

    app.showTabBar()
    app.buttons["Account"].tap()
    let signOut = app.revealed("auth.sign-out")
    XCTAssertTrue(signOut.appears(within: 5))
    if !signOut.isHittable { app.swipeUp() }
    signOut.tap()
    app.confirmSignOut()
    XCTAssertTrue(element("auth.sign-in").appears(within: 10))
  }

  func testPickerListsDevicesWhilePlaybackContinuesAndConnects() throws {
    let row = element("files.item.412")
    let castButton = app.buttons["cast.button"]
    let position = element("video.current-position")

    launchSignedIn()
    openLocally(row, paused: false)
    let before = try XCTUnwrap(Int(position.value as? String ?? ""), "no playback position")
    app.revealVideoControls(showing: castButton)
    castButton.tap()
    XCTAssertTrue(app.staticTexts["Cast to"].appears(within: 5), "Cast opened no picker")
    let tv = app.buttons["cast.picker.device.living-room-tv"]
    let speaker = app.buttons["cast.picker.device.kitchen-speaker"]
    XCTAssertTrue(tv.label.contains("Living Room TV"), tv.label)
    XCTAssertTrue(tv.label.contains("Chromecast with Google TV"), tv.label)
    XCTAssertTrue(speaker.label.contains("Kitchen speaker"), speaker.label)
    XCTAssertTrue(speaker.label.contains("Audio only"), speaker.label)
    let searching = element("cast.picker.searching")
    XCTAssertTrue(searching.exists, "the picker never said it was searching")
    XCTAssertTrue(searching.label.contains("Looking for devices…"), searching.label)
    XCTAssertGreaterThan(searching.frame.minY, speaker.frame.minY, "searching is not last")
    XCTAssertFalse(element("cast.picker.stop").exists, "Stop casting showed while disconnected")
    screenshot("runtime-cast-picker")
    XCTAssertFalse(waitUntil(timeout: 3) { !tv.exists }, "the picker closed on its own")
    app.buttons["sheet.trailing"].tap()
    XCTAssertTrue(tv.disappears(within: 5), "Close kept the picker")
    XCTAssertTrue(
      waitUntil(timeout: 10) { Int(position.value as? String ?? "") ?? 0 >= before + 3 },
      "playback stopped while the picker was open: \(before) -> \(position.value ?? "")")

    app.revealVideoControls(showing: castButton)
    castButton.tap()
    XCTAssertTrue(tv.appears(within: 5), "Cast opened no picker")
    tv.tap()
    XCTAssertTrue(tv.disappears(within: 5), "choosing a device kept the picker open")
    app.revealVideoControls(showing: castButton)
    XCTAssertTrue(
      waitUntil(timeout: 5) { castButton.label == "Cast, connected" },
      "session never connected: \(castButton.label)")

    castButton.tap()
    XCTAssertTrue(tv.appears(within: 5), "Cast opened no picker")
    XCTAssertTrue(tv.isSelected, "the connected device is not marked")
    let stop = app.buttons["cast.picker.stop"]
    XCTAssertTrue(stop.exists, "no Stop casting while connected")
    stop.tap()
    XCTAssertTrue(stop.disappears(within: 5), "Stop casting kept the picker")
    app.revealVideoControls(showing: castButton)
    XCTAssertTrue(
      waitUntil(timeout: 5) { castButton.label == "Cast" },
      "Stop casting kept the session: \(castButton.label)")
    app.closeVideo()

    app.terminate()
    app.launchArguments += ["--putio-harness-episode-conversion", "completes-late"]
    launchSignedIn()
    for id in [410, 440, 441] {
      let item = element("files.item.\(id)")
      XCTAssertTrue(item.becomesHittable(within: 10), "files.item.\(id) never appeared")
      item.tap()
    }
    let detailPlay = element("files.detail.play")
    if detailPlay.appears(within: 3) { detailPlay.tap() }
    XCTAssertTrue(castButton.appears(within: 10), "the conversion gate offers no Cast")
    XCTAssertFalse(element("video.ready").exists, "the conversion finished before Cast")
    castButton.tap()
    XCTAssertTrue(tv.appears(within: 5), "Cast opened no picker")
    XCTAssertFalse(
      waitUntil(timeout: 15) { !tv.exists }, "the picker closed when the converted video started")
    app.buttons["sheet.trailing"].tap()
    XCTAssertTrue(tv.disappears(within: 5), "Close kept the picker")
    XCTAssertTrue(element("video.ready").appears(within: 2), "the converted video never played")
    app.closeVideo()
  }

  func testAudioCastsFromNowPlayingAdvancesOnTheReceiverAndHandsBackPaused() throws {
    app.launchArguments.append("--putio-harness-music")
    launchSignedIn()
    for id in [3101, 3103] {
      let row = app.revealed("files.item.\(id)")
      XCTAssertTrue(row.becomesHittable(within: 10), "files.item.\(id) never appeared")
      row.tap()
    }
    let state = element("audio.state")
    XCTAssertTrue(state.hasValue("id=3103;state=playing", within: 15), "the file never played")
    XCTAssertTrue(app.buttons["audio.speed"].exists, "local playback has no Speed")

    let castButton = app.buttons["cast.button"]
    XCTAssertTrue(castButton.appears(within: 5), "Now Playing offers no Cast")
    castButton.tap()
    let speaker = app.buttons["cast.picker.device.kitchen-speaker"]
    XCTAssertTrue(speaker.appears(within: 5), "Cast opened no picker")
    XCTAssertTrue(speaker.label.contains("Audio only"), speaker.label)
    speaker.tap()
    XCTAssertTrue(speaker.disappears(within: 5), "the picker stayed open")

    XCTAssertTrue(
      state.hasValue("id=3103;state=failed;receiver", within: 15),
      "the failed load showed no failure")
    XCTAssertTrue(app.staticTexts["Can’t play this on Kitchen speaker."].exists)
    XCTAssertTrue(app.buttons["cast.stop"].exists, "the failure offers no Stop casting")
    screenshot("runtime-audio-cast-failed")
    app.buttons["audio.retry"].tap()

    XCTAssertTrue(
      state.hasValue("id=3103;state=playing;receiver", within: 15), "the speaker never played")
    XCTAssertTrue(app.staticTexts["Playing on Kitchen speaker"].exists)
    XCTAssertEqual(castButton.label, "Cast, connected")
    XCTAssertFalse(app.buttons["audio.speed"].exists, "casting kept Speed")
    XCTAssertTrue(app.buttons["audio.sleep-timer"].exists, "casting dropped Sleep timer")
    XCTAssertTrue(app.buttons["audio.up-next"].exists, "casting dropped Up next")
    screenshot("runtime-audio-casting")

    let playPause = app.buttons["audio.play-pause"]
    playPause.tap()
    XCTAssertTrue(state.hasValue("id=3103;state=paused;receiver", within: 5))
    let elapsed = app.staticTexts["audio.elapsed"]
    let pausedAt = elapsed.label
    XCTAssertFalse(
      waitUntil(timeout: 3) { elapsed.label != pausedAt }, "the receiver kept playing")

    app.buttons["audio.next"].tap()
    XCTAssertTrue(
      state.hasValue("id=3104;state=playing;receiver", within: 15),
      "Next did not play on the receiver")
    XCTAssertEqual(
      element("audio.cast-loads").value as? String,
      "/v2/files/3103/stream,/v2/files/3103/stream,/v2/files/3104/stream",
      "a load carried something other than the audio stream")
    XCTAssertTrue(
      waitUntil(timeout: 10) { (Self.seconds(elapsed.label) ?? 0) >= 3 },
      "the receiver position never advanced: \(elapsed.label)")
    playPause.tap()
    XCTAssertTrue(state.hasValue("id=3104;state=paused;receiver", within: 5))
    let receiverPosition = elapsed.label

    castButton.tap()
    let stop = app.buttons["cast.picker.stop"]
    XCTAssertTrue(stop.appears(within: 5), "no Stop casting while connected")
    stop.tap()
    XCTAssertTrue(
      state.hasValue("id=3104;state=paused", within: 15), "the phone never took over paused")
    XCTAssertEqual(elapsed.label, receiverPosition, "the hand-back moved the position")
    XCTAssertTrue(app.buttons["audio.speed"].exists, "local playback has no Speed")
    XCTAssertEqual(castButton.label, "Cast")
    XCTAssertTrue(
      waitForValue(element("cast.receiver-state"), "connected=false;loaded=false", timeout: 5))
    screenshot("runtime-audio-cast-stopped")
  }

  private static func seconds(_ clock: String) -> Int? {
    let parts = clock.split(separator: ":").compactMap { Int($0) }
    guard parts.count >= 2 else { return nil }
    return parts.reduce(0) { $0 * 60 + $1 }
  }

  private func launchSignedIn() {
    app.launch()
    let signIn = element("auth.sign-in")
    if signIn.appears(within: 10) { signIn.tap() }
    XCTAssertTrue(element("files.screen.0").appears(within: 10))
  }

  private func openLocally(_ row: XCUIElement, paused: Bool = true) {
    row.tap()
    let ready = element("video.ready")
    let resume = app.buttons["video.resume.resume"]
    let retry = app.buttons["video.error"]
    for _ in 0..<40 where !ready.exists {
      if resume.exists {
        resume.tap()
      } else if retry.exists, retry.isHittable {
        retry.tap()
      } else {
        _ = ready.waitForExistence(timeout: 1)
      }
    }
    XCTAssertTrue(ready.appears(within: 20), "the local player never played")
    let playPause = element("video.play-pause")
    _ = playPause.disappears(within: 6)
    app.setVideoPlaying(!paused, with: playPause)
  }

  private func connectFromPlayer() {
    let castButton = app.buttons["cast.button"]
    app.revealVideoControls(showing: castButton)
    castButton.tap()
    let device = app.buttons["cast.picker.device.living-room-tv"]
    XCTAssertTrue(device.appears(within: 5), "Cast opened no picker")
    device.tap()
    XCTAssertTrue(device.disappears(within: 5), "the picker stayed open")
    app.revealVideoControls(showing: castButton)
    XCTAssertTrue(
      waitUntil(timeout: 5) { castButton.label == "Cast, connected" },
      "session never connected: \(castButton.label)")
  }

  private func waitUntilHittable(_ element: XCUIElement, timeout: TimeInterval) -> Bool {
    let expectation = XCTNSPredicateExpectation(
      predicate: NSPredicate(format: "hittable == true"), object: element)
    return XCTWaiter.wait(for: [expectation], timeout: timeout) == .completed
  }

  private func signIn() {
    let button = element("auth.sign-in")
    XCTAssertTrue(button.appears(within: 10))
    button.tap()
    XCTAssertTrue(element("files.screen.0").appears(within: 10))
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
