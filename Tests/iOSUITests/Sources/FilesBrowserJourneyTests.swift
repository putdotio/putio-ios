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
    addScreenshot(named: "runtime-sign-in")

    XCTAssertTrue(signIn.isHittable, "sign-in action is not tappable")
    signIn.tap()
    XCTAssertTrue(root.waitForExistence(timeout: 10), "signed-in root browser never appeared")

    let rootVideo = element(identifier: "files.item.412")
    let done = element(identifier: "video.done")
    XCTAssertEqual(rootVideo.value as? String, "Watched, resume position 589 seconds")
    XCTAssertTrue(rootVideo.isHittable, "root video row is not tappable")
    let presentedRoute = element(identifier: "video.presented-route")
    rootVideo.tap()
    let rootRoute = XCTNSPredicateExpectation(
      predicate: NSPredicate(format: "value == %@", "id=412"),
      object: presentedRoute
    )
    XCTAssertEqual(
      XCTWaiter.wait(for: [rootRoute], timeout: 5),
      .completed,
      "root video tap did not select route 412"
    )
    XCTAssertTrue(done.waitForExistence(timeout: 5), "root video screen never appeared")
    let playbackError = element(identifier: "video.error")
    XCTAssertTrue(
      playbackError.waitForExistence(timeout: 5),
      "invalid playback fixture did not produce a recoverable failure"
    )
    let retry = app.buttons["Try again"]
    XCTAssertTrue(retry.isHittable, "playback retry is not tappable")
    retry.tap()
    XCTAssertTrue(
      element(identifier: "video.ready").waitForExistence(timeout: 10),
      "root video never became ready near EOF"
    )
    let nextTitle = element(identifier: "video.next-title")
    XCTAssertTrue(nextTitle.waitForExistence(timeout: 15), "next-video suggestion never appeared")
    XCTAssertFalse(
      rootVideo.isHittable,
      "root browser remained interactive while the next-video player was presented"
    )
    let nextVideoAttachment = screenshotAttachment(named: "runtime-playback")
    XCTAssertEqual(nextTitle.label, "Up next, Root Movie 2.mkv")
    XCTAssertTrue(
      element(identifier: "video.play-next").isHittable,
      "manual play-next action is not tappable"
    )
    XCTAssertTrue(
      element(identifier: "video.cancel-next").isHittable,
      "next-video cancellation is not tappable"
    )
    add(nextVideoAttachment)
    XCTAssertTrue(
      element(identifier: "video.ended").waitForExistence(timeout: 5),
      "root video never reached EOF"
    )
    let reportedPosition = element(identifier: "video.position-reported")
    XCTAssertEqual(
      reportedPosition.value as? String,
      "id=412;seconds=0",
      "next-video suggestion appeared before the completed position reset drained"
    )
    let successorRoute = XCTNSPredicateExpectation(
      predicate: NSPredicate(format: "value == %@", "id=414"),
      object: presentedRoute
    )
    XCTAssertEqual(
      XCTWaiter.wait(for: [successorRoute], timeout: 10),
      .completed,
      "autoplay did not select the successor route"
    )
    let successorResumePosition = XCTNSPredicateExpectation(
      predicate: NSPredicate(format: "value == %@", "37"),
      object: element(identifier: "video.resume-position")
    )
    XCTAssertEqual(
      XCTWaiter.wait(for: [successorResumePosition], timeout: 10),
      .completed,
      "autoplay did not open the successor at its saved position"
    )
    XCTAssertTrue(done.isHittable, "successor video Done button is not tappable")
    done.tap()

    XCTAssertTrue(root.waitForExistence(timeout: 5), "successor video did not return to root")
    let unwatchedRow = XCTNSPredicateExpectation(
      predicate: NSPredicate(format: "value == %@", "Not watched"),
      object: rootVideo
    )
    XCTAssertEqual(
      XCTWaiter.wait(for: [unwatchedRow], timeout: 5),
      .completed,
      "root row did not refresh after the EOF reset"
    )

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
    let conversionError = element(identifier: "video.error")
    XCTAssertTrue(
      conversionError.waitForExistence(timeout: 5),
      "first conversion request did not produce a recoverable failure"
    )
    let retry = app.buttons["Try again"]
    XCTAssertTrue(retry.isHittable, "conversion retry is not tappable")
    retry.tap()
    XCTAssertTrue(
      element(identifier: "video.conversion-progress").waitForExistence(timeout: 5),
      "conversion progress never appeared"
    )
    XCTAssertTrue(
      element(identifier: "video.ready").waitForExistence(timeout: 10),
      "converted video never became ready through native HLS"
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

    XCTAssertTrue(
      element(identifier: "files.screen.0").waitForExistence(timeout: 5),
      "root browser did not return"
    )

    app.buttons["Account"].tap()
    let signOut = element(identifier: "auth.sign-out")
    XCTAssertTrue(signOut.waitForExistence(timeout: 5), "sign-out action never appeared")
    signOut.tap()
    XCTAssertTrue(signIn.waitForExistence(timeout: 10), "sign-out did not return to sign-in")
  }

  func testFileActionsCreateRenameRollbackRetryAndTrash() {
    app.launch()

    let signIn = element(identifier: "auth.sign-in")
    XCTAssertTrue(signIn.waitForExistence(timeout: 10), "sign-in screen never appeared")
    signIn.tap()

    let root = element(identifier: "files.screen.0")
    XCTAssertTrue(root.waitForExistence(timeout: 10), "signed-in root browser never appeared")
    let newFolder = app.buttons["files.new-folder"]
    XCTAssertTrue(
      waitUntilHittable(newFolder, timeout: 5),
      "new-folder action is not tappable"
    )
    newFolder.tap()

    XCTAssertTrue(app.staticTexts["New Folder"].waitForExistence(timeout: 5))
    let createNameField = element(identifier: "files.action-name")
    XCTAssertTrue(
      createNameField.waitForExistence(timeout: 5),
      "new-folder name field never appeared"
    )
    createNameField.tap()
    createNameField.typeText("Watch Later")
    XCTAssertEqual(createNameField.value as? String, "Watch Later")
    let create = app.buttons["Create"]
    XCTAssertTrue(
      waitUntilHittable(create, timeout: 5),
      "create-folder action is not tappable"
    )
    create.tap()

    let createdFolder = element(identifier: "files.item.415")
    XCTAssertTrue(createdFolder.waitForExistence(timeout: 5), "created folder never appeared")
    XCTAssertEqual(createdFolder.label, "Watch Later")

    openContextMenu(for: createdFolder, actionLabel: "Rename").tap()
    XCTAssertTrue(app.staticTexts["Rename Item"].waitForExistence(timeout: 5))
    let firstRenameField = element(identifier: "files.action-name")
    XCTAssertTrue(firstRenameField.waitForExistence(timeout: 5), "rename name field never appeared")
    replaceText(in: firstRenameField, currentValue: "Watch Later", with: "Weekend")
    XCTAssertEqual(firstRenameField.value as? String, "Weekend")
    let firstRename = app.buttons["Rename"]
    XCTAssertTrue(
      waitUntilHittable(firstRename, timeout: 5),
      "rename action is not tappable"
    )
    firstRename.tap()

    let createdFolderButton = app.buttons["files.item.415"]
    XCTAssertTrue(
      createdFolderButton.waitForExistence(timeout: 3),
      "folder control disappeared while rename was pending"
    )
    let disabled = XCTNSPredicateExpectation(
      predicate: NSPredicate(format: "enabled == false"),
      object: createdFolderButton
    )
    XCTAssertEqual(
      XCTWaiter.wait(for: [disabled], timeout: 3),
      .completed,
      "folder navigation did not become disabled while rename was pending"
    )
    XCTAssertEqual(createdFolderButton.label, "Weekend")
    let createdFolderScreen = element(identifier: "files.screen.415")
    XCTAssertFalse(
      createdFolderScreen.waitForExistence(timeout: 1),
      "folder navigation remained enabled while rename was pending"
    )

    let renameFailure = app.staticTexts["Could not rename item"]
    XCTAssertTrue(renameFailure.waitForExistence(timeout: 5), "rename failure was not surfaced")
    XCTAssertTrue(
      createdFolderButton.waitForExistence(timeout: 5) && createdFolderButton.isHittable,
      "folder navigation did not re-enable after rename failure"
    )
    XCTAssertEqual(createdFolderButton.label, "Watch Later", "failed rename did not roll back")
    XCTAssertTrue(
      renameFailure.waitForNonExistence(timeout: 5), "rename failure toast did not clear")

    openContextMenu(for: createdFolder, actionLabel: "Rename").tap()
    XCTAssertTrue(app.staticTexts["Rename Item"].waitForExistence(timeout: 5))
    let retryRenameField = element(identifier: "files.action-name")
    XCTAssertTrue(
      retryRenameField.waitForExistence(timeout: 5), "retry rename field never appeared")
    replaceText(in: retryRenameField, currentValue: "Watch Later", with: "Weekend")
    XCTAssertEqual(retryRenameField.value as? String, "Weekend")
    let retryRename = app.buttons["Rename"]
    XCTAssertTrue(
      waitUntilHittable(retryRename, timeout: 5),
      "retry rename action is not tappable"
    )
    retryRename.tap()

    let renamedFolder = element(identifier: "files.item.415")
    let renamed = XCTNSPredicateExpectation(
      predicate: NSPredicate(format: "label == %@", "Weekend"),
      object: renamedFolder
    )
    XCTAssertEqual(
      XCTWaiter.wait(for: [renamed], timeout: 5),
      .completed,
      "rename retry did not update the folder"
    )

    let delete = openContextMenu(
      for: renamedFolder,
      actionLabel: "Remove"
    )
    addScreenshot(named: "runtime-file-actions")
    delete.tap()
    let confirmDelete = app.buttons["files.delete-confirm"].firstMatch
    XCTAssertTrue(confirmDelete.waitForExistence(timeout: 5), "remove confirmation never appeared")
    XCTAssertEqual(confirmDelete.label, "Remove")
    XCTAssertTrue(app.staticTexts["put.io will apply your current Trash setting."].exists)
    confirmDelete.tap()
    XCTAssertTrue(
      app.staticTexts["Item removed"].waitForExistence(timeout: 5),
      "neutral remove success was not surfaced"
    )
    XCTAssertTrue(renamedFolder.waitForNonExistence(timeout: 5), "removed folder remained visible")

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

  private func waitUntilHittable(_ element: XCUIElement, timeout: TimeInterval) -> Bool {
    let expectation = XCTNSPredicateExpectation(
      predicate: NSPredicate(format: "hittable == true"),
      object: element
    )
    return XCTWaiter.wait(for: [expectation], timeout: timeout) == .completed
  }

  private func openContextMenu(
    for row: XCUIElement,
    actionLabel: String
  ) -> XCUIElement {
    XCTAssertTrue(row.isHittable, "file row is not available for its context menu")
    row.press(forDuration: 1)
    let action = app.buttons[actionLabel]
    XCTAssertTrue(action.waitForExistence(timeout: 5), "file context-menu action never appeared")
    return action
  }

  private func replaceText(
    in field: XCUIElement,
    currentValue: String,
    with replacement: String
  ) {
    field.tap()
    field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: currentValue.count))
    field.typeText(replacement)
  }

  private func addScreenshot(named name: String) {
    add(screenshotAttachment(named: name))
  }

  private func screenshotAttachment(named name: String) -> XCTAttachment {
    let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
    attachment.name = name
    attachment.lifetime = .keepAlways
    return attachment
  }
}
