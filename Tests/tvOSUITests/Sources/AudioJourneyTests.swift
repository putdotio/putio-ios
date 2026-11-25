import XCTest

/// Plays a seeded audio file with the Siri Remote: Now Playing opens full
/// screen, Play/Pause pauses it, the sleep timer starts from its menu, and
/// Menu leaves it playing in the mini player beside the tab bar.
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

    let sleep = element("audio.sleep-timer")
    XCTAssertTrue(focus("audio.sleep-timer", moving: .right, limit: 4))
    remote.press(.select)
    let thirty = app.buttons["In 30 minutes"]
    XCTAssertTrue(thirty.waitForExistence(timeout: 5), "the sleep timer menu never opened")
    XCTAssertTrue(app.buttons["In 1 hour"].exists, "the menu misses an hour")
    attach("runtime-tv-audio-sleep-menu")
    XCTAssertTrue(
      focus(where: "label == 'In 30 minutes'", moving: .down, limit: 4),
      "In 30 minutes never took focus")
    remote.press(.select)
    XCTAssertTrue(
      waitUntil(timeout: 5) { sleep.label.hasPrefix("Sleep timer, 29:") },
      "the timer did not start: \(sleep.label)")

    remote.press(.menu)
    let mini = element("audio.mini.open")
    XCTAssertTrue(mini.waitForExistence(timeout: 10), "Menu did not leave a mini player")
    XCTAssertFalse(state.exists, "Now Playing stayed open")
    XCTAssertEqual(element("audio.mini.title").label, Self.track)
    attach("runtime-tv-audio-mini-player")

    XCTAssertTrue(focus("audio.mini.open", moving: .up, limit: 6))
    remote.press(.select)
    XCTAssertTrue(state.waitForExistence(timeout: 10), "the mini player did not reopen it")
  }

  // MARK: Helpers

  private static let track = "FFTT Tree Rings Open Air Session, October 13, 2026.mp3"

  private func element(_ identifier: String) -> XCUIElement {
    app.descendants(matching: .any).matching(identifier: identifier).firstMatch
  }

  private func hasFocus(_ identifier: String) -> Bool {
    focused("identifier == '\(identifier)'").exists
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
    return waitUntil(timeout: 1.5) { target.exists }
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
