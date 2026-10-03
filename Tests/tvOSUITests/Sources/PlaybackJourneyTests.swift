import XCTest

/// Plays seeded videos from loopback HLS fixtures with the Siri Remote: the
/// pre-play resume decision, episodic continuation, subtitle and speed
/// controls in the system player, and the conversion gate.
final class PlaybackJourneyTests: XCTestCase {
  private var app: XCUIApplication!
  private let remote = XCUIRemote.shared

  override func setUp() {
    continueAfterFailure = false
    app = XCUIApplication()
    let environment = ProcessInfo.processInfo.environment
    guard let mediaBaseURL = environment["PUTIO_HARNESS_MEDIA_BASE_URL"] else {
      XCTFail("the harness did not name its media server")
      return
    }
    app.launchEnvironment["PUTIO_HARNESS_MEDIA_BASE_URL"] = mediaBaseURL
  }

  /// The saved position asks first; Continue has the first focus and the
  /// progress preview follows the focused choice. The resumed video ends,
  /// its successor comes up next, and the successor starts over on request
  /// and reports its position on the 15-second cadence.
  func testResumeChoicesAndEpisodicContinuation() {
    launch()
    openFile("files.item.412")

    let resume = element("video.resume.continue")
    XCTAssertTrue(resume.waitForExistence(timeout: 30))
    XCTAssertEqual(element("video.resume.file-name").label, "Root Movie.mkv")
    XCTAssertEqual(resume.label, "Continue from 9 minutes, 49 seconds")
    XCTAssertTrue(
      waitUntil(timeout: 5) { self.hasFocus("video.resume.continue") },
      "Continue takes the first focus")
    XCTAssertEqual(percent("video.resume.progress"), 100)
    attach("runtime-tv-playback-resume")

    remote.press(.down)
    XCTAssertTrue(waitUntil(timeout: 5) { self.hasFocus("video.resume.start-over") })
    XCTAssertTrue(
      waitUntil(timeout: 5) { self.percent("video.resume.progress") == 0 },
      "the preview follows the focused choice")
    attach("runtime-tv-playback-resume-start-over")
    remote.press(.up)
    XCTAssertTrue(waitUntil(timeout: 5) { self.hasFocus("video.resume.continue") })
    remote.press(.select)

    // One second is left from the saved position.
    XCTAssertTrue(probe("video.ready").waitForExistence(timeout: 30))
    XCTAssertTrue(probe("video.ended").waitForExistence(timeout: 30))
    let nextTitle = element("video.next-title")
    XCTAssertTrue(nextTitle.waitForExistence(timeout: 30))
    XCTAssertEqual(nextTitle.label, "Up next, Root Movie 2.mkv")
    XCTAssertTrue(element("video.cancel-next").exists)
    XCTAssertTrue(waitUntil(timeout: 5) { self.hasFocus("video.play-next") })
    XCTAssertEqual(probeValue("video.position-reported"), "id=412;seconds=0")
    attach("runtime-tv-playback-up-next")
    remote.press(.select)

    XCTAssertTrue(element("video.screen.414").waitForExistence(timeout: 30))
    let successorResume = element("video.resume.continue")
    XCTAssertTrue(successorResume.waitForExistence(timeout: 30))
    XCTAssertEqual(element("video.resume.file-name").label, "Root Movie 2.mkv")
    XCTAssertEqual(successorResume.label, "Continue from 37 seconds")
    attach("runtime-tv-playback-successor-resume")
    remote.press(.down)
    XCTAssertTrue(waitUntil(timeout: 5) { self.hasFocus("video.resume.start-over") })
    remote.press(.select)

    XCTAssertTrue(probe("video.ready").waitForExistence(timeout: 30))
    XCTAssertTrue(
      waitUntil(timeout: 10) { (Int(self.probeValue("video.current-position") ?? "") ?? 99) < 10 },
      "Start from the beginning plays from zero")
    attach("runtime-tv-playback-playing")
    // The first sample lands one cadence after the player is ready.
    XCTAssertTrue(
      waitUntil(timeout: 25) {
        guard let reported = self.probeValue("video.position-reported"),
          reported.hasPrefix("id=414;seconds="),
          let seconds = Int(reported.dropFirst("id=414;seconds=".count))
        else { return false }
        return (13...20).contains(seconds)
      }, "a position report within the 15-second cadence")

    leavePlayer()
    // The finished video's reset reaches its row: it is no longer watched.
    let finished = element("files.item.412")
    XCTAssertTrue(finished.waitForExistence(timeout: 15))
    XCTAssertTrue(waitUntil(timeout: 15) { !finished.label.contains("Watched") })
  }

