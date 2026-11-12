import XCTest

final class PlaybackPreferencesJourneyTests: XCTestCase {
  func testProxySubtitlesAndAutoplayRetryAndPersistAcrossRelaunch() throws {
    continueAfterFailure = false
    let app = XCUIApplication()
    app.launchArguments = [
      "--putio-harness-scenario", "files-browser", "--putio-harness-playback-preferences",
      "--putio-harness-reset-file-preferences",
    ]
    app.launchEnvironment["PUTIO_HARNESS_MEDIA_BASE_URL"] = try XCTUnwrap(
      ProcessInfo.processInfo.environment["PUTIO_HARNESS_MEDIA_BASE_URL"])
    app.launch()
    let signIn = app.descendants(matching: .any)["auth.sign-in"]
    XCTAssertTrue(signIn.appears(within: 10))
    signIn.tap()
    XCTAssertTrue(app.buttons["Account"].appears(within: 10))
    playNextManuallyWithAutoplayOff(app)
    app.buttons["Account"].tap()
    let proxy = openProxy(app)
    let alternate = app.descendants(matching: .any)["playback-settings.route.edge"]
    XCTAssertTrue(alternate.appears(within: 5))
    alternate.tap()
    XCTAssertTrue(app.staticTexts["Couldn’t save this setting"].appears(within: 10))
    XCTAssertTrue(proxy.label.hasSuffix("default"), "proxy row read \(proxy.label)")
    _ = openProxy(app, retryingRoutes: false)
    XCTAssertTrue(alternate.appears(within: 5))
    alternate.tap()
    let refresh = app.revealed("account.settings-retry")
    XCTAssertTrue(refresh.appears(within: 10))
    XCTAssertFalse(proxy.exists, "unconfirmed account preferences stayed editable")
    refresh.tap()
    XCTAssertTrue(refresh.disappears(within: 10))
    XCTAssertTrue(app.revealed("playback-settings.route").appears(within: 10))
    XCTAssertTrue(proxy.label.hasSuffix("edge"), "proxy row read \(proxy.label)")
    let subtitles = app.switches["playback-settings.subtitles"]
    let autoSelection = app.switches["playback-settings.subtitle-selection"]
    XCTAssertTrue(app.revealed("playback-settings.subtitle-selection").appears(within: 5))
    tapToggle(autoSelection)
    assertToggle(autoSelection, value: "0")
    tapToggle(subtitles)
    assertToggle(subtitles, value: "0")
    XCTAssertTrue(autoSelection.disappears(within: 5))
    tapToggle(subtitles)
    assertToggle(subtitles, value: "1")
    XCTAssertTrue(autoSelection.appears(within: 5))
    assertToggle(autoSelection, value: "0")
    let autoplay = app.switches["playback-settings.autoplay"]
    app.scrollDown(toHit: autoplay)
    XCTAssertTrue(autoplay.appears(within: 5))
    assertToggle(autoplay, value: "0")
    tapToggle(autoplay)
    let toast = app.staticTexts["Couldn’t save this setting"]
    XCTAssertTrue(toast.appears(within: 10))
    assertToggle(autoplay, value: "0")
    XCTAssertTrue(toast.disappears(within: 10))
    tapToggle(autoplay)
    assertToggle(autoplay, value: "1")
    let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
    attachment.name = "runtime-playback-preferences"
    attachment.lifetime = .keepAlways
    add(attachment)
    app.terminate()
    app.launchArguments.removeAll { $0 == "--putio-harness-reset-file-preferences" }
    app.launch()
    XCTAssertTrue(app.buttons["Account"].appears(within: 15))
    app.buttons["Account"].tap()
    XCTAssertTrue(app.revealed("playback-settings.autoplay").appears(within: 10))
    assertToggle(autoplay, value: "1")
    XCTAssertTrue(proxy.label.hasSuffix("edge"), "proxy row read \(proxy.label)")
    _ = app.revealed("playback-settings.subtitle-selection")
    assertToggle(subtitles, value: "1")
    assertToggle(autoSelection, value: "0")
    let signOut = app.revealed("auth.sign-out")
    XCTAssertTrue(signOut.appears(within: 5))
    signOut.tap()
    app.confirmSignOut()
    XCTAssertTrue(signIn.appears(within: 10))
  }

