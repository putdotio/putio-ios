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
    XCTAssertTrue(signIn.waitForExistence(timeout: 10))
    signIn.tap()
    XCTAssertTrue(app.buttons["Account"].waitForExistence(timeout: 10))
    playNextManuallyWithAutoplayOff(app)
    openPreferences(app)
    let routeRetry = app.buttons["playback-settings.retry-routes"]
    XCTAssertTrue(routeRetry.waitForExistence(timeout: 10))
    routeRetry.tap()
    let proxy = app.descendants(matching: .any)["playback-settings.route"]
    XCTAssertTrue(proxy.waitForExistence(timeout: 10))
    proxy.tap()
    let alternate = app.descendants(matching: .any)["playback-settings.route.edge"]
    XCTAssertTrue(alternate.waitForExistence(timeout: 5))
    alternate.tap()
    if !app.navigationBars["Playback Preferences"].exists {
      app.navigationBars.buttons["BackButton"].tap()
    }
    let saveRetry = app.buttons["playback-settings.retry-save"]
    XCTAssertTrue(saveRetry.waitForExistence(timeout: 10))
    XCTAssertEqual(proxy.value as? String, "Default proxy")
    saveRetry.tap()
    let refresh = app.buttons["playback-settings.refresh"]
    XCTAssertTrue(refresh.waitForExistence(timeout: 10))
    XCTAssertFalse(saveRetry.exists)
    XCTAssertFalse(proxy.isEnabled)
    XCTAssertEqual(proxy.value as? String, "Alternate proxy")
    refresh.tap()
    XCTAssertTrue(refresh.waitForNonExistence(timeout: 10))
    let subtitles = app.switches["playback-settings.subtitles"]
    let autoSelection = app.switches["playback-settings.subtitle-selection"]
    XCTAssertTrue(autoSelection.waitForExistence(timeout: 5))
    tapToggle(autoSelection)
    assertToggle(autoSelection, value: "1")
    tapToggle(subtitles)
    assertToggle(subtitles, value: "0")
    XCTAssertTrue(autoSelection.waitForNonExistence(timeout: 5))
    tapToggle(subtitles)
    assertToggle(subtitles, value: "1")
    XCTAssertTrue(autoSelection.waitForExistence(timeout: 5))
    assertToggle(autoSelection, value: "1")
    // Autoplay lives in the config document, not the account settings: the
    // first write fails and the switch keeps the authoritative value.
    let autoplay = app.switches["playback-settings.autoplay"]
    XCTAssertTrue(autoplay.waitForExistence(timeout: 5))
    assertToggle(autoplay, value: "0")
    tapToggle(autoplay)
    let autoplayRetry = app.buttons["playback-settings.retry-autoplay"]
    XCTAssertTrue(autoplayRetry.waitForExistence(timeout: 10))
    assertToggle(autoplay, value: "0")
    autoplayRetry.tap()
    XCTAssertTrue(autoplayRetry.waitForNonExistence(timeout: 10))
    assertToggle(autoplay, value: "1")
    let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
    attachment.name = "runtime-playback-preferences"
    attachment.lifetime = .keepAlways
    add(attachment)
    app.terminate()
    app.launchArguments.removeAll { $0 == "--putio-harness-reset-file-preferences" }
    app.launch()
    XCTAssertTrue(app.buttons["Account"].waitForExistence(timeout: 15))
    openPreferences(app)
    XCTAssertTrue(routeRetry.waitForExistence(timeout: 10))
    routeRetry.tap()
    XCTAssertTrue(proxy.waitForExistence(timeout: 10))
    XCTAssertEqual(proxy.value as? String, "Alternate proxy")
    assertToggle(subtitles, value: "1")
    assertToggle(autoSelection, value: "1")
    assertToggle(autoplay, value: "1")
    app.navigationBars.buttons["BackButton"].tap()
    let signOut = app.revealed("auth.sign-out")
    XCTAssertTrue(signOut.waitForExistence(timeout: 5))
    signOut.tap()
    XCTAssertTrue(signIn.waitForExistence(timeout: 10))
  }

  /// With the persisted default (autoplay off) the suggestion still appears
  /// after the completed video's position reset and waits past the autoplay
  /// countdown for the manual action, which opens the successor at its saved
  /// position.
  private func playNextManuallyWithAutoplayOff(_ app: XCUIApplication) {
    let rootVideo = app.descendants(matching: .any)["files.item.412"]
    XCTAssertTrue(rootVideo.waitForExistence(timeout: 10))
    rootVideo.tap()
    // The seeded scenario fails the first playback attempt for retry proof.
    XCTAssertTrue(app.descendants(matching: .any)["video.error"].waitForExistence(timeout: 10))
    app.buttons["Try again"].tap()
    XCTAssertTrue(app.descendants(matching: .any)["video.ready"].waitForExistence(timeout: 10))
    let nextTitle = app.descendants(matching: .any)["video.next-title"]
    XCTAssertTrue(nextTitle.waitForExistence(timeout: 15), "next-video suggestion never appeared")
    XCTAssertEqual(nextTitle.label, "Up next, Root Movie 2.mkv")
    XCTAssertEqual(
      app.descendants(matching: .any)["video.position-reported"].value as? String,
      "id=412;seconds=0", "the completed position reset did not drain before the suggestion")
    let playNext = app.descendants(matching: .any)["video.play-next"]
    let cancelNext = app.descendants(matching: .any)["video.cancel-next"]
    XCTAssertEqual(playNext.label, "Play next, Root Movie 2.mkv")
    XCTAssertEqual(cancelNext.label, "Cancel playing Root Movie 2.mkv")
    let presentedRoute = app.descendants(matching: .any)["video.presented-route"]
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
    XCTAssertTrue(app.descendants(matching: .any)["files.screen.0"].waitForExistence(timeout: 5))
  }

  private func openPreferences(_ app: XCUIApplication) {
    app.buttons["Account"].tap()
    let entry = app.descendants(matching: .any)["account.playback-preferences"]
    XCTAssertTrue(entry.waitForExistence(timeout: 5))
    entry.tap()
  }

  private func tapToggle(_ toggle: XCUIElement) {
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