  /// Subtitles and speed are AVKit's own controls. The server's default
  /// subtitle is on, choosing Turkish keeps English audio, and the chosen
  /// speed holds through pause and seeking without touching either track.
  func testSubtitleAndSpeedControlsKeepTheAudioTrack() {
    launch(subtitled: true)
    openFile("files.item.412")

    XCTAssertTrue(probe("video.ready").waitForExistence(timeout: 30))
    XCTAssertFalse(element("video.resume.continue").exists, "no saved position, no question")
    XCTAssertTrue(waitUntil(timeout: 10) { self.probeValue("video.subtitle") == "en" })
    XCTAssertEqual(probeValue("video.audio-language"), "en")
    XCTAssertEqual(probeValue("video.speed"), "1", "a new session starts at 1x")
    XCTAssertEqual(probeValue("video.speeds"), "2,1.5,1.25,1,0.5")

    // Select shows the transport bar and pauses; up reaches its menus.
    remote.press(.select)
    XCTAssertTrue(waitUntil(timeout: 5) { self.probeValue("video.rate") == "0" })
    remote.press(.up)
    XCTAssertTrue(focus(where: "identifier == 'AVLegibleSettings'", moving: [.right, .left]))
    remote.press(.select)
    XCTAssertTrue(focus(where: "identifier == 'AVLanguagesMenu'", moving: [.down, .up]))
    attach("runtime-tv-playback-subtitles")
    remote.press(.select)
    XCTAssertTrue(focus(where: "label CONTAINS 'Turkish'", moving: [.down, .up]))
    remote.press(.select)
    XCTAssertTrue(
      waitUntil(timeout: 10) { self.probeValue("video.subtitle") == "tr" },
      "the chosen subtitle is in effect")
    XCTAssertEqual(probeValue("video.audio-language"), "en", "a subtitle never moves the audio")
    // The menu and the rendered cue settle after the selection.
    pause(1.5)
    attach("runtime-tv-playback-subtitle-selected")

    // Back to the transport bar, then the speed menu beside Subtitles.
    XCTAssertTrue(backOut(toFocus: "label == 'Playback Speed'"))
    remote.press(.select)
    // The rate label follows the device locale's decimal separator.
    XCTAssertTrue(focus(where: "label IN {'1.5×', '1,5×'}", moving: [.down, .up]))
    attach("runtime-tv-playback-speed")
    remote.press(.select)
    XCTAssertTrue(waitUntil(timeout: 5) { self.probeValue("video.speed") == "1.5" })
    XCTAssertEqual(probeValue("video.subtitle"), "tr", "speed keeps the subtitle")
    XCTAssertEqual(probeValue("video.audio-language"), "en", "speed keeps the audio")

    // Play/Pause toggles; the chosen speed is the rate playback resumes at.
    remote.press(.playPause)
    XCTAssertTrue(
      waitUntil(timeout: 5) { self.probeValue("video.rate") == "1.5" },
      "resuming plays at the chosen speed")
    remote.press(.playPause)
    XCTAssertTrue(waitUntil(timeout: 5) { self.probeValue("video.rate") == "0" })
    XCTAssertEqual(probeValue("video.speed"), "1.5", "pausing keeps the chosen speed")
    remote.press(.playPause)
    XCTAssertTrue(waitUntil(timeout: 5) { self.probeValue("video.rate") == "1.5" })

    // The transport bar hides while playing; left then skips back.
    pause(5)
    dump("before-skip")
    let before = Int(probeValue("video.current-position") ?? "") ?? 0
    remote.press(.left)
    XCTAssertTrue(
      waitUntil(timeout: 5) {
        (Int(self.probeValue("video.current-position") ?? "") ?? 99) < max(before, 1)
      }, "skipping back seeks")
    XCTAssertTrue(waitUntil(timeout: 5) { self.probeValue("video.rate") == "1.5" })
    XCTAssertEqual(probeValue("video.speed"), "1.5", "seeking keeps the chosen speed")
    XCTAssertEqual(probeValue("video.subtitle"), "tr")
    XCTAssertEqual(probeValue("video.audio-language"), "en")
    leavePlayer()
  }

  /// The first conversion request fails with a retry; the retried one
  /// queues, converts, and completes, then the converted video asks to
  /// resume from its saved position.
  func testConversionGateThenResume() {
    launch()
    openFile("files.item.410")
    XCTAssertTrue(focus("files.item.411"))
    remote.press(.select)

    XCTAssertTrue(element("video.retry").waitForExistence(timeout: 30))
    XCTAssertTrue(label(containing: "Could not convert video").exists)
    attach("runtime-tv-playback-conversion-failure")
    XCTAssertTrue(focus("video.retry"))
    remote.press(.select)

    XCTAssertTrue(element("video.conversion-progress").waitForExistence(timeout: 30))
    XCTAssertTrue(element("conversion.explanation").exists)
    attach("runtime-tv-playback-converting")

    let resume = element("video.resume.continue")
    XCTAssertTrue(resume.waitForExistence(timeout: 30))
    XCTAssertEqual(resume.label, "Continue from 1 minute, 30 seconds")
    XCTAssertEqual(probeValue("video.conversion-history"), "queued,converting,completed")
    attach("runtime-tv-playback-converted-resume")
    remote.press(.select)

    XCTAssertTrue(probe("video.ready").waitForExistence(timeout: 30))
    XCTAssertTrue(
      waitUntil(timeout: 10) { (Int(self.probeValue("video.current-position") ?? "") ?? 0) >= 90 },
      "Continue resumes at the saved position")
    leavePlayer()
    XCTAssertTrue(element("files.item.411").waitForExistence(timeout: 15))
  }

