import XCTest

final class PlaybackPreferencesJourneyTests: XCTestCase {
  override func tearDown() {
    XCUIDevice.shared.orientation = .portrait
    super.tearDown()
  }

  func testProxySubtitlesAndAutoplayRetryAndPersistAcrossRelaunch() throws {
    continueAfterFailure = false
    let app = XCUIApplication()
    app.launchArguments = [
      "--putio-harness-scenario", "files-browser", "--putio-harness-playback-preferences",
      "--putio-harness-reset-file-preferences",
    ]
    app.launchEnvironment["PUTIO_HARNESS_MEDIA_BASE_URL"] = try XCTUnwrap(
      ProcessInfo.processInfo.environment["PUTIO_HARNESS_MEDIA_BASE_URL"])
    XCUIDevice.shared.orientation = .portrait
    app.launch()
    let signIn = app.descendants(matching: .any)["auth.sign-in"]
    XCTAssertTrue(signIn.appears(within: 10))
    signIn.tap()
    XCTAssertTrue(app.buttons["Account"].appears(within: 10))
    playNextManuallyWithAutoplayOff(app)
    followTheDeviceWithRotateOff(app)
    app.showTabBar()
    app.buttons["Account"].tap()
    let proxy = app.revealed("playback-settings.route")
    XCTAssertTrue(proxy.appears(within: 10))
    XCTAssertTrue(proxy.label.hasSuffix("Direct"), "proxy row read \(proxy.label)")
    proxy.tap()
    let routeRetry = app.buttons["proxy.retry"]
    XCTAssertTrue(routeRetry.appears(within: 10))
    routeRetry.tap()
    let direct = choice("Direct", in: app)
    let alternate = choice("edge", in: app)
    XCTAssertTrue(alternate.appears(within: 10))
    assertSelected(direct)
    alternate.tap()
    let saveFailure = app.staticTexts["Couldn’t save this setting"]
    XCTAssertTrue(saveFailure.appears(within: 10))
    assertSelected(direct)
    XCTAssertFalse(alternate.isSelected, "a failed save kept the new proxy")
    XCTAssertTrue(saveFailure.disappears(within: 10))
    alternate.tap()
    let settled = XCTNSPredicateExpectation(
      predicate: NSPredicate(format: "selected == true"), object: alternate)
    XCTAssertEqual(XCTWaiter.wait(for: [settled], timeout: 10), .completed)
    app.navigationBars.buttons["BackButton"].tap()
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
    app.launchArguments += [
      "--putio-harness-rotate-off", "--putio-harness-episode-conversion", "converting",
    ]
    app.launch()
    XCTAssertTrue(app.buttons["Account"].appears(within: 15))
    app.buttons["Account"].tap()
    XCTAssertTrue(app.revealed("playback-settings.autoplay").appears(within: 10))
    assertToggle(autoplay, value: "1")
    XCTAssertTrue(app.revealed("playback-settings.route").appears(within: 5))
    XCTAssertTrue(proxy.label.hasSuffix("edge"), "proxy row read \(proxy.label)")
    _ = app.revealed("playback-settings.subtitle-selection")
    assertToggle(subtitles, value: "1")
    assertToggle(autoSelection, value: "0")
    gateFollowsTheDeviceWithRotateOff(app)
    app.showTabBar()
    XCTAssertTrue(app.buttons["Account"].becomesHittable(within: 5))
    app.buttons["Account"].tap()
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
    let alert = app.putioAlert("Turn off resume?")
    XCTAssertTrue(alert.appears(within: 5))
    XCTAssertTrue(
      alert.staticTexts[
        "This erases every saved playback position on your account, on all devices."
      ].exists)
    let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
    attachment.name = "runtime-resume-off-confirm"
    attachment.lifetime = .keepAlways
    add(attachment)
    XCTAssertEqual(alert.buttons["confirm-alert.confirm"].firstMatch.label, "Turn off")
    alert.buttons["Cancel"].firstMatch.tap()
    XCTAssertTrue(alert.disappears(within: 5))
    assertToggle(resume, value: "1")

    tapToggle(resume)
    XCTAssertTrue(alert.appears(within: 5))
    alert.buttons["confirm-alert.confirm"].firstMatch.tap()
    let toast = app.staticTexts["Couldn’t save this setting"]
    XCTAssertTrue(toast.appears(within: 10))
    assertToggle(resume, value: "1")
    XCTAssertTrue(toast.disappears(within: 10))

    tapToggle(resume)
    XCTAssertTrue(alert.appears(within: 5))
    alert.buttons["confirm-alert.confirm"].firstMatch.tap()
    assertToggle(resume, value: "0")

    let rotate = app.switches["playback-settings.auto-rotate"]
    XCTAssertTrue(app.revealed("playback-settings.auto-rotate").appears(within: 5))
    assertToggle(rotate, value: "1")
    tapToggle(rotate)
    assertToggle(rotate, value: "0")

    app.showTabBar()
    app.buttons["Files"].tap()
    let video = app.descendants(matching: .any)["files.item.412"]
    XCTAssertTrue(video.appears(within: 10))
    video.tap()
    let error = app.descendants(matching: .any)["video.error"]
    let ready = app.descendants(matching: .any)["video.ready"]
    if !ready.appears(before: [error], within: 10), error.exists {
      app.buttons["Try again"].tap()
    }
    XCTAssertTrue(ready.appears(within: 10))
    XCTAssertFalse(app.resumePrompt.exists, "resume off still asked where to start")
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
    app.closeVideo()

    app.buttons["Account"].tap()
    XCTAssertTrue(app.revealed("playback-settings.resume").appears(within: 10))
    tapToggle(resume)
    assertToggle(resume, value: "1")
    XCTAssertFalse(alert.exists, "turning resume on asked for confirmation")

    app.showTabBar()
    app.buttons["Files"].tap()
    XCTAssertTrue(video.appears(within: 10))
    video.tap()
    XCTAssertTrue(ready.appears(within: 15), "a video with no saved position never played")
    XCTAssertFalse(app.resumePrompt.exists, "a video with no saved position asked where to start")
    XCTAssertEqual(
      app.descendants(matching: .any)["video.resume-position"].value as? String, "0")
    app.closeVideo()
    app.buttons["Account"].tap()
    let signOut = app.revealed("auth.sign-out")
    XCTAssertTrue(signOut.appears(within: 5))
    signOut.tap()
    app.confirmSignOut()
    XCTAssertTrue(signIn.appears(within: 10))
  }

