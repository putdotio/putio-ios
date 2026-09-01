import XCTest

final class FilesBrowserJourneyTests: XCTestCase {
  private var app: XCUIApplication!

  override func setUpWithError() throws {
    try super.setUpWithError()
    continueAfterFailure = false
    app = XCUIApplication()
    app.launchArguments = [
      "--putio-harness-scenario",
      "files-browser",
    ]
    app.launchEnvironment["PUTIO_HARNESS_MEDIA_BASE_URL"] = try XCTUnwrap(
      ProcessInfo.processInfo.environment["PUTIO_HARNESS_MEDIA_BASE_URL"]
    )
  }

  func testRunnableAlphaLoop() {
    app.launch()

    let signIn = element(identifier: "auth.sign-in")
    XCTAssertTrue(signIn.waitForExistence(timeout: 10), "sign-in screen never appeared")
    let root = element(identifier: "files.screen.0")
    let folder = element(identifier: "files.item.410")
    addScreenshot(named: "runtime-sign-in")

    XCTAssertTrue(signIn.isHittable, "sign-in action is not tappable")
    signIn.tap()
    XCTAssertTrue(root.waitForExistence(timeout: 10), "signed-in root browser never appeared")
    XCTAssertTrue(folder.isHittable, "seeded folder is not tappable after sign-in")

    app.terminate()
    app.launch()

    XCTAssertTrue(root.waitForExistence(timeout: 10), "persisted session did not restore")
    XCTAssertFalse(signIn.exists, "restored session returned to sign-in")
    XCTAssertTrue(folder.isHittable, "seeded folder is not tappable after restore")

    folder.tap()

    let nested = element(identifier: "files.screen.410")
    let nestedFile = element(identifier: "files.item.411")
    XCTAssertTrue(nested.waitForExistence(timeout: 10), "nested browser never appeared")
    XCTAssertTrue(nestedFile.waitForExistence(timeout: 5), "seeded nested file never appeared")
    XCTAssertEqual(nestedFile.value as? String, "Watched, resume position 90 seconds")
    nestedFile.tap()
    let done = element(identifier: "video.done")
    XCTAssertTrue(done.waitForExistence(timeout: 5), "video screen never appeared")
    let loading = element(identifier: "video.loading")
    XCTAssertTrue(loading.waitForNonExistence(timeout: 5), "video source never resolved")
    XCTAssertFalse(
      element(identifier: "video.conversion-required").exists,
      "video unexpectedly requires conversion"
    )
    let playbackError = element(identifier: "video.error")
    XCTAssertTrue(
      playbackError.waitForExistence(timeout: 10),
      "malformed HLS fixture did not produce a recoverable playback failure"
    )
    let retry = app.buttons["Try again"]
    XCTAssertTrue(retry.isHittable, "playback retry is not tappable")
    retry.tap()
    XCTAssertTrue(
      element(identifier: "video.ready").waitForExistence(timeout: 10),
      "bundled HLS fixture never became ready"
    )
    XCTAssertFalse(playbackError.exists, "playback error remained after retry")
    let resumePosition = element(identifier: "video.resume-position")
    XCTAssertTrue(resumePosition.exists, "resolved resume position is not observable")
    XCTAssertEqual(resumePosition.value as? String, "90")
    addScreenshot(named: "runtime-playback")
    XCTAssertTrue(done.isHittable, "video Done button is not tappable")
    done.tap()

    XCTAssertTrue(nested.waitForExistence(timeout: 5), "file selection left the browser")
    XCTAssertTrue(nestedFile.isHittable, "selected file is no longer available")

    let selection = element(identifier: "files.selection")
    XCTAssertEqual(selection.label, "Selected file route")
    XCTAssertEqual(selection.value as? String, "id=411;parent=410;kind=video")

    let navigationBar = app.navigationBars["Harness Folder"]
    XCTAssertTrue(navigationBar.waitForExistence(timeout: 5), "nested navigation bar is missing")
    let backButton = navigationBar.buttons["Files"]
    XCTAssertTrue(backButton.isHittable, "native Files back button is not tappable")
    backButton.tap()

    XCTAssertTrue(
      navigationBar.waitForNonExistence(timeout: 5),
      "native Back transition did not finish"
    )

    XCTAssertTrue(root.waitForExistence(timeout: 5), "root browser did not return")
    XCTAssertTrue(folder.isHittable, "root folder is not tappable after returning")
    XCTAssertFalse(nestedFile.isHittable, "nested content remains visible after returning")

    let account = app.buttons["Account"]
    XCTAssertTrue(account.isHittable, "Account tab is not tappable")
    account.tap()
    let signOut = element(identifier: "auth.sign-out")
    XCTAssertTrue(signOut.waitForExistence(timeout: 5), "sign-out action never appeared")
    XCTAssertTrue(signOut.isHittable, "sign-out action is not tappable")
    signOut.tap()

    XCTAssertTrue(signIn.waitForExistence(timeout: 10), "sign-out did not return to sign-in")
    addScreenshot(named: "runtime-signed-out")
  }

