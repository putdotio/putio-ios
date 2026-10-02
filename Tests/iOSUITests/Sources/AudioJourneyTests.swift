import XCTest

final class AudioJourneyTests: XCTestCase {
  func testAudioPlaysPausesChangesSpeedAndAdvancesToTheNextTrack() throws {
    continueAfterFailure = false
    let app = XCUIApplication()
    app.launchArguments = ["--putio-harness-scenario", "files-browser"]
    app.launchEnvironment["PUTIO_HARNESS_MEDIA_BASE_URL"] = try XCTUnwrap(
      ProcessInfo.processInfo.environment["PUTIO_HARNESS_MEDIA_BASE_URL"])
    app.launch()
    let signIn = app.descendants(matching: .any)["auth.sign-in"]
    XCTAssertTrue(signIn.waitForExistence(timeout: 10))
    signIn.tap()
    let track = app.descendants(matching: .any)["files.item.408"]
    XCTAssertTrue(track.waitForExistence(timeout: 10))
    track.tap()

    let state = app.descendants(matching: .any)["audio.state"]
    XCTAssertTrue(state.waitForExistence(timeout: 10))
    XCTAssertTrue(waitForValue(state, "id=408;state=playing"))
    assertPlaybackAdvances(in: app)
    XCTAssertEqual(app.descendants(matching: .any)["audio.title"].label, "Harness Track.m4a")

    // Dragging down dismisses presentation, not the playback session.
    let navigationBar = app.navigationBars["Now Playing"]
    navigationBar.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
      .press(
        forDuration: 0.1,
        thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.9)))
    let miniPlayer = app.buttons["audio.mini.open"]
    XCTAssertTrue(miniPlayer.waitForExistence(timeout: 5))
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
    assertPlaybackAdvances(in: app)

    let playPause = app.buttons["audio.play-pause"]
    XCTAssertTrue(playPause.waitForExistence(timeout: 5))
    playPause.tap()
    XCTAssertTrue(waitForValue(state, "id=408;state=paused"))
    for identifier in [
      "audio.scrubber", "audio.speed", "audio.skip-back", "audio.play-pause",
      "audio.skip-forward", "audio.next",
    ] {
      let control = app.descendants(matching: .any)[identifier]
      XCTAssertTrue(control.isHittable)
      XCTAssertGreaterThanOrEqual(control.frame.minX, 0, identifier)
      XCTAssertLessThanOrEqual(control.frame.maxX, app.frame.width, identifier)
    }
    let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
    attachment.name = "runtime-audio-player"
    attachment.lifetime = .keepAlways
    add(attachment)

    // Skipping while paused moves exactly 15 s, clamped to the track, and
    // does not start playback.
    let elapsedLabel = app.staticTexts["audio.elapsed"]
    let before = try XCTUnwrap(Self.seconds(elapsedLabel.label), elapsedLabel.label)
    let durationLabel = app.staticTexts["audio.duration"].label
    let duration = try XCTUnwrap(Self.seconds(durationLabel), durationLabel)
    let expected = Self.clock(min(before + 15, duration))
    app.buttons["audio.skip-forward"].tap()
    let skip = XCTNSPredicateExpectation(
      predicate: NSPredicate(format: "label == %@", expected), object: elapsedLabel)
    XCTAssertEqual(
      XCTWaiter.wait(for: [skip], timeout: 5), .completed,
      "skip forward from \(Self.clock(before)) showed \(elapsedLabel.label), not \(expected)")
    XCTAssertTrue(waitForValue(state, "id=408;state=paused"), "skip forward resumed playback")

    let speed = app.buttons["audio.speed"]
    XCTAssertEqual(speed.value as? String, "1×")
    speed.tap()
    let faster = app.buttons["audio.speed.1.5"]
    XCTAssertTrue(faster.waitForExistence(timeout: 5))
    faster.tap()
    XCTAssertTrue(waitForValue(speed, "1.5×"))

    // Scrubbing near the end lets the track finish and the successor take over.
    // Scrubbing while paused keeps the seek on this track however slowly the
    // host drives the UI; a playing track can finish first. The remaining 12 s
    // (8 s at 1.5×) leave time to see this track resume before it hands over.
    let scrubber = app.sliders["audio.scrubber"]
    XCTAssertTrue(scrubber.waitForExistence(timeout: 5))
    let elapsed = app.staticTexts["audio.elapsed"]
    let pausedAt = elapsed.label
    scrubber.adjust(toNormalizedSliderPosition: 0.8)
    let sought = XCTNSPredicateExpectation(
      predicate: NSPredicate(format: "label != %@", pausedAt), object: elapsed)
    XCTAssertEqual(XCTWaiter.wait(for: [sought], timeout: 5), .completed)
    XCTAssertTrue(waitForValue(state, "id=408;state=paused"))
    playPause.tap()
    XCTAssertTrue(waitForValue(state, "id=408;state=playing", timeout: 5))
    XCTAssertEqual(speed.value as? String, "1.5×")
    XCTAssertTrue(waitForValue(state, "id=409;state=playing", timeout: 20))
    XCTAssertEqual(speed.value as? String, "1.5×")
    scrubber.adjust(toNormalizedSliderPosition: 0.95)
    XCTAssertTrue(waitForValue(state, "id=409;state=ended", timeout: 20))
    XCTAssertTrue(app.descendants(matching: .any)["audio.ended"].exists)

    app.buttons["audio.done"].tap()
    XCTAssertTrue(track.waitForExistence(timeout: 5))
    for _ in 0..<3 {
      track.tap()
      XCTAssertTrue(waitForValue(state, "id=408;state=playing", timeout: 10))
      assertPlaybackAdvances(in: app)
      XCTAssertEqual(speed.value as? String, "1.5×")
      app.buttons["audio.done"].tap()
    }

    let account = app.buttons["Account"]
    XCTAssertTrue(account.waitForExistence(timeout: 5))
    account.tap()
    let signOut = app.revealed("auth.sign-out")
    XCTAssertTrue(signOut.waitForExistence(timeout: 5))
    if !signOut.isHittable { app.swipeUp() }
    let hittable = XCTNSPredicateExpectation(
      predicate: NSPredicate(format: "hittable == true"), object: signOut)
    XCTAssertEqual(XCTWaiter.wait(for: [hittable], timeout: 5), .completed)
    signOut.tap()
    app.confirmSignOut()
    XCTAssertTrue(signIn.waitForExistence(timeout: 10))
    XCTAssertFalse(miniPlayer.exists)
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

  private func assertPlaybackAdvances(in app: XCUIApplication) {
    let elapsed = app.staticTexts["audio.elapsed"]
    XCTAssertTrue(elapsed.waitForExistence(timeout: 10))
    let initial = elapsed.label
    let advances = XCTNSPredicateExpectation(
      predicate: NSPredicate(format: "label != %@", initial), object: elapsed)
    XCTAssertEqual(XCTWaiter.wait(for: [advances], timeout: 10), .completed)
    XCTAssertFalse(app.descendants(matching: .any)["audio.error"].exists)
  }
}
