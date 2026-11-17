import XCTest

final class DownloadsJourneyTests: XCTestCase {
  private var app: XCUIApplication!

  override func setUpWithError() throws {
    try super.setUpWithError()
    continueAfterFailure = false
    app = XCUIApplication()
    app.launchArguments = [
      "--putio-harness-scenario", "files-browser", "--putio-harness-offline-positions-fail",
    ]
    app.launchEnvironment["PUTIO_HARNESS_MEDIA_BASE_URL"] = try XCTUnwrap(
      ProcessInfo.processInfo.environment["PUTIO_HARNESS_MEDIA_BASE_URL"])
    // Turkish first so the stream's English default is not the pick.
    app.launchArguments += ["--putio-harness-preferred-languages", "tr,en"]
  }

  func testMultiAudioDownloadOfflinePlaybackAndPositionSync() throws {
    app.launch()
    signIn()

    let row = element("files.item.412")
    XCTAssertTrue(row.appears(within: 10))
    row.press(forDuration: 1)
    let download = app.submenuAction("Download", in: "Download")
    XCTAssertTrue(download.appears(within: 5))
    download.tap()
    let item = element("downloads.item.412")
    XCTAssertTrue(item.appears(within: 10))

    // Queue: progress through completion.
    XCTAssertTrue(
      waitForValue(item, "completed;watched", timeout: 90),
      "download did not complete: \(item.value ?? "")")
    XCTAssertTrue(element("downloads.storage-used").exists)
    screenshot("runtime-downloads-queue")

    // Info lists the fixture's stored audio and subtitle tracks and closes by swipe.
    item.press(forDuration: 1)
    let infoButton = app.buttons["downloads.info.412"].firstMatch
    XCTAssertTrue(infoButton.appears(within: 5), "the finished row offers no Info")
    infoButton.tap()
    let info = element("downloads.info-sheet.412")
    XCTAssertTrue(info.appears(within: 5), "Info opened no sheet")
    XCTAssertEqual(element("downloads.info.audio").value as? String, "English, Turkish")
    XCTAssertEqual(element("downloads.info.subtitles").value as? String, "English, Turkish")
    screenshot("runtime-downloads-info")
    info.swipeDown(velocity: .fast)
    XCTAssertTrue(info.disappears(within: 5), "swiping down left Info open")

    // Offline playback; the seeded position endpoint fails, so the
    // position stays pending locally.
    item.tap()
    let startOver = app.buttons["video.resume.start-over"].firstMatch
    if startOver.appears(within: 10) { startOver.tap() }
    let ready = element("video.ready")
    XCTAssertTrue(ready.appears(within: 20))
    let language = element("video.audio-language")
    XCTAssertTrue(language.appears(within: 10))
    XCTAssertTrue(
      waitForValue(language, "tr", timeout: 10),
      "offline playback did not pick Turkish: \(language.value ?? "")")
    let position = element("video.current-position")
    XCTAssertTrue(position.appears(within: 10))
    let advanced = XCTNSPredicateExpectation(
      predicate: NSPredicate(format: "value != '0'"), object: position)
    XCTAssertEqual(XCTWaiter.wait(for: [advanced], timeout: 15), .completed)
    app.closeVideo()

    app.terminate()
    app.launchArguments.removeAll { $0 == "--putio-harness-offline-positions-fail" }
    app.launch()
    XCTAssertTrue(element("files.screen.0").appears(within: 10))
    app.buttons["Downloads"].tap()
    XCTAssertTrue(item.appears(within: 10))
    XCTAssertEqual(item.value as? String, "completed;watched")

    app.terminate()
    let preference = try XCTUnwrap(
      app.launchArguments.firstIndex(of: "--putio-harness-preferred-languages"))
    app.launchArguments[preference + 1] = "en,tr"
    app.launch()
    XCTAssertTrue(element("files.screen.0").appears(within: 10))
    app.buttons["Downloads"].tap()
    XCTAssertTrue(item.appears(within: 10))
    item.tap()
    if startOver.appears(within: 10) { startOver.tap() }
    XCTAssertTrue(ready.appears(within: 20))
    XCTAssertTrue(
      waitForValue(language, "en", timeout: 10),
      "offline playback did not switch to English: \(language.value ?? "")")
    app.closeVideo()
    XCTAssertTrue(item.appears(within: 10))

    app.buttons["downloads.more"].tap()
    app.buttons["downloads.select"].tap()
    let removeSelected = app.buttons["selection.action.remove"]
    XCTAssertTrue(removeSelected.appears(within: 5))
    XCTAssertFalse(removeSelected.isEnabled)
    XCTAssertEqual(item.value as? String, "Not selected")
    RunLoop.current.run(until: Date.now.addingTimeInterval(1))
    let rowAccent = app.accentPixelCount(in: rowBand(item))
    item.tap()
    XCTAssertTrue(waitUntil(timeout: 5) { removeSelected.isEnabled })
    XCTAssertEqual(item.value as? String, "Selected")
    RunLoop.current.run(until: Date.now.addingTimeInterval(1))
    screenshot("runtime-downloads-selection")
    XCTAssertGreaterThan(
      app.accentPixelCount(in: rowBand(item)), rowAccent + 1_000,
      "the selection checkmark is not yellow")
    removeSelected.tap()
    let confirmation = app.putioAlert("Remove from this iPhone?")
    XCTAssertTrue(confirmation.appears(within: 5), "removal asked for no confirmation")
    XCTAssertTrue(
      confirmation.staticTexts[
        "“Root Movie.mkv” stays in your put.io files. Only the copy on this iPhone is removed."
      ].exists, "the confirmation does not keep the file in the account")
    screenshot("runtime-downloads-remove")
    app.buttons["downloads.remove-confirm"].firstMatch.tap()
    XCTAssertTrue(item.disappears(within: 10))
    XCTAssertTrue(app.staticTexts["Nothing downloaded yet"].appears(within: 5))

    app.buttons["Files"].tap()
    XCTAssertTrue(element("files.screen.0").appears(within: 10))
    app.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.25)).press(
      forDuration: 0.1,
      thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.85)),
      withVelocity: .slow, thenHoldForDuration: 1)
    XCTAssertTrue(
      element("files.item.412").appears(within: 10),
      "removing the download took the original from the account")

    let account = app.buttons["Account"]
    if !account.exists {
      app.tabBars.buttons.matching(NSPredicate(format: "selected == true")).firstMatch.tap()
    }
    XCTAssertTrue(account.appears(within: 5), "the collapsed tab bar did not expand")
    account.tap()
    let signOut = app.revealed("auth.sign-out")
    XCTAssertTrue(signOut.appears(within: 5))
    if !signOut.isHittable { app.swipeUp() }
    signOut.tap()
    app.confirmSignOut()
    XCTAssertTrue(element("auth.sign-in").appears(within: 10))
  }

  func testAnUnsavedDownloadIsReportedOutsideDownloads() throws {
    app.launchArguments.append("--putio-harness-offline-writes-fail")
    app.launch()
    signIn()

    // Restore's write fails at launch and is reported over Files.
    let unsaved = app.putioAlert("Could not save downloads")
    XCTAssertTrue(unsaved.appears(within: 10))

    // Nothing else writes yet, so only the retry's own failure can bring the
    // alert back.
    app.buttons["downloads.save-retry"].firstMatch.tap()
    // Past the tapped alert's dismissal, so only a new presentation counts.
    Thread.sleep(forTimeInterval: 2)
    XCTAssertTrue(unsaved.appears(within: 8), "a retry that fails again is not reported")
    app.buttons["downloads.save-dismiss"].firstMatch.tap()
    XCTAssertTrue(unsaved.disappears(within: 5))

    // Queuing from Files is reported there; Downloads is never opened.
    let track = element("files.item.408")
    XCTAssertTrue(track.appears(within: 10))
    track.press(forDuration: 1)
    let download = app.buttons["Download"]
    XCTAssertTrue(download.appears(within: 5))
    download.tap()
    XCTAssertTrue(unsaved.appears(within: 10))
    XCTAssertTrue(app.buttons["downloads.save-retry"].firstMatch.exists)

    // Every write keeps failing, so the alert returns; relaunch with working
    // writes to leave the simulator signed out for the next journey test.
    app.terminate()
    app.launchArguments.removeAll { $0 == "--putio-harness-offline-writes-fail" }
    app.launch()
    XCTAssertTrue(element("files.screen.0").appears(within: 10))
    XCTAssertFalse(unsaved.exists)
    app.buttons["Account"].tap()
    let signOut = app.revealed("auth.sign-out")
    XCTAssertTrue(signOut.appears(within: 5))
    if !signOut.isHittable { app.swipeUp() }
    signOut.tap()
    app.confirmSignOut()
    XCTAssertTrue(element("auth.sign-in").appears(within: 10))
  }

  func testADownloadThatCannotStartIsReported() throws {
    app.launchArguments.append("--putio-harness-vlc-resolution-fails-once")
    app.launch()
    signIn()

    let row = element("files.item.412")
    XCTAssertTrue(row.appears(within: 10))
    row.press(forDuration: 1)
    let download = app.submenuAction("Download", in: "Download")
    XCTAssertTrue(download.appears(within: 5))
    download.tap()
    let item = element("downloads.item.412")
    XCTAssertTrue(item.appears(within: 10))
    XCTAssertTrue(
      waitForValue(item, "failed;resolution;watched", timeout: 20),
      "the refused download was not reported: \(item.value ?? "")")
    screenshot("runtime-downloads-start-failed")

    app.buttons["Account"].tap()
    let signOut = app.revealed("auth.sign-out")
    XCTAssertTrue(signOut.appears(within: 5))
    if !signOut.isHittable { app.swipeUp() }
    signOut.tap()
    app.confirmSignOut()
    XCTAssertTrue(element("auth.sign-in").appears(within: 10))
  }

  func testADownloadFinishesWithNotificationsOff() throws {
    app.launchArguments.append("--putio-harness-notifications-denied")
    app.launch()
    signIn()

    let harness = element("files.item.410")
    XCTAssertTrue(harness.appears(within: 10))
    harness.tap()
    let season = element("files.item.440")
    XCTAssertTrue(season.appears(within: 10))
    season.tap()
    let episode = element("files.item.442")
    XCTAssertTrue(episode.appears(within: 10))
    episode.press(forDuration: 1)
    let download = app.submenuAction("Download", in: "Download")
    XCTAssertTrue(download.appears(within: 5))
    download.tap()
    let item = element("downloads.item.442")
    XCTAssertTrue(item.appears(within: 10))
    XCTAssertTrue(
      element("downloads.notifications-off").appears(within: 5),
      "denied notifications showed no row")
    XCTAssertTrue(app.buttons["downloads.notifications-turn-on"].exists)
    XCTAssertTrue(
      waitForValue(item, "completed;watched", timeout: 60),
      "the download did not finish without notifications: \(item.value ?? "")")
    screenshot("runtime-downloads-notifications-off")

    app.buttons["Account"].tap()
    let signOut = app.revealed("auth.sign-out")
    XCTAssertTrue(signOut.appears(within: 5))
    if !signOut.isHittable { app.swipeUp() }
    signOut.tap()
    app.confirmSignOut()
    XCTAssertTrue(element("auth.sign-in").appears(within: 10))
  }

  func testDownloadsFollowThePlaybackMethodUnlessTheMenuNamesTheOther() throws {
    app.launch()
    signIn()
    choosePlaybackMethod("Direct play")

    let movie = element("files.item.412")
    XCTAssertTrue(movie.appears(within: 10))
    movie.press(forDuration: 1)
    let download = app.submenuAction("Download", in: "Download")
    XCTAssertTrue(
      app.buttons["Download with Standard"].appears(within: 5),
      "the menu does not offer the other method")
    download.tap()
    let original = element("downloads.item.412")
    XCTAssertTrue(original.appears(within: 10))
    XCTAssertTrue(
      waitForValue(original, "completed;watched", timeout: 90),
      "the Direct play download did not complete: \(original.value ?? "")")

    app.buttons["Files"].tap()
    let harness = element("files.item.410")
    XCTAssertTrue(harness.appears(within: 10))
    harness.tap()
    let season = element("files.item.440")
    XCTAssertTrue(season.appears(within: 10))
    season.tap()
    let episode = element("files.item.442")
    XCTAssertTrue(episode.appears(within: 10))
    episode.press(forDuration: 1)
    let standard = app.submenuAction("Download with Standard", in: "Download")
    XCTAssertTrue(standard.appears(within: 5))
    standard.tap()
    let package = element("downloads.item.442")
    XCTAssertTrue(package.appears(within: 10))
    XCTAssertTrue(
      waitForValue(package, "completed;watched", timeout: 90),
      "the Standard download did not complete: \(package.value ?? "")")

    let mediaBaseURL = try XCTUnwrap(
      ProcessInfo.processInfo.environment["PUTIO_HARNESS_MEDIA_BASE_URL"].flatMap {
        URL(string: $0)
      })
    let served = try Data(contentsOf: mediaBaseURL.appending(path: "runtime-proof-direct.mkv"))
    let originalDirectory = try storedDownload(412)
    let stored = try XCTUnwrap(
      FileManager.default.contentsOfDirectory(atPath: originalDirectory.path)
        .first { $0.hasPrefix("original") },
      "no original file in \(originalDirectory.path)")
    XCTAssertEqual(
      try Data(contentsOf: originalDirectory.appending(path: stored)), served,
      "the Direct play download is not the original file")
    let packageDirectory = try storedDownload(442)
    XCTAssertEqual(packageDirectory.pathExtension, "movpkg", "\(packageDirectory.path)")
    let packageFiles = try XCTUnwrap(
      FileManager.default.enumerator(atPath: packageDirectory.path)?.allObjects as? [String])
    XCTAssertTrue(
      packageFiles.contains { $0.hasSuffix(".m3u8") }, "the Standard download is not an HLS package"
    )

    original.press(forDuration: 1)
    let infoButton = app.buttons["downloads.info.412"].firstMatch
    XCTAssertTrue(infoButton.appears(within: 5), "the finished original offers no Info")
    infoButton.tap()
    let info = element("downloads.info-sheet.412")
    XCTAssertTrue(info.appears(within: 5), "Info opened no sheet")
    XCTAssertEqual(element("downloads.info.audio").value as? String, "English, Turkish")
    XCTAssertEqual(element("downloads.info.subtitles").value as? String, "English, Turkish")
    screenshot("runtime-downloads-direct-play-original")
    info.swipeDown(velocity: .fast)
    XCTAssertTrue(info.disappears(within: 5), "swiping down left Info open")
    package.tap()
    let resume = app.buttons["video.resume.resume"].firstMatch
    if resume.appears(within: 10) { resume.tap() }
    XCTAssertTrue(element("video.ready").appears(within: 20))
    app.closeVideo()

    app.buttons["Account"].tap()
    let signOut = app.revealed("auth.sign-out")
    XCTAssertTrue(signOut.appears(within: 5))
    if !signOut.isHittable { app.swipeUp() }
    signOut.tap()
    app.confirmSignOut()
    XCTAssertTrue(element("auth.sign-in").appears(within: 10))
  }

  func testDownloadsTabWorksOffline() throws {
    app.launchArguments.removeAll { $0 == "--putio-harness-offline-positions-fail" }
    app.launchArguments += ["--putio-harness-downloads", "offline"]
    app.launch()
    let signIn = element("auth.sign-in")
    if signIn.appears(within: 10) { signIn.tap() }
    let downloads = app.buttons["Downloads"]
    XCTAssertTrue(downloads.appears(within: 15), "the Downloads tab is missing")
    downloads.tap()
    XCTAssertTrue(element("downloads.screen").appears(within: 10), "Downloads never opened")

    let waiting = element("downloads.item.442")
    XCTAssertTrue(
      waitForValue(waiting, "waiting-network;42", timeout: 10),
      "the running download did not wait for the network: \(waiting.value ?? "")")
    XCTAssertEqual(element("downloads.item.443").value as? String, "queued")
    XCTAssertFalse(app.putioAlerts.firstMatch.exists, "the offline tab reported an error")
    screenshot("runtime-downloads-offline")

    let failed = element("downloads.item.444")
    app.bringIntoView(failed)
    app.buttons["Retry download, \(episode(4))"].tap()
    RunLoop.current.run(until: .now.addingTimeInterval(2))
    XCTAssertEqual(
      failed.value as? String, "failed;resolution;26",
      "an offline retry did not stay Connection lost")
    XCTAssertTrue(
      app.descendants(matching: .any)
        .matching(NSPredicate(format: "label CONTAINS %@", "Connection lost")).firstMatch.exists,
      "the offline retry row does not read Connection lost")

    let finished = app.buttons["downloads.item.441"].firstMatch
    app.bringIntoView(finished)
    finished.tap()
    XCTAssertTrue(element("video.ready").appears(within: 20), "the finished video did not play")
    let audio = element("video.audio-language")
    XCTAssertTrue(audio.appears(within: 10))
    let target = (audio.value as? String) == "tr" ? "English" : "Turkish"
    openAudioChip()
    XCTAssertTrue(element("video.audio.1").exists, "the player offers one stored audio track")
    app.buttons.matching(
      NSPredicate(format: "identifier BEGINSWITH 'video.audio.' AND label CONTAINS %@", target)
    ).firstMatch.tap()
    XCTAssertTrue(
      waitForValue(audio, target == "English" ? "en" : "tr", timeout: 10),
      "the stored \(target) track did not play: \(audio.value ?? "")")
    let position = element("video.current-position")
    XCTAssertTrue(position.appears(within: 10))
    app.setVideoPlaying(false, with: element("video.play-pause"))
    app.closeVideo()

    let reported = element("video.position-reported")
    XCTAssertTrue(
      waitUntil(timeout: 10) { self.positionReport(reported)?.id == "441" },
      "closing the video saved no position")
    RunLoop.current.run(until: .now.addingTimeInterval(1))
    let seconds = try XCTUnwrap(positionReport(reported)?.seconds)
    let synced = element("downloads.synced-position")
    XCTAssertEqual(synced.value as? String, "0", "the position reached put.io while offline")

    CFNotificationCenterPostNotification(
      CFNotificationCenterGetDarwinNotifyCenter(),
      CFNotificationName("io.put.harness.downloads-network-restore" as CFString), nil, nil, true)
    XCTAssertTrue(
      waitForValue(waiting, "downloading;42", timeout: 10),
      "the waiting download did not resume: \(waiting.value ?? "")")
    XCTAssertTrue(
      waitForValue(synced, seconds, timeout: 10),
      "the saved position never reached put.io: \(synced.value ?? "")")
    XCTAssertEqual(element("downloads.item.443").value as? String, "queued")

    app.buttons["Account"].tap()
    let signOut = app.revealed("auth.sign-out")
    XCTAssertTrue(signOut.appears(within: 5))
    if !signOut.isHittable { app.swipeUp() }
    signOut.tap()
    app.confirmSignOut()
    XCTAssertTrue(element("auth.sign-in").appears(within: 10))
  }

  func testADirectPlayDownloadPlaysOfflineWithItsSubtitlesAndSyncsItsPosition() throws {
    app.launchArguments.removeAll { $0 == "--putio-harness-offline-positions-fail" }
    app.launch()
    signIn()
    choosePlaybackMethod("Direct play")

    let movie = element("files.item.412")
    XCTAssertTrue(movie.appears(within: 10))
    movie.press(forDuration: 1)
    app.submenuAction("Download", in: "Download").tap()
    let item = element("downloads.item.412")
    XCTAssertTrue(item.appears(within: 10))
    XCTAssertTrue(
      waitForValue(item, "completed;watched", timeout: 90),
      "the Direct play download did not complete: \(item.value ?? "")")

    app.terminate()
    app.launchArguments.append("--putio-harness-network-cut")
    app.launch()
    let requests = openDownloadsCut(item)
    item.tap()
    let source = playStored(startingOver: true)
    XCTAssertEqual(source, "original-engine", "the Direct play download left the engine")

    let subtitle = element("video.subtitle")
    let subtitlesChip = element("video.chip.subtitles")
    app.revealVideoControls(showing: subtitlesChip)
    subtitlesChip.tap()
    let turkishSubtitle = app.buttons.matching(
      NSPredicate(
        format: "identifier BEGINSWITH %@ AND label BEGINSWITH %@", "video.subtitles.", "Turkish")
    ).firstMatch
    XCTAssertTrue(turkishSubtitle.appears(within: 5), "the stored Turkish subtitle is not offered")
    XCTAssertTrue(
      app.buttons.matching(
        NSPredicate(
          format: "identifier BEGINSWITH %@ AND label BEGINSWITH %@", "video.subtitles.",
          "English")
      ).firstMatch.exists, "the stored English subtitle is not offered")
    screenshot("runtime-downloads-offline-direct-play-subtitles")
    turkishSubtitle.tap()
    XCTAssertTrue(
      waitForValue(subtitle, "tr", timeout: 10), "subtitle: \(subtitle.value ?? "")")

    let audio = element("video.audio-language")
    let preferred = try XCTUnwrap(preferredAudioLanguage())
    XCTAssertTrue(
      waitForValue(audio, preferred, timeout: 10),
      "the stored original did not start on the device language \(preferred): \(audio.value ?? "")"
    )
    let audioChip = element("video.chip.audio")
    app.revealVideoControls(showing: audioChip)
    audioChip.tap()
    XCTAssertTrue(app.buttons["video.audio.1"].appears(within: 5), "the Audio chip opened no menu")
    XCTAssertTrue(
      app.buttons["video.audio.2"].exists, "the file's second audio track is not offered")
    screenshot("runtime-downloads-offline-direct-play-audio")
    let other = preferred == "tr" ? "en" : "tr"
    app.buttons[other == "en" ? "video.audio.1" : "video.audio.2"].tap()
    XCTAssertTrue(waitForValue(audio, other, timeout: 10), "audio: \(audio.value ?? "")")

    let position = element("video.current-position")
    XCTAssertTrue(
      waitFor(NSPredicate(format: "value.intValue >= 8"), position, timeout: 20),
      "the stored original is not playing: \(position.value ?? "")")
    assertNoPlaybackRequests(since: requests)
    app.closeVideo()
    let saved = try reportedSeconds()
    XCTAssertNotEqual(
      element("downloads.seeded-position").value as? String, "\(saved)",
      "the position reached put.io with the network cut")

    app.terminate()
    app.launch()
    let relaunchedRequests = openDownloadsCut(item)
    item.tap()
    _ = playStored(startingOver: false)
    XCTAssertTrue(
      waitFor(NSPredicate(format: "value.intValue >= %d", saved - 1), position, timeout: 10),
      "the download did not resume at \(saved): \(position.value ?? "")")
    XCTAssertTrue(
      waitFor(NSPredicate(format: "value.intValue >= %d", saved + 3), position, timeout: 15),
      "the resumed download stopped playing: \(position.value ?? "")")
    assertNoPlaybackRequests(since: relaunchedRequests)
    app.closeVideo()
    let resumed = try reportedSeconds()

    app.terminate()
    app.launchArguments.removeAll { $0 == "--putio-harness-network-cut" }
    app.launch()
    XCTAssertTrue(element("files.screen.0").appears(within: 10))
    XCTAssertTrue(
      waitForValue(element("downloads.seeded-position"), "\(resumed)", timeout: 15),
      "the saved position never reached put.io: \(element("downloads.seeded-position").value ?? "")"
    )

    app.buttons["Account"].tap()
    let signOut = app.revealed("auth.sign-out")
    XCTAssertTrue(signOut.appears(within: 5))
    if !signOut.isHittable { app.swipeUp() }
    signOut.tap()
    app.confirmSignOut()
    XCTAssertTrue(element("auth.sign-in").appears(within: 10))
  }

  func testFileRowsControlDownloadsAndFollowTheDownloadsTab() throws {
    app.launchArguments += ["--putio-harness-downloads", "file-states"]
    app.launch()
    signIn()
    let harnessFolder = element("files.item.410")
    XCTAssertTrue(harnessFolder.appears(within: 10))
    harnessFolder.tap()
    let season = element("files.item.440")
    XCTAssertTrue(season.appears(within: 10))
    season.tap()

    let downloading = element("files.item.442")
    XCTAssertTrue(downloading.appears(within: 10))
    XCTAssertTrue(downloading.label.contains("Downloading"), downloading.label)
    app.buttons["Pause download, \(episode(2))"].tap()
    let resume = app.buttons["Resume download, \(episode(2))"]
    XCTAssertTrue(resume.appears(within: 5), "the row did not pause")
    XCTAssertTrue(downloading.label.contains("Paused"), downloading.label)
    resume.tap()
    XCTAssertTrue(
      app.buttons["Pause download, \(episode(2))"].appears(within: 5), "the row did not resume")

    let failed = element("files.item.448")
    app.bringIntoView(failed)
    XCTAssertTrue(failed.label.contains("Connection lost"), failed.label)
    app.buttons["Retry download, \(episode(6))"].tap()
    XCTAssertTrue(
      app.buttons["Cancel download, \(episode(6))"].appears(within: 5), "retry did not queue")
    XCTAssertTrue(failed.label.contains("Queued"), failed.label)

    app.buttons["Downloads"].tap()
    let downloadsRow = app.revealed("downloads.item.442")
    XCTAssertTrue(waitForValue(downloadsRow, "downloading;42", timeout: 5))
    XCTAssertTrue(waitForValue(app.revealed("downloads.item.448"), "queued", timeout: 5))
    app.buttons["Pause download, \(episode(2))"].tap()
    XCTAssertTrue(waitForValue(downloadsRow, "paused;42", timeout: 5))

    app.buttons["Files"].tap()
    XCTAssertTrue(
      app.buttons["Resume download, \(episode(2))"].appears(within: 5),
      "the open folder missed the pause made in Downloads")

    app.buttons["Account"].tap()
    let signOut = app.revealed("auth.sign-out")
    XCTAssertTrue(signOut.appears(within: 5))
    if !signOut.isHittable { app.swipeUp() }
    signOut.tap()
    let remove = app.buttons["auth.sign-out-remove-downloads"].firstMatch
    if remove.appears(within: 5) { remove.tap() } else { app.confirmSignOut() }
    XCTAssertTrue(element("auth.sign-in").appears(within: 10))
  }

  private func assertNoPlaybackRequests(
    since count: Int, file: StaticString = #filePath, line: UInt = #line
  ) {
    let shellRequests: Set<String> = [
      "GET /v2/config", "GET /v2/files/412/next-file", "POST /v2/files/412/start-from/set",
    ]
    let paths = (element("downloads.cut-paths").value as? String ?? "")
      .split(separator: ",").map(String.init)
    let playback = paths.dropFirst(count).filter { !shellRequests.contains($0) }
    XCTAssertEqual(
      playback, [], "playing the download asked the network for it", file: file, line: line)
  }

  private func openDownloadsCut(_ item: XCUIElement) -> Int {
    let downloads = app.buttons["Downloads"]
    XCTAssertTrue(downloads.appears(within: 15), "the signed-in shell did not open offline")
    downloads.tap()
    XCTAssertTrue(item.appears(within: 10))
    XCTAssertEqual(item.value as? String, "completed;watched")
    RunLoop.current.run(until: .now.addingTimeInterval(2))
    return Int(element("downloads.cut-requests").value as? String ?? "") ?? 0
  }

  private func preferredAudioLanguage() -> String? {
    guard let flag = app.launchArguments.firstIndex(of: "--putio-harness-preferred-languages"),
      app.launchArguments.indices.contains(flag + 1)
    else { return nil }
    return app.launchArguments[flag + 1].split(separator: ",").first.map(String.init)
  }

  private func playStored(startingOver: Bool) -> String? {
    let choice = app.buttons[startingOver ? "video.resume.start-over" : "video.resume.resume"]
      .firstMatch
    if choice.waitForExistence(timeout: 8) { choice.tap() }
    XCTAssertTrue(element("video.ready").appears(within: 20), "the download did not play")
    let source = element("video.source")
    _ = waitForValue(source, "original-engine", timeout: 10)
    return source.value as? String
  }

  private func reportedSeconds() throws -> Int {
    let reported = element("video.position-reported")
    XCTAssertTrue(
      waitFor(NSPredicate(format: "value BEGINSWITH 'id=412;'"), reported, timeout: 10),
      "closing the video saved no position")
    RunLoop.current.run(until: .now.addingTimeInterval(1))
    let value = try XCTUnwrap(reported.value as? String)
    return try XCTUnwrap(value.split(separator: "=").last.flatMap { Int($0) }, value)
  }

  private func waitFor(_ predicate: NSPredicate, _ element: XCUIElement, timeout: TimeInterval)
    -> Bool
  {
    let expectation = XCTNSPredicateExpectation(predicate: predicate, object: element)
    return XCTWaiter.wait(for: [expectation], timeout: timeout) == .completed
  }

  private func choosePlaybackMethod(_ name: String) {
    app.buttons["Account"].tap()
    let method = app.revealed("playback-settings.method")
    XCTAssertTrue(method.appears(within: 10))
    method.tap()
    let choice = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", name)).firstMatch
    XCTAssertTrue(choice.appears(within: 5))
    choice.tap()
    let failed = app.staticTexts["Couldn’t save this setting"]
    if failed.waitForExistence(timeout: 5) {
      XCTAssertTrue(failed.disappears(within: 10))
      choice.tap()
    }
    app.navigationBars.buttons["BackButton"].tap()
    XCTAssertTrue(
      waitUntil(timeout: 10) { method.label.hasSuffix(name) }, "method row read \(method.label)")
    app.buttons["Files"].tap()
    XCTAssertTrue(element("files.screen.0").appears(within: 10))
  }

  private func episode(_ number: Int) -> String {
    "Blue.Lights.S04E0\(number).1080p.HDTV.H264-ORGANiC.mkv"
  }

  private func openAudioChip() {
    let chip = element("video.chip.audio")
    for _ in 0..<3 {
      app.revealVideoControls(showing: chip)
      chip.tap()
      if element("video.audio.0").waitForExistence(timeout: 3) { return }
    }
    XCTFail("the Audio chip opened no menu")
  }

  private func positionReport(_ probe: XCUIElement) -> (id: String, seconds: String)? {
    let fields = (probe.value as? String ?? "").split(separator: ";").map {
      $0.split(separator: "=", maxSplits: 1).last.map(String.init) ?? ""
    }
    guard fields.count == 2 else { return nil }
    return (fields[0], fields[1])
  }

  private func waitUntil(timeout: TimeInterval, _ condition: @escaping () -> Bool) -> Bool {
    let expectation = XCTNSPredicateExpectation(
      predicate: NSPredicate { _, _ in condition() }, object: nil)
    return XCTWaiter.wait(for: [expectation], timeout: timeout) == .completed
  }

  private func signIn() {
    let button = element("auth.sign-in")
    XCTAssertTrue(button.appears(within: 10))
    button.tap()
    XCTAssertTrue(element("files.screen.0").appears(within: 10))
  }

  private func waitForValue(_ element: XCUIElement, _ value: String, timeout: TimeInterval)
    -> Bool
  {
    let expectation = XCTNSPredicateExpectation(
      predicate: NSPredicate(format: "value == %@", value), object: element)
    return XCTWaiter.wait(for: [expectation], timeout: timeout) == .completed
  }

  private func element(_ identifier: String) -> XCUIElement {
    app.descendants(matching: .any)[identifier]
  }

  private func storedDownload(_ fileID: Int) throws -> URL {
    let fileManager = FileManager.default
    let containers = URL(fileURLWithPath: NSHomeDirectory()).deletingLastPathComponent()
    var newest: (container: URL, queue: URL, date: Date)?
    for container in try fileManager.contentsOfDirectory(
      at: containers, includingPropertiesForKeys: nil)
    {
      let queue = container.appending(path: "tmp/harness-offline/queue.json")
      guard
        let date = try? queue.resourceValues(forKeys: [.contentModificationDateKey])
          .contentModificationDate
      else { continue }
      if newest.map({ date > $0.date }) ?? true { newest = (container, queue, date) }
    }
    let found = try XCTUnwrap(newest, "no offline queue under \(containers.path)")
    let document = try XCTUnwrap(
      JSONSerialization.jsonObject(with: Data(contentsOf: found.queue)) as? [String: Any])
    let items = try XCTUnwrap(document["items"] as? [[String: Any]])
    let item = try XCTUnwrap(items.first { $0["id"] as? Int == fileID }, "no queue item \(fileID)")
    let localPath = try XCTUnwrap(item["localPath"] as? String, "item \(fileID) has no local path")
    return localPath.hasPrefix("/")
      ? URL(fileURLWithPath: localPath) : found.container.appending(path: localPath)
  }

  private func rowBand(_ row: XCUIElement) -> CGRect {
    CGRect(
      x: 0, y: row.frame.minY, width: app.windows.firstMatch.frame.width,
      height: row.frame.height)
  }

  private func screenshot(_ name: String) {
    let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
    attachment.name = name
    attachment.lifetime = .keepAlways
    add(attachment)
  }
}