  // MARK: Helpers

  private func launch(subtitled: Bool = false) {
    app.launchArguments = ["--putio-harness-scenario", "signed-in", "--putio-harness-tv-browse"]
    if subtitled { app.launchArguments.append("--putio-harness-subtitled-stream") }
    app.launch()
    XCTAssertTrue(element("home.files").waitForExistence(timeout: 15))
    XCTAssertTrue(waitUntil(timeout: 5) { self.hasFocus("home.files") })
    remote.press(.select)
  }

  private func openFile(_ identifier: String) {
    XCTAssertTrue(element(identifier).waitForExistence(timeout: 15))
    XCTAssertTrue(focus(identifier))
    remote.press(.select)
  }

  /// Menu closes the player's menus and chrome first, then leaves the screen.
  private func leavePlayer() {
    for _ in 0..<6 {
      remote.press(.menu)
      if waitUntil(timeout: 2, { !self.element("video.system-player").exists }) {
        return
      }
    }
    XCTFail("Menu never left the player")
  }

  /// Menu presses until the transport bar item matching `predicate` has
  /// focus again, without leaving the player.
  private func backOut(toFocus predicate: String) -> Bool {
    for _ in 0..<4 {
      remote.press(.menu)
      pause(1)
      if focus(where: predicate, moving: [.right, .left], dumpsOnMiss: false) { return true }
    }
    dump("back-out-miss")
    return false
  }

  /// Steers focus to the first element matching `predicate`, trying each
  /// direction in turn, bounded so a missing control still fails.
  private func focus(
    where predicate: String, moving directions: [XCUIRemote.Button], dumpsOnMiss: Bool = true
  ) -> Bool {
    let focused = NSPredicate(format: "(\(predicate)) AND hasFocus == true")
    let target = app.descendants(matching: .any).matching(focused).firstMatch
    for direction in directions {
      for _ in 0..<6 {
        if waitUntil(timeout: 0.75, { target.exists }) { return true }
        remote.press(direction)
      }
    }
    if waitUntil(timeout: 1.5, { target.exists }) { return true }
    if dumpsOnMiss { dump("focus-miss-\(predicate)") }
    return false
  }

  private func element(_ identifier: String) -> XCUIElement {
    app.descendants(matching: .any).matching(identifier: identifier).firstMatch
  }

  private func probe(_ identifier: String) -> XCUIElement {
    element(identifier)
  }

  private func probeValue(_ identifier: String) -> String? {
    let probe = element(identifier)
    return probe.exists ? probe.value as? String : nil
  }

  /// A percentage value's digits; the sign's side follows the locale.
  private func percent(_ identifier: String) -> Int? {
    (element(identifier).value as? String).flatMap { Int($0.filter(\.isNumber)) }
  }

  private func label(containing text: String) -> XCUIElement {
    app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", text))
      .firstMatch
  }

  private func hasFocus(_ identifier: String) -> Bool {
    app.descendants(matching: .any)
      .matching(NSPredicate(format: "identifier == %@ AND hasFocus == true", identifier))
      .firstMatch.exists
  }

  private func focus(_ identifier: String) -> Bool {
    if focus(identifier, moving: .down, limit: 14) || focus(identifier, moving: .up, limit: 20) {
      return true
    }
    dump("focus-miss-\(identifier)")
    return false
  }

  private func focus(
    _ identifier: String, moving direction: XCUIRemote.Button, limit: Int = 10
  ) -> Bool {
    for _ in 0..<limit {
      if waitUntil(timeout: 0.75, { self.hasFocus(identifier) }) { return true }
      remote.press(direction)
    }
    return waitUntil(timeout: 1.5) { self.hasFocus(identifier) }
  }

  private func dump(_ name: String) {
    let tree = XCTAttachment(string: app.debugDescription)
    tree.name = name
    tree.lifetime = .keepAlways
    add(tree)
  }

  private func pause(_ seconds: TimeInterval) {
    RunLoop.current.run(until: Date().addingTimeInterval(seconds))
  }

  private func waitUntil(timeout: TimeInterval, _ condition: () -> Bool) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
      if condition() { return true }
      RunLoop.current.run(until: Date().addingTimeInterval(0.25))
    }
    return condition()
  }

  private func attach(_ name: String) {
    let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
    attachment.name = name
    attachment.lifetime = .keepAlways
    add(attachment)
  }
}