  func testUnsupportedFileIsNotActionable() {
    app.launch()

    let signIn = element(identifier: "auth.sign-in")
    XCTAssertTrue(signIn.waitForExistence(timeout: 10), "sign-in screen never appeared")
    signIn.tap()

    let root = element(identifier: "files.screen.0")
    XCTAssertTrue(root.waitForExistence(timeout: 10), "signed-in root browser never appeared")
    let unsupportedFile = app.staticTexts["Document.pdf"]
    XCTAssertTrue(unsupportedFile.exists, "unsupported file row is missing")
    XCTAssertEqual(unsupportedFile.elementType, .staticText)
    XCTAssertFalse(app.buttons["files.item.413"].exists)
    if unsupportedFile.isHittable {
      unsupportedFile.tap()
    }
    XCTAssertTrue(root.exists, "unsupported file selection left the browser")
    XCTAssertFalse(element(identifier: "files.selection").exists)

    app.buttons["Account"].tap()
    let signOut = element(identifier: "auth.sign-out")
    XCTAssertTrue(signOut.waitForExistence(timeout: 5), "sign-out action never appeared")
    signOut.tap()
    XCTAssertTrue(signIn.waitForExistence(timeout: 10), "sign-out did not return to sign-in")
  }

  func testPlaybackPositionPersistsAcrossReopen() {
    app.launch()

    let signIn = element(identifier: "auth.sign-in")
    XCTAssertTrue(signIn.waitForExistence(timeout: 10), "sign-in screen never appeared")
    signIn.tap()

    let folder = element(identifier: "files.item.410")
    XCTAssertTrue(folder.waitForExistence(timeout: 10), "seeded folder never appeared")
    folder.tap()

    let nested = element(identifier: "files.screen.410")
    let nestedFile = element(identifier: "files.item.411")
    XCTAssertTrue(nested.waitForExistence(timeout: 10), "nested browser never appeared")
    XCTAssertTrue(nestedFile.waitForExistence(timeout: 5), "seeded nested file never appeared")
    nestedFile.tap()

    let done = element(identifier: "video.done")
    XCTAssertTrue(done.waitForExistence(timeout: 5), "video screen never appeared")
    let playbackError = element(identifier: "video.error")
    XCTAssertTrue(
      playbackError.waitForExistence(timeout: 10),
      "malformed HLS fixture did not produce a recoverable playback failure"
    )
    let retry = app.buttons["Try again"]
    XCTAssertTrue(retry.isHittable, "playback retry is not tappable")
    retry.tap()
    XCTAssertTrue(
      element(identifier: "video.ready").waitForExistence(timeout: 10),
      "bundled HLS fixture never became ready"
    )

    let resumePosition = element(identifier: "video.resume-position")
    XCTAssertTrue(resumePosition.exists, "resolved resume position is not observable")
    XCTAssertEqual(resumePosition.value as? String, "90")
    let currentPosition = element(identifier: "video.current-position")
    let advancedPlayback = XCTNSPredicateExpectation(
      predicate: NSPredicate { object, _ in
        guard let element = object as? XCUIElement else { return false }
        return Int(element.value as? String ?? "") ?? -1 > 90
      },
      object: currentPosition
    )
    XCTAssertEqual(
      XCTWaiter.wait(for: [advancedPlayback], timeout: 10),
      .completed,
      "playback did not advance beyond the seeded resume position"
    )
    XCTAssertTrue(done.isHittable, "video Done button is not tappable")
    done.tap()

    XCTAssertTrue(nested.waitForExistence(timeout: 5), "video did not return to folder")
    let reportedPosition = element(identifier: "video.position-reported")
    XCTAssertTrue(
      reportedPosition.waitForExistence(timeout: 5),
      "final playback position was not persisted"
    )
    let persistedSeconds = reportedPlaybackSeconds(from: reportedPosition.value as? String)
    XCTAssertNotNil(persistedSeconds, "reported playback position has an unexpected format")
    XCTAssertGreaterThan(
      persistedSeconds ?? -1,
      90,
      "reported playback position did not advance beyond the seeded row value"
    )
    let refreshedRowValue = persistedSeconds.map {
      "Watched, resume position \($0) seconds"
    }
    let rowRefresh = XCTNSPredicateExpectation(
      predicate: NSPredicate(format: "value == %@", refreshedRowValue ?? ""),
      object: nestedFile
    )
    XCTAssertEqual(
      XCTWaiter.wait(for: [rowRefresh], timeout: 5),
      .completed,
      "folder row did not refresh after the position report completed"
    )

    nestedFile.tap()
    XCTAssertTrue(done.waitForExistence(timeout: 5), "reopened video screen never appeared")
    XCTAssertTrue(
      resumePosition.waitForExistence(timeout: 5),
      "persisted resume position did not resolve on reopen"
    )
    XCTAssertEqual(resumePosition.value as? String, persistedSeconds.map(String.init))
    XCTAssertTrue(done.isHittable, "reopened video Done button is not tappable")
    done.tap()

    XCTAssertTrue(nested.waitForExistence(timeout: 5), "reopened video did not return to folder")
    let navigationBar = app.navigationBars["Harness Folder"]
    let backButton = navigationBar.buttons["Files"]
    XCTAssertTrue(backButton.isHittable, "native Files back button is not tappable")
    backButton.tap()

    let root = element(identifier: "files.screen.0")
    let rootVideo = element(identifier: "files.item.412")
    XCTAssertTrue(root.waitForExistence(timeout: 5), "root browser did not return")
    XCTAssertEqual(rootVideo.value as? String, "Watched, resume position 589 seconds")
    rootVideo.tap()
    XCTAssertTrue(done.waitForExistence(timeout: 5), "root video screen never appeared")
    XCTAssertTrue(
      element(identifier: "video.ready").waitForExistence(timeout: 10),
      "root video never became ready near EOF"
    )
    XCTAssertTrue(
      element(identifier: "video.ended").waitForExistence(timeout: 10),
      "root video never reached EOF"
    )
    XCTAssertTrue(done.isHittable, "root video Done button is not tappable")
    done.tap()

    XCTAssertTrue(root.waitForExistence(timeout: 5), "root video did not return to folder")
    let resetPosition = XCTNSPredicateExpectation(
      predicate: NSPredicate(format: "value == %@", "id=412;seconds=0"),
      object: reportedPosition
    )
    XCTAssertEqual(
      XCTWaiter.wait(for: [resetPosition], timeout: 5),
      .completed,
      "root video did not report the EOF reset"
    )
    let unwatchedRow = XCTNSPredicateExpectation(
      predicate: NSPredicate(format: "value == %@", "Not watched"),
      object: rootVideo
    )
    XCTAssertEqual(
      XCTWaiter.wait(for: [unwatchedRow], timeout: 5),
      .completed,
      "root row did not refresh after the EOF reset"
    )

    app.buttons["Account"].tap()
    let signOut = element(identifier: "auth.sign-out")
    XCTAssertTrue(signOut.waitForExistence(timeout: 5), "sign-out action never appeared")
    signOut.tap()
    XCTAssertTrue(signIn.waitForExistence(timeout: 10), "sign-out did not return to sign-in")
  }

  private func reportedPlaybackSeconds(from value: String?) -> Int? {
    let prefix = "id=411;seconds="
    guard let value, value.hasPrefix(prefix) else {
      return nil
    }
    return Int(value.dropFirst(prefix.count))
  }

  private func element(identifier: String) -> XCUIElement {
    app.descendants(matching: .any)[identifier]
  }

  private func addScreenshot(named name: String) {
    let attachment = XCTAttachment(screenshot: app.screenshot())
    attachment.name = name
    attachment.lifetime = .keepAlways
    add(attachment)
  }
}