  func testProxyListWaitsOnASlowLoadAndARefusedRouteKeepsTheCheckedOne() throws {
    continueAfterFailure = false
    let app = XCUIApplication()
    app.launchArguments = [
      "--putio-harness-scenario", "files-browser", "--putio-harness-proxy", "slow",
    ]
    let proxy = openProxy(in: app, signingIn: true)
    XCTAssertTrue(app.descendants(matching: .any)["proxy.loading"].appears(within: 5))
    let current = choice("cdn77", in: app)
    XCTAssertTrue(current.appears(within: 15), "the slow proxy list never loaded")
    assertSelected(current)
    XCTAssertTrue(choice("Direct", in: app).exists)
    XCTAssertTrue(choice("Washington, D.C.", in: app).exists)

    app.terminate()
    app.launchArguments = [
      "--putio-harness-scenario", "files-browser", "--putio-harness-proxy", "refused",
    ]
    _ = openProxy(in: app, signingIn: false)
    XCTAssertTrue(current.appears(within: 10))
    let london = choice("London", in: app)
    london.tap()
    let alert = app.putioAlert("That proxy isn’t available for your account.")
    XCTAssertTrue(alert.appears(within: 10), "the refused proxy showed no alert")
    let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
    attachment.name = "runtime-proxy-refused"
    attachment.lifetime = .keepAlways
    add(attachment)
    alert.buttons.firstMatch.tap()
    XCTAssertTrue(alert.disappears(within: 5))
    assertSelected(current)
    XCTAssertFalse(london.isSelected, "the refused proxy stayed checked")
    app.navigationBars.buttons["BackButton"].tap()
    XCTAssertTrue(proxy.appears(within: 5))
    XCTAssertTrue(proxy.label.hasSuffix("cdn77"), "proxy row read \(proxy.label)")
    let signOut = app.revealed("auth.sign-out")
    XCTAssertTrue(signOut.appears(within: 5))
    signOut.tap()
    app.confirmSignOut()
    XCTAssertTrue(app.descendants(matching: .any)["auth.sign-in"].appears(within: 10))
  }

