import XCTest

final class VideoWaitJourneyTests: XCTestCase {
  private var app: XCUIApplication!

  override func setUpWithError() throws {
    try super.setUpWithError()
    continueAfterFailure = false
    app = XCUIApplication()
    app.launchArguments = ["--putio-harness-scenario", "files-browser"]
    app.launchEnvironment["PUTIO_HARNESS_MEDIA_BASE_URL"] = try XCTUnwrap(
      ProcessInfo.processInfo.environment["PUTIO_HARNESS_MEDIA_BASE_URL"]
    )
    XCUIDevice.shared.orientation = .landscapeLeft
  }

  override func tearDown() {
    XCUIDevice.shared.orientation = .portrait
    super.tearDown()
  }

  func testPlayerSaysWhatItWaitsForAndRecovers() throws {
    let start = play(holding: .start)
    XCTAssertTrue(element("video.preparing").appears(within: 15), "no Preparing video")
    XCTAssertTrue(app.staticTexts["Preparing video"].exists)
    screenshot("runtime-video-preparing")
    start.release()
    XCTAssertTrue(element("video.preparing").disappears(within: 15), "preparing never ended")
    XCTAssertTrue(element("video.ready").appears(within: 10), "the video never played")

    let recovering = play(holding: .middle)
    let spinner = element("video.buffering-spinner")
    let label = element("video.buffering")
    XCTAssertTrue(spinner.appears(within: 50), "playback never buffered")
    let bufferingSince = Date.now
    XCTAssertFalse(label.exists, "the label showed with the spinner")
    screenshot("runtime-video-buffering")
    XCTAssertTrue(label.appears(within: 15), "the label never showed")
    XCTAssertGreaterThanOrEqual(
      Date.now.timeIntervalSince(bufferingSince), 5, "the label showed well before 10 seconds")
    screenshot("runtime-video-buffering-long")
    recovering.release()
    XCTAssertTrue(spinner.disappears(within: 15), "playback never recovered on its own")
    XCTAssertFalse(label.exists, "recovery left the label")
    XCTAssertFalse(element("video.stalled").exists, "recovery stalled")
    XCTAssertTrue(advances(past: 30), "recovered playback did not move")

    let backingOut = play(holding: .middle)
    XCTAssertTrue(element("video.stalled").appears(within: 80), "playback never stalled")
    XCTAssertTrue(app.staticTexts["Playback stalled"].exists)
    screenshot("runtime-video-stalled")
    app.buttons["video.stalled.back"].tap()
    XCTAssertTrue(app.videoClose.disappears(within: 5), "Back left the player open")
    XCTAssertTrue(element("files.item.441").appears(within: 10), "Back did not return to Files")
    backingOut.release()

    let retrying = play(holding: .middle)
    XCTAssertTrue(element("video.stalled").appears(within: 80), "playback never stalled")
    let stalledAt = try XCTUnwrap(
      Int(element("video.current-position").value as? String ?? ""), "no stalled position")
    XCTAssertGreaterThan(stalledAt, 10, "playback stalled before it played")
    app.buttons["video.stalled.retry"].tap()
    XCTAssertTrue(element("video.stalled").disappears(within: 5), "Try again kept the stall")
    XCTAssertTrue(element("video.preparing").appears(within: 5), "Try again did not reload")
    retrying.release()
    XCTAssertTrue(element("video.preparing").disappears(within: 15), "the reload never played")
    XCTAssertTrue(
      advances(past: stalledAt, within: 5), "Try again did not reload at the stalled position")
    screenshot("runtime-video-stall-retried")
    app.closeVideo()
    signOut()
  }

  private func signOut() {
    XCUIDevice.shared.orientation = .portrait
    let account = app.buttons["Account"]
    XCTAssertTrue(account.appears(within: 5), "no Account tab")
    account.tap()
    let signOut = app.revealed("auth.sign-out")
    XCTAssertTrue(signOut.appears(within: 5), "no Sign out")
    if !signOut.isHittable { app.swipeUp() }
    XCTAssertTrue(signOut.becomesHittable(within: 5), "Sign out is not tappable")
    signOut.tap()
    app.confirmSignOut()
    XCTAssertTrue(element("auth.sign-in").appears(within: 10), "sign-out never finished")
  }

  private func play(holding hold: HeldStream.Hold) -> HeldStream {
    let stream = HeldStream()
    app.launchEnvironment["PUTIO_HARNESS_HELD_STREAM"] = stream.environment(hold)
    addTeardownBlock { stream.release() }
    app.launch()
    let signIn = element("auth.sign-in")
    let episode = element("files.item.441")
    let screens = [0, 410, 440].map { element("files.screen.\($0)") }
    let deadline = Date.now.addingTimeInterval(15)
    while !signIn.exists, !screens.contains(where: \.exists), Date.now < deadline {
      _ = signIn.appears(within: 0.5)
    }
    if signIn.exists { signIn.tap() }
    for (screen, id) in zip(screens, [410, 440]) where !episode.exists {
      guard screen.appears(within: 10) else { continue }
      let folder = element("files.item.\(id)")
      XCTAssertTrue(folder.appears(within: 10), "folder \(id) never appeared")
      folder.tap()
    }
    XCTAssertTrue(episode.appears(within: 10), "the first episode never appeared")
    episode.tap()
    XCTAssertTrue(app.videoClose.appears(within: 10), "the player never opened")
    return stream
  }

  private func advances(past seconds: Int, within timeout: TimeInterval = 15) -> Bool {
    let position = element("video.current-position")
    let moved = XCTNSPredicateExpectation(
      predicate: NSPredicate(format: "value.intValue > %d", seconds), object: position)
    return XCTWaiter.wait(for: [moved], timeout: timeout) == .completed
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
