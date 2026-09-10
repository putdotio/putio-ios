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
    // Turkish first so the stored English default is not the pick.
    app.launchArguments += ["--putio-harness-preferred-languages", "tr,en"]
  }

  func testMultiAudioDownloadOfflinePlaybackAndPositionSync() throws {
    app.launch()
    signIn()

    // Inventory and bounded multi-select.
    let row = element("files.item.412")
    XCTAssertTrue(row.waitForExistence(timeout: 10))
    row.press(forDuration: 1)
    let download = app.buttons["files.download.412"]
    XCTAssertTrue(download.waitForExistence(timeout: 5))
    download.tap()
    let turkish = element("downloads.track.tr")
    XCTAssertTrue(turkish.waitForExistence(timeout: 20), "track picker never appeared")
    XCTAssertTrue(isOn(turkish), "preferred language was not preselected: \(turkish.value ?? "")")
    let english = element("downloads.track.en")
    XCTAssertFalse(isOn(english))
    english.switches.firstMatch.tap()
    XCTAssertTrue(waitUntil(timeout: 5) { self.isOn(english) })
    XCTAssertTrue(element("downloads.estimate").exists)
    XCTAssertFalse(element("downloads.over-budget").exists)
    screenshot("runtime-downloads-picker")
    app.buttons["downloads.picker.confirm"].tap()

    // Queue: progress through completion.
    let item = element("downloads.item.412")
    XCTAssertTrue(item.waitForExistence(timeout: 10))
    XCTAssertTrue(
      waitForValue(item, "completed", timeout: 90),
      "download did not complete: \(item.value ?? "")")
    XCTAssertTrue(element("downloads.storage-used").exists)
    screenshot("runtime-downloads-queue")

    // Details disclose both stored tracks.
    item.press(forDuration: 1)
    let details = app.buttons["downloads.details.412"]
    XCTAssertTrue(details.waitForExistence(timeout: 5))
    details.tap()
    XCTAssertTrue(element("downloads.detail.412").waitForExistence(timeout: 5))
    XCTAssertTrue(element("downloads.detail.audio.en").waitForExistence(timeout: 5))
    XCTAssertTrue(element("downloads.detail.audio.tr").waitForExistence(timeout: 5))
    screenshot("runtime-downloads-detail")
    app.buttons["downloads.detail.done"].tap()

    // Offline playback; the seeded position endpoint fails, so the
    // position stays pending locally.
    item.tap()
    let ready = element("video.ready")
    XCTAssertTrue(ready.waitForExistence(timeout: 20))
    let language = element("video.audio-language")
    XCTAssertTrue(language.waitForExistence(timeout: 10))
    XCTAssertEqual(language.value as? String, "tr", "offline playback did not pick Turkish")
    let position = element("video.current-position")
    XCTAssertTrue(position.waitForExistence(timeout: 10))
    let advanced = XCTNSPredicateExpectation(
      predicate: NSPredicate(format: "value != '0'"), object: position)
    XCTAssertEqual(XCTWaiter.wait(for: [advanced], timeout: 15), .completed)
    element("video.done").tap()
    let pending = element("downloads.pending-positions")
    XCTAssertTrue(pending.waitForExistence(timeout: 10))
    XCTAssertEqual(pending.value as? String, "1")

    // Relaunch without the failure flag: the item and its pending position
    // survive, and foregrounding syncs it.
    app.terminate()
    app.launchArguments.removeAll { $0 == "--putio-harness-offline-positions-fail" }
    app.launch()
    XCTAssertTrue(element("files.screen.0").waitForExistence(timeout: 10))
    app.buttons["Downloads"].tap()
    XCTAssertTrue(item.waitForExistence(timeout: 10))
    XCTAssertEqual(item.value as? String, "completed")
    XCTAssertTrue(pending.waitForNonExistence(timeout: 15), "pending position did not sync")

    // Multi-select removal reclaims storage.
    app.buttons["downloads.select"].tap()
    XCTAssertTrue(app.buttons["downloads.remove-selected"].waitForExistence(timeout: 5))
    XCTAssertFalse(app.buttons["downloads.remove-selected"].isEnabled)
    XCTAssertEqual(item.value as? String, "Not selected")
    item.tap()
    XCTAssertTrue(waitUntil(timeout: 5) { self.app.buttons["downloads.remove-selected"].isEnabled })
    XCTAssertEqual(item.value as? String, "Selected")
    app.buttons["downloads.remove-selected"].tap()
    let alert = app.alerts["Remove 1 download?"]
    XCTAssertTrue(alert.waitForExistence(timeout: 5))
    alert.buttons["Remove"].tap()
    XCTAssertTrue(item.waitForNonExistence(timeout: 10))
    XCTAssertTrue(app.staticTexts["No downloads"].waitForExistence(timeout: 5))

    app.buttons["Account"].tap()
    let signOut = element("auth.sign-out")
    XCTAssertTrue(signOut.waitForExistence(timeout: 5))
    if !signOut.isHittable { app.swipeUp() }
    signOut.tap()
    XCTAssertTrue(element("auth.sign-in").waitForExistence(timeout: 10))
  }

  /// Toggle rows expose the switch value as "1"/"0" on the row or its switch.
  private func isOn(_ toggle: XCUIElement) -> Bool {
    let value = (toggle.switches.firstMatch.value ?? toggle.value) as? String
    return value == "1"
  }

  private func waitUntilHittable(_ element: XCUIElement, timeout: TimeInterval) -> Bool {
    let expectation = XCTNSPredicateExpectation(
      predicate: NSPredicate(format: "hittable == true"), object: element)
    return XCTWaiter.wait(for: [expectation], timeout: timeout) == .completed
  }

  private func waitUntil(timeout: TimeInterval, _ condition: @escaping () -> Bool) -> Bool {
    let expectation = XCTNSPredicateExpectation(
      predicate: NSPredicate { _, _ in condition() }, object: nil)
    return XCTWaiter.wait(for: [expectation], timeout: timeout) == .completed
  }

  private func signIn() {
    let button = element("auth.sign-in")
    XCTAssertTrue(button.waitForExistence(timeout: 10))
    button.tap()
    XCTAssertTrue(element("files.screen.0").waitForExistence(timeout: 10))
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

  private func screenshot(_ name: String) {
    let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
    attachment.name = name
    attachment.lifetime = .keepAlways
    add(attachment)
  }
}