  func testResumeOffAsksFirstAndSavedVideosStartAtZeroInPortrait() throws {
    continueAfterFailure = false
    let app = XCUIApplication()
    app.launchArguments = [
      "--putio-harness-scenario", "files-browser", "--putio-harness-playback-preferences",
      "--putio-harness-reset-file-preferences",
    ]
    app.launchEnvironment["PUTIO_HARNESS_MEDIA_BASE_URL"] = try XCTUnwrap(
      ProcessInfo.processInfo.environment["PUTIO_HARNESS_MEDIA_BASE_URL"])
    app.launch()
    let signIn = app.descendants(matching: .any)["auth.sign-in"]
    XCTAssertTrue(signIn.appears(within: 10))
    signIn.tap()
    XCTAssertTrue(app.buttons["Account"].appears(within: 10))
    app.buttons["Account"].tap()
    let resume = app.switches["playback-settings.resume"]
    XCTAssertTrue(app.revealed("playback-settings.resume").appears(within: 10))
    assertToggle(resume, value: "1")

    tapToggle(resume)
    let alert = app.alerts["Turn off resume?"]
    XCTAssertTrue(alert.appears(within: 5))
    XCTAssertTrue(
      alert.staticTexts[
        "This erases every saved playback position on your account, on all devices."
      ].exists)
    let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
    attachment.name = "runtime-resume-off-confirm"
    attachment.lifetime = .keepAlways
    add(attachment)
    XCTAssertEqual(alert.buttons["confirm-alert.confirm"].label, "Turn off")
    alert.buttons["Cancel"].firstMatch.tap()
    XCTAssertTrue(alert.disappears(within: 5))
    assertToggle(resume, value: "1")

    tapToggle(resume)
    XCTAssertTrue(alert.appears(within: 5))
    alert.buttons["confirm-alert.confirm"].tap()
    let toast = app.staticTexts["Couldn’t save this setting"]
    XCTAssertTrue(toast.appears(within: 10))
    assertToggle(resume, value: "1")
    XCTAssertTrue(toast.disappears(within: 10))

    tapToggle(resume)
    XCTAssertTrue(alert.appears(within: 5))
    alert.buttons["confirm-alert.confirm"].tap()
    assertToggle(resume, value: "0")

    let rotate = app.switches["playback-settings.auto-rotate"]
    XCTAssertTrue(app.revealed("playback-settings.auto-rotate").appears(within: 5))
    assertToggle(rotate, value: "1")
    tapToggle(rotate)
    assertToggle(rotate, value: "0")

    app.showTabBar()
    app.buttons["Files"].tap()
    let video = app.descendants(matching: .any)["files.item.414"]
    XCTAssertTrue(video.appears(within: 10))
    video.tap()
    let error = app.descendants(matching: .any)["video.error"]
    let ready = app.descendants(matching: .any)["video.ready"]
    if !ready.appears(within: 10), error.exists { app.buttons["Try again"].tap() }
    XCTAssertTrue(ready.appears(within: 10))
    XCTAssertEqual(
      app.descendants(matching: .any)["video.resume-position"].value as? String, "0",
      "a saved position survived turning resume off")
    let landscape = XCTNSPredicateExpectation(
      predicate: NSPredicate { window, _ in
        guard let frame = (window as? XCUIElement)?.frame else { return false }
        return frame.width > frame.height
      }, object: app.windows.firstMatch)
    XCTAssertEqual(
      XCTWaiter.wait(for: [landscape], timeout: 3), .timedOut,
      "the video rotated with Rotate off")
    app.descendants(matching: .any)["video.done"].tap()

    app.buttons["Account"].tap()
    XCTAssertTrue(app.revealed("playback-settings.resume").appears(within: 10))
    tapToggle(resume)
    assertToggle(resume, value: "1")
    XCTAssertFalse(alert.exists, "turning resume on asked for confirmation")
    let signOut = app.revealed("auth.sign-out")
    XCTAssertTrue(signOut.appears(within: 5))
    signOut.tap()
    app.confirmSignOut()
    XCTAssertTrue(signIn.appears(within: 10))
  }