  private func openProxy(in app: XCUIApplication, signingIn: Bool) -> XCUIElement {
    app.launch()
    if signingIn {
      let signIn = app.descendants(matching: .any)["auth.sign-in"]
      XCTAssertTrue(signIn.appears(within: 10))
      signIn.tap()
    }
    XCTAssertTrue(app.buttons["Account"].appears(within: 15))
    app.buttons["Account"].tap()
    let proxy = app.revealed("playback-settings.route")
    XCTAssertTrue(proxy.appears(within: 10))
    proxy.tap()
    return proxy
  }

  func testPlaybackMethodAppliesOnTapRevertsAFailedSaveAndPersistsAcrossRelaunch() throws {
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
    let method = app.revealed("playback-settings.method")
    XCTAssertTrue(method.appears(within: 10))
    XCTAssertTrue(method.label.hasSuffix("Standard"), "method row read \(method.label)")
    method.tap()
    let standard = choice("Standard", in: app)
    let directPlay = choice("Direct play", in: app)
    XCTAssertTrue(directPlay.appears(within: 5))
    assertSelected(standard)
    XCTAssertFalse(directPlay.isSelected)

    directPlay.tap()
    let toast = app.staticTexts["Couldn’t save this setting"]
    XCTAssertTrue(toast.appears(within: 10))
    assertSelected(standard)
    XCTAssertFalse(directPlay.isSelected, "a failed save kept Direct play")
    XCTAssertTrue(toast.disappears(within: 10))

    directPlay.tap()
    assertSelected(directPlay)
    XCTAssertFalse(standard.isSelected)
    let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
    attachment.name = "runtime-playback-method"
    attachment.lifetime = .keepAlways
    add(attachment)
    app.navigationBars.buttons["BackButton"].tap()
    XCTAssertTrue(method.appears(within: 5))
    XCTAssertTrue(method.label.hasSuffix("Direct play"), "method row read \(method.label)")

    app.terminate()
    app.launchArguments.removeAll { $0 == "--putio-harness-reset-file-preferences" }
    app.launch()
    XCTAssertTrue(app.buttons["Account"].appears(within: 15))
    app.buttons["Account"].tap()
    XCTAssertTrue(app.revealed("playback-settings.method").appears(within: 10))
    XCTAssertTrue(method.label.hasSuffix("Direct play"), "method row read \(method.label)")
    method.tap()
    XCTAssertTrue(directPlay.appears(within: 5))
    assertSelected(directPlay)
    XCTAssertFalse(standard.isSelected)
    app.navigationBars.buttons["BackButton"].tap()
    let signOut = app.revealed("auth.sign-out")
    XCTAssertTrue(signOut.appears(within: 5))
    signOut.tap()
    app.confirmSignOut()
    XCTAssertTrue(signIn.appears(within: 10))
  }

  private func choice(_ title: String, in app: XCUIApplication) -> XCUIElement {
    app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", title)).firstMatch
  }

  private func assertSelected(_ element: XCUIElement) {
    let expectation = XCTNSPredicateExpectation(
      predicate: NSPredicate(format: "selected == true AND enabled == true"), object: element)
    XCTAssertEqual(XCTWaiter.wait(for: [expectation], timeout: 10), .completed)
  }

