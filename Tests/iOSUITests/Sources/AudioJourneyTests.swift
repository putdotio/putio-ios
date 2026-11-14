import XCTest

final class AudioJourneyTests: XCTestCase {
  private var app: XCUIApplication!

  func testAudioPlaysPausesChangesSpeedAndAdvancesToTheNextTrack() throws {
    continueAfterFailure = false
    app = XCUIApplication()
    app.launchArguments = ["--putio-harness-scenario", "files-browser"]
    app.launchEnvironment["PUTIO_HARNESS_MEDIA_BASE_URL"] = try XCTUnwrap(
      ProcessInfo.processInfo.environment["PUTIO_HARNESS_MEDIA_BASE_URL"])
    app.launch()
    let signIn = element("auth.sign-in")
    XCTAssertTrue(signIn.appears(within: 10))
    signIn.tap()
    let track = element("files.item.408")
    XCTAssertTrue(track.appears(within: 10))
    track.tap()

    let state = element("audio.state")
    XCTAssertTrue(state.appears(within: 10))
    XCTAssertTrue(waitForValue(state, "id=408;state=playing"))
    assertOneSaveAfterTenSeconds()
    XCTAssertEqual(element("audio.title").label, "Harness Track.m4a")
    XCTAssertTrue(waitForLabel(element("audio.folder"), "Your Files"))
    XCTAssertFalse(app.buttons["audio.previous"].isEnabled, "the first file has no previous")
    XCTAssertTrue(app.buttons["audio.next"].isEnabled)
    XCTAssertFalse(app.buttons["audio.sleep-timer"].isEnabled)
    XCTAssertTrue(waitForEnabled(app.buttons["audio.up-next"], true))

    // Dragging down dismisses presentation, not the playback session.
    let collapse = app.buttons["audio.collapse"]
    app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0))
      .withOffset(CGVector(dx: 0, dy: collapse.frame.midY))
      .press(
        forDuration: 0.1,
        thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.95)))
    XCTAssertTrue(element("audio.title").disappears(within: 5), "dragging down kept the sheet")
    let miniPlayer = app.buttons["audio.mini.open"]
    XCTAssertTrue(miniPlayer.appears(within: 5))
    let miniToggle = app.buttons["audio.mini.toggle"]
    XCTAssertEqual(miniToggle.label, "Pause")
    miniToggle.tap()
    XCTAssertEqual(miniToggle.label, "Play")
    app.buttons["Account"].tap()
    XCTAssertTrue(miniPlayer.exists)
    app.buttons["Files"].tap()
    miniPlayer.tap()
    XCTAssertTrue(waitForValue(state, "id=408;state=paused"))
    app.buttons["audio.play-pause"].tap()
    XCTAssertTrue(waitForValue(state, "id=408;state=playing"))
    assertPlaybackAdvances()

    let playPause = app.buttons["audio.play-pause"]
    XCTAssertTrue(playPause.appears(within: 5))
    playPause.tap()
    XCTAssertTrue(waitForValue(state, "id=408;state=paused"))
    for identifier in [
      "audio.collapse", "audio.scrubber", "audio.skip-back", "audio.previous", "audio.play-pause",
      "audio.next", "audio.skip-forward", "audio.speed", "audio.sleep-timer", "audio.up-next",
    ] {
      let control = element(identifier)
      XCTAssertTrue(control.isHittable, identifier)
      XCTAssertGreaterThanOrEqual(control.frame.minX, 0, identifier)
      XCTAssertLessThanOrEqual(control.frame.maxX, app.frame.width, identifier)
    }
    let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
    attachment.name = "runtime-audio-player"
    attachment.lifetime = .keepAlways
    add(attachment)

    // Skipping while paused moves exactly 10 s, clamped to the track, and
    // does not start playback.
    let elapsedLabel = app.staticTexts["audio.elapsed"]
    let before = try XCTUnwrap(Self.seconds(elapsedLabel.label), elapsedLabel.label)
    let remainingLabel = app.staticTexts["audio.remaining"].label
    let remaining = try XCTUnwrap(
      Self.seconds(String(remainingLabel.dropFirst())), remainingLabel)
    let expected = Self.clock(before + min(10, remaining))
    app.buttons["audio.skip-forward"].tap()
    let skip = XCTNSPredicateExpectation(
      predicate: NSPredicate(format: "label == %@", expected), object: elapsedLabel)
    XCTAssertEqual(
      XCTWaiter.wait(for: [skip], timeout: 5), .completed,
      "skip forward from \(Self.clock(before)) showed \(elapsedLabel.label), not \(expected)")
    XCTAssertTrue(waitForValue(state, "id=408;state=paused"), "skip forward resumed playback")
    app.buttons["audio.skip-back"].tap()
    let back = XCTNSPredicateExpectation(
      predicate: NSPredicate(format: "label == %@", Self.clock(before)), object: elapsedLabel)
    XCTAssertEqual(XCTWaiter.wait(for: [back], timeout: 5), .completed)

    let speed = app.buttons["audio.speed"]
    XCTAssertEqual(speed.value as? String, "1×")
    speed.tap()
    XCTAssertTrue(app.buttons["audio.speed.0.25"].appears(within: 5))
    XCTAssertTrue(app.buttons["audio.speed.4"].exists, "the speed list ends at 4×")
    let faster = app.buttons["audio.speed.1.5"]
    faster.tap()
    XCTAssertTrue(waitForValue(speed, "1.5×"))

    // Scrubbing near the end lets the track finish and the successor take over.
    // Scrubbing while paused keeps the seek on this track however slowly the
    // host drives the UI; a playing track can finish first. The remaining 12 s
    // (8 s at 1.5×) leave time to see this track resume before it hands over.
    let scrubber = app.sliders["audio.scrubber"]
    XCTAssertTrue(scrubber.appears(within: 5))
    let pausedAt = elapsedLabel.label
    scrubber.adjust(toNormalizedSliderPosition: 0.8)
    let sought = XCTNSPredicateExpectation(
      predicate: NSPredicate(format: "label != %@", pausedAt), object: elapsedLabel)
    XCTAssertEqual(XCTWaiter.wait(for: [sought], timeout: 5), .completed)
    XCTAssertTrue(waitForValue(state, "id=408;state=paused"))
    playPause.tap()
    XCTAssertTrue(waitForValue(state, "id=408;state=playing", timeout: 5))
    XCTAssertEqual(speed.value as? String, "1.5×")
    XCTAssertTrue(waitForValue(state, "id=409;state=playing", timeout: 20))
    XCTAssertEqual(speed.value as? String, "1.5×")
    XCTAssertTrue(waitForEnabled(app.buttons["audio.previous"], true))
    XCTAssertTrue(waitForEnabled(app.buttons["audio.next"], false), "the last file has no next")

    app.buttons["audio.previous"].tap()
    XCTAssertTrue(waitForValue(state, "id=408;state=playing", timeout: 10))
    XCTAssertTrue(waitForEnabled(app.buttons["audio.next"], true))
    app.buttons["audio.next"].tap()
    XCTAssertTrue(waitForValue(state, "id=409;state=playing", timeout: 10))
    scrubber.adjust(toNormalizedSliderPosition: 0.95)
    XCTAssertTrue(waitForValue(state, "id=409;state=ended", timeout: 20))

    app.buttons["audio.collapse"].tap()
    XCTAssertTrue(track.appears(within: 5))
    for _ in 0..<3 {
      track.tap()
      XCTAssertTrue(waitForValue(state, "id=408;state=playing", timeout: 10))
      assertPlaybackAdvances()
      XCTAssertEqual(speed.value as? String, "1.5×")
      app.buttons["audio.collapse"].tap()
    }

    signOut()
    XCTAssertFalse(miniPlayer.exists)

    try folderQueueRetriesAFailureAndFollowsTheFolder()
    try upNextPlaysATappedFileAndFollowsPlayback()
  }

  private func upNextPlaysATappedFileAndFollowsPlayback() throws {
    app.terminate()
    app.launchArguments = [
      "--putio-harness-scenario", "files-browser", "--putio-harness-music",
      "--putio-harness-audio-near-end",
    ]
    app.launch()
    let signIn = element("auth.sign-in")
    XCTAssertTrue(signIn.appears(within: 10))
    signIn.tap()
    app.revealed("files.item.3101").tap()
    let track = app.revealed("files.item.3103")
    XCTAssertTrue(track.appears(within: 10))
    track.tap()
    let state = element("audio.state")
    XCTAssertTrue(waitForValue(state, "id=3103;state=playing", timeout: 10))

    let chip = app.buttons["audio.up-next"]
    XCTAssertTrue(waitForEnabled(chip, true), "a four-file folder offers Up next")
    chip.tap()
    XCTAssertTrue(app.staticTexts["Up next"].appears(within: 5))
    let rows = [3102, 3103, 3104, 3108].map { app.buttons["audio.up-next.\($0)"] }
    XCTAssertTrue(rows[3].appears(within: 10), "the list never showed the folder")
    let tops = rows.map(\.frame.minY)
    XCTAssertEqual(tops, tops.sorted(), "rows follow the folder's order")
    XCTAssertTrue(rows[1].isSelected, "the playing file is not marked")
    XCTAssertFalse(rows[2].isSelected)
    XCTAssertTrue(app.staticTexts["51:02"].exists, "the third row shows no length")
    let list = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
    list.name = "runtime-audio-up-next"
    list.lifetime = .keepAlways
    add(list)

    rows[2].tap()
    XCTAssertTrue(waitForSelected(rows[2], true), "the tapped file is not marked")
    XCTAssertFalse(rows[1].isSelected)
    XCTAssertTrue(rows[2].isHittable, "tapping a row closed the list")
    XCTAssertTrue(
      waitForSelected(rows[3], true, timeout: 30), "the mark did not follow the next file")
    XCTAssertFalse(rows[2].isSelected)
    XCTAssertTrue(rows[3].isHittable, "the list closed when the file ended")

    app.buttons["sheet.trailing"].tap()
    XCTAssertTrue(rows[3].disappears(within: 5))
    XCTAssertTrue(waitForValue(state, "id=3108;state=playing", timeout: 10))
    app.buttons["audio.collapse"].tap()
    signOut()
  }

  private func folderQueueRetriesAFailureAndFollowsTheFolder() throws {
    app.terminate()
    app.launchArguments += ["--putio-harness-music", "--putio-harness-audio-fails-once"]
    app.launch()
    let signIn = element("auth.sign-in")
    XCTAssertTrue(signIn.appears(within: 10))
    signIn.tap()
    app.revealed("files.item.3101").tap()
    let track = app.revealed("files.item.3103")
    XCTAssertTrue(track.appears(within: 10))
    track.tap()

    let state = element("audio.state")
    XCTAssertTrue(waitForValue(state, "id=3103;state=failed", timeout: 10))
    XCTAssertTrue(app.staticTexts["Couldn’t play this audio"].exists)
    XCTAssertTrue(app.staticTexts["put.io is temporarily unavailable. Try again."].exists)
    let failure = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
    failure.name = "runtime-audio-error"
    failure.lifetime = .keepAlways
    add(failure)
    app.buttons["audio.retry"].tap()
    XCTAssertTrue(waitForValue(state, "id=3103;state=playing", timeout: 10))
    XCTAssertTrue(waitForLabel(element("audio.folder"), "Music"))
    XCTAssertEqual(
      element("audio.title").label, "FFTT Tree Rings Open Air Session, October 13, 2026.mp3")
    XCTAssertTrue(waitForEnabled(app.buttons["audio.previous"], true))
    XCTAssertTrue(app.buttons["audio.next"].isEnabled)

    app.buttons["audio.next"].tap()
    XCTAssertTrue(waitForValue(state, "id=3104;state=playing", timeout: 10))
    XCTAssertTrue(waitForEnabled(app.buttons["audio.previous"], true))
    app.buttons["audio.previous"].tap()
    XCTAssertTrue(waitForValue(state, "id=3103;state=playing", timeout: 10))
    XCTAssertTrue(waitForEnabled(app.buttons["audio.previous"], true))
    app.buttons["audio.previous"].tap()
    XCTAssertTrue(waitForValue(state, "id=3102;state=playing", timeout: 10))
    XCTAssertTrue(waitForEnabled(app.buttons["audio.next"], true))
    XCTAssertFalse(app.buttons["audio.previous"].isEnabled)

    app.buttons["audio.collapse"].tap()
    let back = app.navigationBars.buttons["BackButton"].firstMatch
    XCTAssertTrue(back.appears(within: 5))
    back.tap()
    app.revealed("files.item.3105").tap()
    app.revealed("files.item.3106").tap()
    app.revealed("files.item.3107").tap()
    XCTAssertTrue(waitForValue(state, "id=3107;state=playing", timeout: 10))
    XCTAssertTrue(waitForLabel(element("audio.folder"), "Music"))
    XCTAssertFalse(app.buttons["audio.previous"].isEnabled, "a one-file folder has no previous")
    XCTAssertFalse(app.buttons["audio.next"].isEnabled, "a one-file folder has no next")
    XCTAssertFalse(app.buttons["audio.up-next"].isEnabled)
    let single = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
    single.name = "runtime-audio-single"
    single.lifetime = .keepAlways
    add(single)
    app.buttons["audio.collapse"].tap()
    signOut()
  }

  private func element(_ identifier: String) -> XCUIElement {
    app.descendants(matching: .any)[identifier]
  }

  private func signOut() {
    let account = app.buttons["Account"]
    XCTAssertTrue(account.appears(within: 5))
    account.tap()
    let signOut = app.revealed("auth.sign-out")
    XCTAssertTrue(signOut.appears(within: 5))
    if !signOut.isHittable { app.swipeUp() }
    let hittable = XCTNSPredicateExpectation(
      predicate: NSPredicate(format: "hittable == true"), object: signOut)
    XCTAssertEqual(XCTWaiter.wait(for: [hittable], timeout: 5), .completed)
    signOut.tap()
    app.confirmSignOut()
    XCTAssertTrue(element("auth.sign-in").appears(within: 10))
  }

  /// Reads the player's "m:ss" clock.
  private static func seconds(_ clock: String) -> Int? {
    let parts = clock.split(separator: ":").compactMap { Int($0) }
    guard parts.count == 2 else { return nil }
    return parts[0] * 60 + parts[1]
  }

  private static func clock(_ seconds: Int) -> String {
    String(format: "%d:%02d", seconds / 60, seconds % 60)
  }

  private func waitForValue(_ element: XCUIElement, _ value: String, timeout: TimeInterval = 10)
    -> Bool
  {
    let expectation = XCTNSPredicateExpectation(
      predicate: NSPredicate(format: "value == %@", value), object: element)
    return XCTWaiter.wait(for: [expectation], timeout: timeout) == .completed
  }

  private func waitForLabel(_ element: XCUIElement, _ label: String) -> Bool {
    let expectation = XCTNSPredicateExpectation(
      predicate: NSPredicate(format: "label == %@", label), object: element)
    return XCTWaiter.wait(for: [expectation], timeout: 10) == .completed
  }

  private func waitForSelected(
    _ element: XCUIElement, _ selected: Bool, timeout: TimeInterval = 10
  ) -> Bool {
    let expectation = XCTNSPredicateExpectation(
      predicate: NSPredicate(format: "selected == %@", NSNumber(value: selected)), object: element)
    return XCTWaiter.wait(for: [expectation], timeout: timeout) == .completed
  }

  private func waitForEnabled(_ element: XCUIElement, _ enabled: Bool) -> Bool {
    let expectation = XCTNSPredicateExpectation(
      predicate: NSPredicate(format: "enabled == %@", NSNumber(value: enabled)), object: element)
    return XCTWaiter.wait(for: [expectation], timeout: 10) == .completed
  }

  private func assertOneSaveAfterTenSeconds() {
    let saves = element("audio.position-saves")
    let started = Date()
    let firstSave = XCTNSPredicateExpectation(
      predicate: NSPredicate { object, _ in
        guard let value = (object as? XCUIElement)?.value as? String else { return false }
        return !value.isEmpty
      },
      object: saves)
    XCTAssertEqual(
      XCTWaiter.wait(for: [firstSave], timeout: 20), .completed, "no save while playing")
    XCTAssertGreaterThanOrEqual(Date().timeIntervalSince(started), 5, "saved before the 10 s tick")
    let value = saves.value as? String ?? ""
    let parts = value.split(separator: "@")
    XCTAssertEqual(parts.count, 2, "expected one save, got \(value)")
    XCTAssertEqual(parts.first, "408", value)
    let seconds = Int(parts.last ?? "") ?? 0
    XCTAssertTrue((1...12).contains(seconds), "the save after 10 s was at \(seconds) s")
  }

  private func assertPlaybackAdvances() {
    let elapsed = app.staticTexts["audio.elapsed"]
    XCTAssertTrue(elapsed.appears(within: 10))
    let initial = elapsed.label
    let advances = XCTNSPredicateExpectation(
      predicate: NSPredicate(format: "label != %@", initial), object: elapsed)
    XCTAssertEqual(XCTWaiter.wait(for: [advances], timeout: 10), .completed)
    XCTAssertFalse(app.staticTexts["Couldn’t play this audio"].exists)
  }
}