  /// With the persisted default (autoplay off) the suggestion still appears
  /// after the completed video's position reset and waits past the autoplay
  /// countdown for the manual action, which opens the successor at its saved
  /// position.
  private func playNextManuallyWithAutoplayOff(_ app: XCUIApplication) {
    let rootVideo = app.descendants(matching: .any)["files.item.412"]
    XCTAssertTrue(rootVideo.appears(within: 10))
    rootVideo.tap()
    // The seeded scenario fails the first playback attempt for retry proof.
    XCTAssertTrue(app.descendants(matching: .any)["video.error"].appears(within: 10))
    app.buttons["Try again"].tap()
    XCTAssertTrue(app.descendants(matching: .any)["video.ready"].appears(within: 10))
    let nextTitle = app.descendants(matching: .any)["video.next-title"]
    XCTAssertTrue(nextTitle.appears(within: 15), "next-video suggestion never appeared")
    XCTAssertEqual(nextTitle.label, "Up next, Root Movie 2.mkv")
    XCTAssertFalse(
      app.descendants(matching: .any)["video.next-countdown"].exists,
      "a countdown is shown without autoplay")
    XCTAssertEqual(
      app.descendants(matching: .any)["video.position-reported"].value as? String,
      "id=412;seconds=0", "the completed position reset did not drain before the suggestion")
    let playNext = app.descendants(matching: .any)["video.play-next"]
    let cancelNext = app.descendants(matching: .any)["video.cancel-next"]
    XCTAssertEqual(playNext.label, "Play next, Root Movie 2.mkv")
    XCTAssertEqual(cancelNext.label, "Cancel playing Root Movie 2.mkv")
    let presentedRoute = app.descendants(matching: .any)["video.presented-route"]
    XCTAssertTrue(presentedRoute.appears(within: 5))
    let successorRoute = NSPredicate(format: "value == %@", "id=414")
    XCTAssertEqual(
      XCTWaiter.wait(
        for: [XCTNSPredicateExpectation(predicate: successorRoute, object: presentedRoute)],
        timeout: 8),
      .timedOut, "the successor started without autoplay enabled")
    XCTAssertEqual(presentedRoute.value as? String, "id=412")
    XCTAssertTrue(playNext.isHittable)
    playNext.tap()
    XCTAssertEqual(
      XCTWaiter.wait(
        for: [XCTNSPredicateExpectation(predicate: successorRoute, object: presentedRoute)],
        timeout: 10),
      .completed, "manual play-next did not open the successor")
    let resumePosition = XCTNSPredicateExpectation(
      predicate: NSPredicate(format: "value == %@", "37"),
      object: app.descendants(matching: .any)["video.resume-position"])
    XCTAssertEqual(
      XCTWaiter.wait(for: [resumePosition], timeout: 10), .completed,
      "manual play-next did not open the successor at its saved position")
    app.descendants(matching: .any)["video.done"].tap()
    XCTAssertTrue(app.descendants(matching: .any)["files.screen.0"].appears(within: 5))
  }

  private func openProxy(_ app: XCUIApplication, retryingRoutes: Bool = true) -> XCUIElement {
    let proxy = app.revealed("playback-settings.route")
    XCTAssertTrue(proxy.appears(within: 10))
    proxy.tap()
    if retryingRoutes {
      let routeRetry = app.buttons["playback-settings.retry-routes"]
      XCTAssertTrue(routeRetry.appears(within: 10))
      routeRetry.tap()
    }
    return proxy
  }

  private func lowerBelowNavigationBar(_ element: XCUIElement, in app: XCUIApplication) {
    let ceiling = app.navigationBars.firstMatch.frame.maxY
    var drags = 0
    while element.frame.minY < ceiling, drags < 6 {
      let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.4))
      let end = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.55))
      start.press(forDuration: 0.05, thenDragTo: end, withVelocity: .slow, thenHoldForDuration: 0.3)
      drags += 1
    }
    XCTAssertGreaterThanOrEqual(element.frame.minY, ceiling, "the row stayed under the bar")
  }

  private func tapToggle(_ toggle: XCUIElement) {
    let app = XCUIApplication()
    app.bringIntoView(toggle)
    lowerBelowNavigationBar(toggle, in: app)
    let expectation = XCTNSPredicateExpectation(
      predicate: NSPredicate(format: "hittable == true AND enabled == true"), object: toggle)
    XCTAssertEqual(XCTWaiter.wait(for: [expectation], timeout: 5), .completed)
    // Form exposes the full row as the switch accessibility frame.
    toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
  }

  private func assertToggle(_ toggle: XCUIElement, value: String) {
    let expectation = XCTNSPredicateExpectation(
      predicate: NSPredicate(format: "value == %@ AND enabled == true", value), object: toggle)
    XCTAssertEqual(XCTWaiter.wait(for: [expectation], timeout: 10), .completed)
  }
}