  private func playNextManuallyWithAutoplayOff(_ app: XCUIApplication) {
    let rootVideo = app.descendants(matching: .any)["files.item.412"]
    XCTAssertTrue(rootVideo.appears(within: 10))
    rootVideo.tap()
    app.answerResumePrompt()
    XCTAssertTrue(waitForWindow(app, landscape: true), "Rotate on did not hold landscape")
    // The seeded scenario fails the first playback attempt for retry proof.
    XCTAssertTrue(app.descendants(matching: .any)["video.error"].appears(within: 10))
    app.buttons["Try again"].tap()
    XCTAssertTrue(app.descendants(matching: .any)["video.ready"].appears(within: 10))
    let chip = app.descendants(matching: .any)["video.next-episode"]
    XCTAssertTrue(chip.appears(within: 10), "Next episode never showed while playing")
    XCTAssertEqual(chip.label, "Next episode")
    XCTAssertTrue(
      app.descendants(matching: .any)["video.ended"].appears(within: 45),
      "the root video never reached its end")
    let reported =
      app.descendants(matching: .any)["video.position-reported"].value as? String ?? ""
    XCTAssertTrue(
      reported.hasPrefix("id=412;seconds=") && (Int(reported.dropFirst(15)) ?? 0) >= 589,
      "the watched end position did not drain: \(reported)")
    let presentedRoute = app.descendants(matching: .any)["video.presented-route"]
    XCTAssertTrue(presentedRoute.appears(within: 5))
    XCTAssertFalse(
      presentedRoute.hasValue("id=414", within: 12), "the successor started without autoplay")
    XCTAssertFalse(
      app.descendants(matching: .any)["video.up-next"].exists,
      "the Up next card showed without autoplay")
    XCTAssertEqual(presentedRoute.value as? String, "id=412")
    XCTAssertTrue(chip.isHittable, "the finished video lost its Next episode chip")
    chip.tap()
    XCTAssertTrue(
      presentedRoute.hasValue("id=414", within: 10), "Next episode did not open the successor")
    XCTAssertTrue(
      app.descendants(matching: .any)["video.resume-position"].hasValue("37", within: 10),
      "Next episode did not open the successor at its saved position")
    XCTAssertTrue(waitForWindow(app, landscape: true), "the next video dropped the lock")
    app.closeVideo()
    XCTAssertTrue(waitForWindow(app, landscape: false), "Close did not restore portrait")
    XCTAssertTrue(app.descendants(matching: .any)["files.screen.0"].appears(within: 5))
  }

  private func followTheDeviceWithRotateOff(_ app: XCUIApplication) {
    app.showTabBar()
    XCTAssertTrue(app.buttons["Account"].becomesHittable(within: 5))
    app.buttons["Account"].tap()
    let rotate = app.switches["playback-settings.auto-rotate"]
    XCTAssertTrue(app.revealed("playback-settings.auto-rotate").appears(within: 10))
    let tabBarTop = app.tabBars.firstMatch.frame.minY
    var swipes = 0
    while rotate.frame.maxY > tabBarTop, swipes < 3 {
      app.swipeUp()
      swipes += 1
    }
    assertToggle(rotate, value: "1")
    tapToggle(rotate)
    assertToggle(rotate, value: "0")

    app.showTabBar()
    app.buttons["Files"].tap()
    let video = app.descendants(matching: .any)["files.item.412"]
    XCTAssertTrue(video.appears(within: 10))
    video.tap()
    let ready = app.descendants(matching: .any)["video.ready"]
    if app.resumePrompt.appears(before: [ready], within: 5) { app.answerResumePrompt() }
    XCTAssertTrue(ready.appears(within: 15), "the video never played with Rotate off")
    XCTAssertTrue(waitForWindow(app, landscape: false), "Rotate off still turned the phone")
    let title = app.descendants(matching: .any)["video.title"]
    app.revealVideoControls(showing: app.videoClose)
    XCTAssertGreaterThanOrEqual(
      title.frame.minY, app.videoClose.frame.maxY, "the portrait title shares the button row")
    let speedChip = app.descendants(matching: .any)["video.chip.speed"]
    let position = app.descendants(matching: .any)["video.current-position"]
    app.revealVideoControls(showing: speedChip)
    speedChip.tap()
    let faster = app.buttons["video.speed.1.5"]
    XCTAssertTrue(faster.appears(within: 5), "the speed chip opened no menu")
    faster.tap()
    XCTAssertTrue(faster.disappears(within: 5), "choosing a speed left the menu open")
    let turns: [UIDeviceOrientation] = [
      .landscapeLeft, .portrait, .landscapeRight, .landscapeLeft, .portrait,
    ]
    for (turn, orientation) in turns.enumerated() {
      let started = XCTNSPredicateExpectation(
        predicate: NSPredicate(format: "value != nil AND value != '0'"), object: position)
      XCTAssertEqual(XCTWaiter.wait(for: [started], timeout: 10), .completed, "playback stalled")
      let before = Int(position.value as? String ?? "") ?? 0
      XCTAssertGreaterThan(before, 0, "the position probe is missing")
      XCUIDevice.shared.orientation = orientation
      XCTAssertTrue(
        waitForWindow(app, landscape: orientation.isLandscape),
        "Rotate off did not follow the device to \(orientation.rawValue)")
      RunLoop.current.run(until: .now.addingTimeInterval(1.5))
      XCTAssertTrue(ready.exists, "rotating reloaded the video")
      XCTAssertGreaterThanOrEqual(
        Int(position.value as? String ?? "") ?? 0, before, "rotating lost the position")
      app.revealVideoControls(showing: speedChip)
      XCTAssertEqual(speedChip.label, "Playback speed 1.5×", "rotating reset the chips")
      if turn == 1 {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = "runtime-rotate-off-portrait"
        attachment.lifetime = .keepAlways
        add(attachment)
      }
    }
    app.closeVideo()
    XCTAssertTrue(waitForWindow(app, landscape: false), "Close left the phone in landscape")
  }

