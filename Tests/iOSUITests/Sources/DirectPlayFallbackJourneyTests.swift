import XCTest

final class DirectPlayFallbackJourneyTests: XCTestCase {
  private var app: XCUIApplication!

  override func setUpWithError() throws {
    try super.setUpWithError()
    continueAfterFailure = false
    app = XCUIApplication()
    app.launchArguments = ["--putio-harness-scenario", "files-browser"]
    app.launchEnvironment["PUTIO_HARNESS_MEDIA_BASE_URL"] = try XCTUnwrap(
      ProcessInfo.processInfo.environment["PUTIO_HARNESS_MEDIA_BASE_URL"])
  }

  func testAFailingOriginalPlaysConvertedWhereItStoodAndStartsConvertedNextTime() throws {
    app.launchArguments += ["--putio-harness-original-fails", "converted"]
    launchSignedIn()

    openEpisode()
    XCTAssertTrue(element("video.ready").appears(within: 30), "the converted stream never played")
    XCTAssertTrue(waitForValue(element("video.source"), "stream"), "the original kept playing")
    XCTAssertEqual(element("video.fallbacks").value as? String, "1", "no fallback was recorded")
    XCTAssertFalse(element("video.reported-failures").exists, "the fallback reported a failure")
    XCTAssertFalse(element("video.error").exists, "the fallback showed an error")
    XCTAssertEqual(
      element("video.resume-position").value as? String, "120", "the fallback lost the position")
    let position = element("video.current-position")
    XCTAssertTrue(
      waitFor(NSPredicate(format: "value.intValue >= 121"), position, timeout: 15),
      "the converted stream did not play on from 120: \(position.value ?? "")")
    screenshot("runtime-direct-play-fallback")
    app.closeVideo()

    openEpisode()
    XCTAssertTrue(element("video.ready").appears(within: 30), "the second play never started")
    XCTAssertTrue(waitForValue(element("video.source"), "stream"), "the second play left converted")
    RunLoop.current.run(until: .now.addingTimeInterval(2))
    XCTAssertFalse(element("video.fallbacks").exists, "the second play tried the original again")
    XCTAssertFalse(element("video.error").exists)
    app.closeVideo()
  }

  func testAFailingOriginalWithNoConvertedVersionSaysItCannotPlayAndOffersVLC() throws {
    app.launchArguments += [
      "--putio-harness-original-fails", "none", "--putio-harness-vlc-installed",
    ]
    launchSignedIn()

    openEpisode()
    XCTAssertTrue(element("video.error").appears(within: 30), "the original never gave up")
    XCTAssertTrue(app.staticTexts["Can’t play this file"].exists)
    let device = UIDevice.current.userInterfaceIdiom == .pad ? "iPad" : "iPhone"
    XCTAssertTrue(
      app.staticTexts[
        "This \(device) can’t play the original file, and it has no converted version."
      ].exists, "the message does not name this \(device)")
    XCTAssertEqual(
      element("video.title").label, "Blue.Lights.S04E01.1080p.HDTV.H264-ORGANiC.mkv")
    XCTAssertTrue(app.videoClose.exists, "the state offers no Close")
    XCTAssertFalse(app.buttons["Try again"].exists, "the state offers Try again")
    XCTAssertFalse(element("video.conversion-progress").exists, "the state started a conversion")
    screenshot("runtime-direct-play-cant-play")

    let vlc = app.buttons["video.unsupported.vlc"]
    XCTAssertEqual(vlc.label, "Open in VLC")
    vlc.tap()
    XCTAssertTrue(
      waitFor(
        NSPredicate(format: "value BEGINSWITH %@", "1|vlc-x-callback://"),
        element("vlc.requests"), timeout: 10),
      "Open in VLC handed nothing to VLC: \(element("vlc.requests").value ?? "")")
  }

  private func launchSignedIn() {
    app.launch()
    let signIn = element("auth.sign-in")
    let files = app.buttons["Files"]
    let deadline = Date.now.addingTimeInterval(30)
    while Date.now < deadline, !files.exists {
      if signIn.exists { signIn.tap() }
      _ = files.waitForExistence(timeout: 1)
    }
    XCTAssertTrue(files.appears(within: 5), "the app never reached Files")
  }

  private func openEpisode() {
    app.showTabBar()
    app.buttons["Files"].tap()
    for identifier in ["files.item.410", "files.item.440"] {
      let row = element(identifier)
      if !element("files.screen.440").exists, row.appears(within: 10) { row.tap() }
    }
    let episode = element("files.item.441")
    XCTAssertTrue(episode.appears(within: 10), "the episode never appeared")
    episode.tap()
    let detailPlay = element("files.detail.play")
    if detailPlay.appears(within: 3) { detailPlay.tap() }
    app.answerResumePrompt()
  }

  private func element(_ identifier: String) -> XCUIElement {
    app.descendants(matching: .any)[identifier]
  }

  private func waitForValue(_ element: XCUIElement, _ value: String) -> Bool {
    waitFor(NSPredicate(format: "value == %@", value), element, timeout: 15)
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
