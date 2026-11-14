import XCTest

final class ConversionGateJourneyTests: XCTestCase {
  private var app: XCUIApplication!

  override func setUpWithError() throws {
    try super.setUpWithError()
    continueAfterFailure = false
    app = XCUIApplication()
    app.launchArguments = [
      "--putio-harness-scenario", "files-browser", "--putio-harness-vlc-installed",
    ]
    app.launchEnvironment["PUTIO_HARNESS_MEDIA_BASE_URL"] = try XCTUnwrap(
      ProcessInfo.processInfo.environment["PUTIO_HARNESS_MEDIA_BASE_URL"])
  }

  func testCancelLeavesTheConversionRunningAndReopeningShowsWhereItStands() {
    launch(conversion: "converting")
    openEpisode()

    let progress = element("video.conversion-progress")
    XCTAssertTrue(progress.appears(within: 10), "the gate never showed the conversion progress")
    XCTAssertEqual(
      element("video.conversion-history").value as? String, "queued,converting",
      "the gate did not wait in the queue before converting")
    XCTAssertTrue(app.staticTexts["Converting to MP4"].exists)
    XCTAssertEqual(progress.value as? String, "62%")
    XCTAssertTrue(
      app.staticTexts[
        "This video can’t play in its original format, so put.io started a conversion. It keeps going if you leave."
      ].exists)
    screenshot("runtime-conversion-converting")

    let requests = element("vlc.requests")
    app.buttons["Open in VLC"].tap()
    XCTAssertTrue(
      waitForValue(
        requests,
        "1|vlc-x-callback://x-callback-url/stream?url=https://api.put.io/v2/files/441/download"
          + "&x-success=putio:///files/440"),
      "Open in VLC did not hand the episode off: \(requests.value ?? "")")

    app.buttons["Cancel"].tap()
    XCTAssertTrue(app.videoClose.disappears(within: 5), "Cancel did not leave the gate")
    XCTAssertTrue(element("files.screen.440").appears(within: 5), "Cancel did not return")
    let reads = element("video.conversion-reads")
    let readsAfterCancel = reads.value as? String
    XCTAssertFalse(
      reads.waitForValue(notEqualTo: readsAfterCancel, within: 4),
      "the closed gate kept reading the conversion status")

    openEpisode()
    XCTAssertTrue(progress.appears(within: 10), "reopening did not show the running conversion")
    XCTAssertEqual(progress.value as? String, "62%")
    screenshot("runtime-conversion-reopened")
    app.buttons["Cancel"].tap()
    XCTAssertTrue(app.videoClose.disappears(within: 5), "Cancel did not leave the gate")
  }

  func testCompletedConversionPlaysWithoutATap() {
    launch(conversion: "completes")
    openEpisode()

    XCTAssertTrue(
      element("video.ready").appears(within: 20), "the converted episode never started playing")
    XCTAssertEqual(
      element("video.conversion-history").value as? String, "queued,converting,completed")
    XCTAssertFalse(element("video.error").exists)
    screenshot("runtime-conversion-completed")
    app.closeVideo()
  }

  func testFailedConversionConvertsAgain() {
    launch(conversion: "failed")
    openEpisode()

    XCTAssertTrue(element("video.error").appears(within: 10), "the conversion never failed")
    XCTAssertTrue(app.staticTexts["Conversion failed"].exists)
    let reads = element("video.conversion-reads")
    let readsBefore = reads.value as? String
    app.buttons["Convert again"].tap()
    XCTAssertTrue(
      reads.waitForValue(notEqualTo: readsBefore, within: 10),
      "Convert again did not check the new conversion")
    XCTAssertTrue(app.staticTexts["Conversion failed"].appears(within: 10))
    screenshot("runtime-conversion-failed")
  }

  func testCannotConvertOffersOnlyVLC() {
    launch(conversion: "unavailable")
    openEpisode()

    XCTAssertTrue(
      app.staticTexts["Can’t play this file"].appears(within: 10),
      "a video that cannot convert never said so")
    XCTAssertFalse(app.buttons["Try again"].exists, "a final state offers Try again")
    XCTAssertFalse(app.buttons["Convert again"].exists, "a final state offers Convert again")
    app.buttons["Open in VLC"].tap()
    XCTAssertTrue(
      waitForValue(element("vlc.requests"), prefix: "1|vlc-x-callback://"),
      "Open in VLC did not hand the episode off")
  }

  func testLostStatusCheckNeverReadsAsFailedAndRetries() {
    launch(conversion: "offline")
    openEpisode()

    XCTAssertTrue(
      app.staticTexts["Can’t check conversion status"].appears(within: 10),
      "a failed status read did not say so")
    XCTAssertFalse(app.staticTexts["Conversion failed"].exists)
    let reads = element("video.conversion-reads")
    let readsBefore = reads.value as? String
    app.buttons["Try again"].tap()
    XCTAssertTrue(
      reads.waitForValue(notEqualTo: readsBefore, within: 10),
      "Try again did not read the status again")
  }

  private func launch(conversion: String) {
    app.launchArguments += ["--putio-harness-episode-conversion", conversion]
    app.launch()
    let signIn = element("auth.sign-in")
    let season = element("files.screen.440")
    let screens = [0, 410].map { element("files.screen.\($0)") }
    let deadline = Date.now.addingTimeInterval(15)
    while !signIn.exists, !season.exists, !screens.contains(where: \.exists), Date.now < deadline {
      _ = signIn.appears(within: 0.5)
    }
    if signIn.exists { signIn.tap() }
    for (screen, id) in zip(screens, [410, 440]) where !season.exists {
      guard screen.appears(within: 10) else { continue }
      let folder = element("files.item.\(id)")
      XCTAssertTrue(folder.appears(within: 10), "folder \(id) never appeared")
      folder.tap()
    }
    XCTAssertTrue(season.appears(within: 10), "the season never opened")
  }

  private func openEpisode() {
    let episode = element("files.item.441")
    XCTAssertTrue(episode.appears(within: 10), "the first episode never appeared")
    episode.tap()
    let detailPlay = element("files.detail.play")
    if detailPlay.appears(within: 3) { detailPlay.tap() }
    XCTAssertTrue(app.videoClose.appears(within: 10), "the gate never opened")
    XCTAssertEqual(
      element("video.title").label, "Blue.Lights.S04E01.1080p.HDTV.H264-ORGANiC.mkv")
  }

  private func waitForValue(_ element: XCUIElement, _ value: String) -> Bool {
    let expectation = XCTNSPredicateExpectation(
      predicate: NSPredicate(format: "value == %@", value), object: element)
    return XCTWaiter.wait(for: [expectation], timeout: 10) == .completed
  }

  private func waitForValue(_ element: XCUIElement, prefix: String) -> Bool {
    let expectation = XCTNSPredicateExpectation(
      predicate: NSPredicate(format: "value BEGINSWITH %@", prefix), object: element)
    return XCTWaiter.wait(for: [expectation], timeout: 10) == .completed
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

extension XCUIElement {
  fileprivate func waitForValue(notEqualTo value: String?, within timeout: TimeInterval) -> Bool {
    let expectation = XCTNSPredicateExpectation(
      predicate: NSPredicate { object, _ in
        (object as? XCUIElement)?.value as? String != value
      }, object: self)
    return XCTWaiter.wait(for: [expectation], timeout: timeout) == .completed
  }
}