  private func gateFollowsTheDeviceWithRotateOff(_ app: XCUIApplication) {
    app.showTabBar()
    app.buttons["Files"].tap()
    let harness = app.descendants(matching: .any)["files.item.410"]
    XCTAssertTrue(harness.appears(within: 10))
    harness.tap()
    let season = app.descendants(matching: .any)["files.item.440"]
    XCTAssertTrue(season.appears(within: 10))
    season.tap()
    let episode = app.descendants(matching: .any)["files.item.441"]
    XCTAssertTrue(episode.appears(within: 10))
    episode.tap()
    let progress = app.descendants(matching: .any)["video.conversion-progress"]
    XCTAssertTrue(progress.appears(within: 15), "the conversion gate never showed progress")
    XCTAssertTrue(waitForWindow(app, landscape: false), "the gate turned the phone")
    for orientation in [UIDeviceOrientation.landscapeLeft, .portrait, .landscapeRight, .portrait] {
      XCUIDevice.shared.orientation = orientation
      XCTAssertTrue(
        waitForWindow(app, landscape: orientation.isLandscape),
        "the gate did not follow the device to \(orientation.rawValue)")
      XCTAssertTrue(progress.exists, "rotating lost the conversion")
      XCTAssertTrue(app.buttons["video.conversion.cancel"].isHittable, "rotating hid Cancel")
      XCTAssertTrue(app.videoClose.isHittable, "rotating hid Close")
    }
    XCTAssertGreaterThanOrEqual(
      app.descendants(matching: .any)["video.title"].frame.minY, app.videoClose.frame.maxY,
      "the portrait gate title shares the button row")
    let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
    attachment.name = "runtime-rotate-off-converting"
    attachment.lifetime = .keepAlways
    add(attachment)
    app.buttons["video.conversion.cancel"].tap()
    XCTAssertTrue(progress.disappears(within: 5), "Cancel did not close the gate")
    for _ in 0..<2 { app.navigationBars.buttons["BackButton"].firstMatch.tap() }
    XCTAssertTrue(app.descendants(matching: .any)["files.screen.0"].appears(within: 5))
  }

  private func waitForWindow(_ app: XCUIApplication, landscape: Bool) -> Bool {
    let settled = XCTNSPredicateExpectation(
      predicate: NSPredicate { window, _ in
        guard let frame = (window as? XCUIElement)?.frame, !frame.isEmpty else { return false }
        return (frame.width > frame.height) == landscape
      }, object: app.mainWindow)
    return XCTWaiter.wait(for: [settled], timeout: 10) == .completed
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
