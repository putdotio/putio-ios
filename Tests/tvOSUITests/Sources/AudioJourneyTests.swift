import XCTest

/// Plays a seeded audio file with the Siri Remote: Now Playing opens full
/// screen, Play/Pause pauses it, Home leaves it playing in the background, the
/// sleep timer starts from its menu, Menu leaves it playing in the mini player
/// beside the tab bar, and Stop playback lets tvOS suspend the app.
final class AudioJourneyTests: XCTestCase {
  private var app: XCUIApplication!
  private let remote = XCUIRemote.shared

  override func setUp() {
    continueAfterFailure = false
    app = XCUIApplication()
    guard
      let mediaBaseURL = ProcessInfo.processInfo.environment["PUTIO_HARNESS_MEDIA_BASE_URL"]
    else {
      XCTFail("the harness did not name its media server")
      return
    }
    app.launchEnvironment["PUTIO_HARNESS_MEDIA_BASE_URL"] = mediaBaseURL
  }

  func testNowPlayingSleepTimerAndMiniPlayer() {
    app.launchArguments = [
      "--putio-harness-scenario", "signed-in", "--putio-harness-tv-browse",
      "--putio-harness-music",
    ]
    app.launch()
    XCTAssertTrue(TVTabBar(app).open("Files"))
    remote.press(.down)
    XCTAssertTrue(element("files.item.412").waitForExistence(timeout: 15))
    XCTAssertTrue(focus("files.item.3101"))
    remote.press(.select)
    XCTAssertTrue(element("files.item.3103").waitForExistence(timeout: 10))
    XCTAssertTrue(focus("files.item.3103"))
    remote.press(.select)

    let state = element("audio.state")
    XCTAssertTrue(state.waitForExistence(timeout: 20), "Now Playing never opened")
    XCTAssertTrue(waitUntil(timeout: 10) { state.value as? String == "playing" })
    XCTAssertEqual(element("audio.title").label, Self.track)
    XCTAssertTrue(element("audio.folder").exists, "Now Playing does not name the folder")
    attach("runtime-tv-audio-now-playing")

    remote.press(.playPause)
    XCTAssertTrue(waitUntil(timeout: 5) { state.value as? String == "paused" })
    attach("runtime-tv-audio-paused")
    remote.press(.playPause)
    XCTAssertTrue(waitUntil(timeout: 5) { state.value as? String == "playing" })
    keepsPlayingInTheBackground()

    remote.press(.right)
    remote.press(.select)
    let thirty = menuRow("In 30 minutes")
    XCTAssertTrue(thirty.waitForExistence(timeout: 5), "the sleep timer menu never opened")
    XCTAssertTrue(menuRow("In 1 hour").exists, "the menu misses an hour")
    attach("runtime-tv-audio-sleep-menu")
    for _ in 0..<4 where !thirty.hasFocus {
      remote.press(.down)
      _ = waitUntil(timeout: 1) { thirty.hasFocus }
    }
    XCTAssertTrue(thirty.hasFocus, "In 30 minutes never took focus")
    remote.press(.select)
    XCTAssertTrue(
      waitUntil(timeout: 5) { self.label(containing: "Sleep in 29:").exists },
      "the timer did not start")

    remote.press(.menu)
    let mini = element("audio.mini.open")
    XCTAssertTrue(mini.waitForExistence(timeout: 10), "Menu did not leave a mini player")
    XCTAssertFalse(state.exists, "Now Playing stayed open")
    XCTAssertEqual(mini.value as? String, Self.track)
    attach("runtime-tv-audio-mini-player")

    XCTAssertTrue(focus(where: "identifier == 'tab.files'", moving: .up, limit: 6))
    XCTAssertTrue(focus(where: "identifier == 'audio.mini.open'", moving: .right, limit: 6))
    remote.press(.select)
    XCTAssertTrue(state.waitForExistence(timeout: 10), "the mini player did not reopen it")

    remote.press(.menu)
    XCTAssertTrue(mini.waitForExistence(timeout: 10), "Menu did not leave a mini player")
    XCTAssertTrue(focus(where: "identifier == 'audio.mini.open'", moving: .right, limit: 6))
    remote.press(.select, forDuration: 1.5)
    let stop = focused("identifier == 'audio.mini.stop'")
    XCTAssertTrue(
      waitUntil(timeout: 5) { stop.exists }, "the mini player menu did not focus Stop playback")
    remote.press(.select)
    XCTAssertTrue(
      waitUntil(timeout: 10) { !mini.exists }, "Stop playback left the mini player")
    remote.press(.home)
    XCTAssertTrue(
      app.wait(for: .runningBackgroundSuspended, timeout: 30),
      "the app kept running in the background after Stop playback")
  }

  private func keepsPlayingInTheBackground() {
    let before = position()
    remote.press(.home)
    XCTAssertTrue(app.wait(for: .runningBackground, timeout: 10), "Home did not leave the app")
    let away = Date()
    XCTAssertFalse(
      app.wait(for: .runningBackgroundSuspended, timeout: Self.background),
      "tvOS suspended the app, so playback stopped")
    app.activate()
    XCTAssertTrue(app.wait(for: .runningForeground, timeout: 10), "the app did not come back")
    let seconds = Int(Date().timeIntervalSince(away))
    let after = position()
    XCTAssertGreaterThanOrEqual(
      after - before, seconds - 2,
      "the track moved \(after - before) s while the app spent \(seconds) s in the background")
    XCTAssertEqual(element("audio.state").value as? String, "playing")
  }

  private func position() -> Int {
    let scrubber = element("audio.scrubber")
    XCTAssertTrue(scrubber.waitForExistence(timeout: 10), "Now Playing has no position")
    let parts = (scrubber.value as? String ?? "").split(separator: ":").compactMap { Int($0) }
    return parts.reduce(0) { $0 * 60 + $1 }
  }

  // MARK: Helpers

  private static let background: TimeInterval = 8
  private static let track = "FFTT Tree Rings Open Air Session, October 13, 2026.mp3"

  private func element(_ identifier: String) -> XCUIElement {
    app.descendants(matching: .any).matching(identifier: identifier).firstMatch
  }

  private func menuRow(_ title: String) -> XCUIElement {
    app.cells.containing(NSPredicate(format: "label == %@", title)).firstMatch
  }

  private func label(containing text: String) -> XCUIElement {
    app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", text))
      .firstMatch
  }

  private func focused(_ predicate: String) -> XCUIElement {
    app.descendants(matching: .any)
      .matching(NSPredicate(format: "(\(predicate)) AND hasFocus == true")).firstMatch
  }

  private func focus(_ identifier: String) -> Bool {
    focus(identifier, moving: .down, limit: 14) || focus(identifier, moving: .up, limit: 20)
  }

  private func focus(
    _ identifier: String, moving direction: XCUIRemote.Button, limit: Int
  ) -> Bool {
    focus(where: "identifier == '\(identifier)'", moving: direction, limit: limit)
  }

  private func focus(
    where predicate: String, moving direction: XCUIRemote.Button, limit: Int
  ) -> Bool {
    let target = focused(predicate)
    for _ in 0..<limit {
      if waitUntil(timeout: 0.75, { target.exists }) { return true }
      remote.press(direction)
    }
    if waitUntil(timeout: 1.5, { target.exists }) { return true }
    let tree = XCTAttachment(string: app.debugDescription)
    tree.name = "focus-miss"
    tree.lifetime = .keepAlways
    add(tree)
    return false
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
