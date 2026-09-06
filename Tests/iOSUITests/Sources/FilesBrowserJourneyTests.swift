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

  func testBulkSelectionControls() {
    app.launch()

    let signIn = element(identifier: "auth.sign-in")
    XCTAssertTrue(signIn.waitForExistence(timeout: 10))
    signIn.tap()
    XCTAssertTrue(element(identifier: "files.screen.0").waitForExistence(timeout: 10))

    let unsupportedFile = tapUnsupportedFileBeforeEditing()

    let successFolder = createFolder(named: "Bulk Success", expectedID: 415)
    let retryFolder = createFolder(named: "Bulk Retry", expectedID: 416)
    let edit = app.buttons["files.selection.toggle"]
    XCTAssertTrue(waitUntilHittable(edit, timeout: 5))
    edit.tap()
    XCTAssertEqual(edit.label, "Done", "selection control did not enter edit mode")
    let bulkMove = app.buttons["files.bulk.move"]
    XCTAssertTrue(bulkMove.waitForExistence(timeout: 5), "bulk toolbar did not appear")
    XCTAssertEqual(unsupportedFile.value as? String, "Not selected")
    XCTAssertFalse(bulkMove.isEnabled)

    let selectAll = app.buttons["files.selection.select-all"]
    XCTAssertTrue(
      waitUntilHittable(selectAll, timeout: 5),
      "select-all action is not hittable: \(selectAll.debugDescription)"
    )
    selectAll.tap()
    XCTAssertEqual(successFolder.value as? String, "Selected")
    XCTAssertEqual(retryFolder.value as? String, "Selected")
    XCTAssertTrue(bulkMove.isEnabled)
    let deselectAll = app.buttons["files.selection.deselect-all"]
    XCTAssertTrue(waitUntilHittable(deselectAll, timeout: 5))
    deselectAll.tap()
    XCTAssertEqual(successFolder.value as? String, "Not selected")
    XCTAssertEqual(retryFolder.value as? String, "Not selected")
    XCTAssertFalse(bulkMove.isEnabled)

    successFolder.tap()
    XCTAssertEqual(successFolder.value as? String, "Selected")
    successFolder.tap()
    XCTAssertEqual(successFolder.value as? String, "Not selected")

    successFolder.tap()
    retryFolder.tap()
    XCTAssertEqual(successFolder.value as? String, "Selected")
    XCTAssertEqual(retryFolder.value as? String, "Selected")
    XCTAssertTrue(bulkMove.isEnabled)
    XCTAssertTrue(waitUntilHittable(bulkMove, timeout: 5))

    let bulkRemove = app.buttons["files.bulk.remove"]
    XCTAssertTrue(waitUntilHittable(bulkRemove, timeout: 5))
    XCTAssertEqual(bulkRemove.label, "Trash")
    bulkRemove.tap()
    XCTAssertTrue(app.staticTexts["Move 2 items to Trash?"].waitForExistence(timeout: 5))
    XCTAssertTrue(app.staticTexts["You can restore these items from Trash."].exists)
    let confirm = app.buttons["files.bulk.remove-confirm"].firstMatch
    XCTAssertTrue(waitUntilHittable(confirm, timeout: 5))
    confirm.tap()
    let progress = element(identifier: "files.bulk.progress")
    XCTAssertTrue(progress.waitForExistence(timeout: 5))
    assertCurrentBulkProgress(progress, itemNames: ["Bulk Success", "Bulk Retry"])
    XCTAssertTrue(
      app.staticTexts["Some items couldn’t be moved to Trash"].waitForExistence(timeout: 10)
    )
    let retry = app.buttons["files.bulk.retry"].firstMatch
    XCTAssertTrue(waitUntilHittable(retry, timeout: 5))
    retry.tap()
    XCTAssertTrue(app.staticTexts["Moved 1 item to Trash."].waitForExistence(timeout: 10))
    XCTAssertTrue(retryFolder.waitForNonExistence(timeout: 5))

    app.buttons["Account"].tap()
    let signOut = element(identifier: "auth.sign-out")
    XCTAssertTrue(signOut.waitForExistence(timeout: 5), "sign-out action never appeared")
    signOut.tap()
    XCTAssertTrue(signIn.waitForExistence(timeout: 10), "sign-out did not return to sign-in")
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

  func testSignOutFailureRecoversWithExplicitRetry() {
    app.launchArguments = [
      "--putio-harness-scenario", "signed-in", "--putio-harness-sign-out-failure",
    ]
    app.launch()
    let account = app.buttons["Account"]
    XCTAssertTrue(account.waitForExistence(timeout: 10), "seeded session did not restore")
    account.tap()
    let signOut = element(identifier: "auth.sign-out")
    XCTAssertTrue(signOut.waitForExistence(timeout: 5), "sign-out action never appeared")
    signOut.tap()
    let retry = element(identifier: "auth.retry-sign-out")
    XCTAssertTrue(retry.waitForExistence(timeout: 15), "failed sign-out did not offer retry")
    XCTAssertTrue(app.staticTexts["Sign-out did not finish"].exists)
    XCTAssertTrue(
      app.staticTexts.matching(
        NSPredicate(
          format: "label == %@",
          "Saved sign-in details could not be removed and put.io could not revoke your session. Check your connection and try again before closing the app."
        )
      ).firstMatch.exists)
    let signIn = element(identifier: "auth.sign-in")
    XCTAssertFalse(signIn.exists, "failed sign-out must not offer a new sign-in")
    addScreenshot(named: "runtime-sign-out-failure")
    XCTAssertTrue(retry.isHittable, "sign-out retry is not tappable")
    retry.tap()
    XCTAssertTrue(signIn.waitForExistence(timeout: 10), "retry did not complete sign-out")
    XCTAssertFalse(retry.exists)
  }

  func testTrashDisabledUsesPermanentDeleteCopyAndVisibleMenu() {
    app.launchArguments.append("--putio-harness-trash-disabled")
    app.launch()

    let signIn = element(identifier: "auth.sign-in")
    XCTAssertTrue(signIn.waitForExistence(timeout: 10), "sign-in screen never appeared")
    signIn.tap()
    XCTAssertTrue(
      element(identifier: "files.screen.0").waitForExistence(timeout: 10),
      "signed-in root browser never appeared"
    )

    let folder = createFolder(named: "Delete Forever", expectedID: 415)
    let moreActions = app.buttons["files.actions.415"]
    XCTAssertTrue(
      waitUntilHittable(moreActions, timeout: 5),
      "visible more-actions control is unavailable"
    )
    XCTAssertEqual(moreActions.label, "More actions for Delete Forever")
    moreActions.tap()

    let delete = app.buttons["files.delete.415"]
    XCTAssertTrue(delete.waitForExistence(timeout: 5), "permanent Delete action is unavailable")
    XCTAssertEqual(delete.label, "Delete")
    delete.tap()
    XCTAssertTrue(
      app.staticTexts["Delete “Delete Forever” permanently?"].waitForExistence(timeout: 5)
    )
    XCTAssertTrue(app.staticTexts["This item cannot be restored."].exists)
    let confirm = app.buttons["files.delete-confirm"].firstMatch
    XCTAssertTrue(waitUntilHittable(confirm, timeout: 5))
    XCTAssertEqual(confirm.label, "Delete")
    confirm.tap()
    XCTAssertTrue(app.staticTexts["Item deleted"].waitForExistence(timeout: 5))
    XCTAssertTrue(folder.waitForNonExistence(timeout: 5))

    app.buttons["Account"].tap()
    let signOut = element(identifier: "auth.sign-out")
    XCTAssertTrue(signOut.waitForExistence(timeout: 5), "sign-out action never appeared")
    signOut.tap()
    XCTAssertTrue(signIn.waitForExistence(timeout: 10), "sign-out did not return to sign-in")
  }

  func testTrashManagementRestoreRetryDeleteAndEmpty() {
    app.launch()

    let signIn = element(identifier: "auth.sign-in")
    XCTAssertTrue(signIn.waitForExistence(timeout: 10))
    signIn.tap()
    XCTAssertTrue(element(identifier: "files.screen.0").waitForExistence(timeout: 10))

    app.buttons["Account"].tap()
    let trashEntry = element(identifier: "account.trash")
    XCTAssertTrue(waitUntilHittable(trashEntry, timeout: 5))
    trashEntry.tap()

    let restoreRow = app.staticTexts["Restore Me"]
    XCTAssertTrue(restoreRow.waitForExistence(timeout: 10))
    let refreshStart = restoreRow.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
    refreshStart.press(
      forDuration: 0.1,
      thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.85)),
      withVelocity: .slow,
      thenHoldForDuration: 1
    )
    let refreshError = app.staticTexts["Could not refresh Trash"]
    XCTAssertTrue(refreshError.waitForExistence(timeout: 5), app.debugDescription)
    XCTAssertTrue(restoreRow.exists, "failed refresh discarded the loaded Trash page")
    addScreenshot(named: "runtime-trash-refresh-error")
    let retryRefresh = app.buttons["Try again"]
    XCTAssertTrue(waitUntilHittable(retryRefresh, timeout: 5))
    retryRefresh.tap()
    XCTAssertTrue(refreshError.waitForNonExistence(timeout: 5))
    XCTAssertFalse(app.staticTexts["Empty Me"].exists)
    let loadMore = app.buttons["trash.load-more"]
    XCTAssertTrue(waitUntilHittable(loadMore, timeout: 5))
    loadMore.tap()
    XCTAssertTrue(app.staticTexts["Empty Me"].waitForExistence(timeout: 5))
    XCTAssertTrue(loadMore.waitForNonExistence(timeout: 5))
    addScreenshot(named: "runtime-trash-loaded")
    let restoreActions = app.buttons["trash.item.419.actions"]
    XCTAssertTrue(waitUntilHittable(restoreActions, timeout: 5))
    restoreActions.tap()
    let restore = app.buttons["trash.restore.419"]
    XCTAssertTrue(waitUntilHittable(restore, timeout: 5))
    restore.tap()
    XCTAssertTrue(element(identifier: "trash.progress").waitForExistence(timeout: 5))
    app.navigationBars.buttons.element(boundBy: 0).tap()

    app.buttons["Files"].tap()
    XCTAssertTrue(
      element(identifier: "files.item.419").waitForExistence(timeout: 10),
      "restored item did not return to its authoritative root destination"
    )
    app.buttons["Account"].tap()
    XCTAssertTrue(waitUntilHittable(trashEntry, timeout: 5))
    trashEntry.tap()
    XCTAssertTrue(app.staticTexts["Delete Me"].waitForExistence(timeout: 5))
    XCTAssertTrue(restoreRow.waitForNonExistence(timeout: 5))

    let deleteRow = app.staticTexts["Delete Me"]
    XCTAssertTrue(deleteRow.waitForExistence(timeout: 5))
    permanentlyDeleteTrashItem(id: 420, name: "Delete Me")
    XCTAssertTrue(
      app.staticTexts["Could not permanently delete item"].waitForExistence(timeout: 5)
    )
    XCTAssertTrue(deleteRow.exists, "failed permanent delete removed the row")

    permanentlyDeleteTrashItem(id: 420, name: "Delete Me")
    XCTAssertTrue(app.staticTexts["Item deleted"].waitForExistence(timeout: 5))
    XCTAssertTrue(deleteRow.waitForNonExistence(timeout: 5))

    let emptyTrash = app.buttons["trash.empty"]
    XCTAssertTrue(waitUntilHittable(emptyTrash, timeout: 5))
    emptyTrash.tap()
    XCTAssertTrue(app.staticTexts["Empty Trash permanently?"].waitForExistence(timeout: 5))
    XCTAssertTrue(
      app.staticTexts["Every item in Trash will be deleted and cannot be restored."].exists
    )
    let confirmEmpty = app.buttons["trash.empty-confirm"].firstMatch
    XCTAssertTrue(waitUntilHittable(confirmEmpty, timeout: 5))
    confirmEmpty.tap()
    XCTAssertTrue(app.staticTexts["Trash is empty"].waitForExistence(timeout: 10))
    XCTAssertTrue(app.staticTexts["Trash emptied"].waitForExistence(timeout: 5))
    let emptyRefreshStart = app.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.25))
    emptyRefreshStart.press(
      forDuration: 0.1,
      thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.85)),
      withVelocity: .slow,
      thenHoldForDuration: 1
    )
    XCTAssertTrue(refreshError.waitForExistence(timeout: 5), app.debugDescription)
    XCTAssertTrue(waitUntilHittable(retryRefresh, timeout: 5))
    retryRefresh.tap()
    XCTAssertTrue(refreshError.waitForNonExistence(timeout: 5))
    XCTAssertTrue(app.staticTexts["Trash is empty"].waitForExistence(timeout: 5))
    addScreenshot(named: "runtime-trash-empty")

    app.navigationBars.buttons.element(boundBy: 0).tap()
    let signOut = element(identifier: "auth.sign-out")
    XCTAssertTrue(signOut.waitForExistence(timeout: 5), "sign-out action never appeared")
    signOut.tap()
    XCTAssertTrue(signIn.waitForExistence(timeout: 10), "sign-out did not return to sign-in")
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

  private func permanentlyDeleteTrashItem(id: Int, name: String) {
    let actions = app.buttons["trash.item.\(id).actions"]
    XCTAssertTrue(waitUntilHittable(actions, timeout: 5))
    actions.tap()
    let delete = app.buttons["trash.delete.\(id)"]
    XCTAssertTrue(waitUntilHittable(delete, timeout: 5))
    delete.tap()
    XCTAssertTrue(
      app.staticTexts["Delete “\(name)” permanently?"].waitForExistence(timeout: 5)
    )
    XCTAssertTrue(app.staticTexts["This item cannot be restored."].exists)
    let confirm = app.buttons["trash.delete-confirm"].firstMatch
    XCTAssertTrue(waitUntilHittable(confirm, timeout: 5))
    confirm.tap()
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
    tapUnsupportedFileBeforeEditing()
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

    openContextMenu(for: renamedFolder, actionLabel: "Move").tap()
    XCTAssertTrue(
      element(identifier: "files.move-screen.0").waitForExistence(timeout: 5),
      "move picker did not open at Files"
    )
    let moveToCurrentFolder = app.buttons["files.move-here.0"]
    XCTAssertTrue(moveToCurrentFolder.exists, "current-folder move action is missing")
    XCTAssertFalse(moveToCurrentFolder.isEnabled, "moving to the current folder is enabled")
    XCTAssertFalse(
      element(identifier: "files.move-folder.415").exists,
      "source folder is available as its own move destination"
    )

    let harnessDestination = element(identifier: "files.move-folder.410")
    XCTAssertTrue(
      waitUntilHittable(harnessDestination, timeout: 5),
      "Harness Folder is not available as a move destination"
    )
    harnessDestination.tap()
    XCTAssertTrue(
      element(identifier: "files.move-screen.410").waitForExistence(timeout: 5),
      "move picker did not enter Harness Folder"
    )
    let moveHere = app.buttons["files.move-here.410"]
    XCTAssertTrue(waitUntilHittable(moveHere, timeout: 5), "Move Here is not tappable")
    moveHere.tap()

    XCTAssertTrue(
      app.staticTexts["Item moved"].waitForExistence(timeout: 5),
      "move success was not surfaced"
    )
    XCTAssertTrue(
      renamedFolder.waitForNonExistence(timeout: 5),
      "moved folder remained in its source list"
    )

    let harnessFolder = element(identifier: "files.item.410")
    XCTAssertTrue(waitUntilHittable(harnessFolder, timeout: 5))
    harnessFolder.tap()
    XCTAssertTrue(
      element(identifier: "files.screen.410").waitForExistence(timeout: 5),
      "Harness Folder did not open after the move"
    )
    let movedFolder = element(identifier: "files.item.415")
    XCTAssertTrue(
      movedFolder.waitForExistence(timeout: 5),
      "moved folder is missing at destination"
    )
    XCTAssertEqual(movedFolder.label, "Weekend")

    openContextMenu(for: movedFolder, actionLabel: "Move").tap()
    XCTAssertTrue(
      element(identifier: "files.move-screen.0").waitForExistence(timeout: 5),
      "move picker did not reopen at Files"
    )
    let moveBackToRoot = app.buttons["files.move-here.0"]
    XCTAssertTrue(waitUntilHittable(moveBackToRoot, timeout: 5), "moving back to Files is disabled")
    moveBackToRoot.tap()
    XCTAssertTrue(
      app.staticTexts["Weekend to Files"].waitForExistence(timeout: 5),
      "move back to Files did not settle"
    )

    let backToFiles = app.navigationBars["Harness Folder"].buttons["Files"]
    XCTAssertTrue(waitUntilHittable(backToFiles, timeout: 5), "Files back button is unavailable")
    backToFiles.tap()
    XCTAssertTrue(
      element(identifier: "files.screen.0").waitForExistence(timeout: 5),
      "Files did not reappear after moving to the ancestor"
    )
    let movedFolderAtRoot = element(identifier: "files.item.415")
    XCTAssertTrue(
      waitUntilHittable(movedFolderAtRoot, timeout: 5),
      "ancestor Files list did not refresh after the move"
    )
    XCTAssertEqual(movedFolderAtRoot.label, "Weekend")

    let delete = openContextMenu(
      for: movedFolderAtRoot,
      actionLabel: "Trash"
    )
    delete.tap()
    let confirmDelete = app.buttons["files.delete-confirm"].firstMatch
    XCTAssertTrue(confirmDelete.waitForExistence(timeout: 5), "Trash confirmation never appeared")
    XCTAssertEqual(confirmDelete.label, "Trash")
    XCTAssertTrue(app.staticTexts["You can restore this item from Trash."].exists)
    confirmDelete.tap()
    XCTAssertTrue(
      app.staticTexts["Moved to Trash"].waitForExistence(timeout: 5),
      "Trash success was not surfaced"
    )
    XCTAssertTrue(
      movedFolderAtRoot.waitForNonExistence(timeout: 5), "trashed folder remained visible")

    let bulkRetryFolder = createFolder(named: "Bulk Retry", expectedID: 416)
    let bulkSuccessFolder = createFolder(named: "Bulk Success", expectedID: 417)
    let edit = app.buttons["files.selection.toggle"]
    XCTAssertTrue(waitUntilHittable(edit, timeout: 5), "file selection control is unavailable")
    edit.tap()
    XCTAssertTrue(
      app.buttons["files.bulk.move"].waitForExistence(timeout: 5),
      "bulk toolbar did not appear in edit mode"
    )
    XCTAssertEqual(element(identifier: "files.item.413").value as? String, "Not selected")
    let bulkMove = app.buttons["files.bulk.move"]
    XCTAssertFalse(bulkMove.isEnabled)
    let selectAll = app.buttons["files.selection.select-all"]
    XCTAssertTrue(
      waitUntilHittable(selectAll, timeout: 5),
      "select-all action is not hittable: \(selectAll.debugDescription)"
    )
    selectAll.tap()
    XCTAssertEqual(bulkRetryFolder.value as? String, "Selected")
    XCTAssertEqual(bulkSuccessFolder.value as? String, "Selected")
    XCTAssertTrue(bulkMove.isEnabled)
    let deselectAll = app.buttons["files.selection.deselect-all"]
    XCTAssertTrue(waitUntilHittable(deselectAll, timeout: 5))
    deselectAll.tap()
    XCTAssertEqual(bulkRetryFolder.value as? String, "Not selected")
    XCTAssertEqual(bulkSuccessFolder.value as? String, "Not selected")
    XCTAssertFalse(bulkMove.isEnabled)

    bulkRetryFolder.tap()
    XCTAssertEqual(bulkRetryFolder.value as? String, "Selected")
    bulkRetryFolder.tap()
    XCTAssertEqual(bulkRetryFolder.value as? String, "Not selected")
    bulkRetryFolder.tap()
    bulkSuccessFolder.tap()
    XCTAssertEqual(bulkRetryFolder.value as? String, "Selected")
    XCTAssertEqual(bulkSuccessFolder.value as? String, "Selected")

    XCTAssertTrue(bulkMove.isEnabled, "bulk Move did not enable for the selected rows")
    XCTAssertTrue(waitUntilHittable(bulkMove, timeout: 5), "bulk Move is disabled")
    bulkMove.tap()
    let bulkDestination = element(identifier: "files.move-folder.410")
    XCTAssertTrue(
      waitUntilHittable(bulkDestination, timeout: 5),
      "Harness Folder is unavailable for the bulk move"
    )
    bulkDestination.tap()
    let bulkMoveHere = app.buttons["files.move-here.410"]
    XCTAssertTrue(waitUntilHittable(bulkMoveHere, timeout: 5), "bulk Move Here is disabled")
    bulkMoveHere.tap()
    XCTAssertTrue(
      app.staticTexts["Moved 2 items."].waitForExistence(timeout: 10),
      "bulk move did not settle"
    )

    let harnessFolderAfterBulkMove = element(identifier: "files.item.410")
    XCTAssertTrue(waitUntilHittable(harnessFolderAfterBulkMove, timeout: 5))
    harnessFolderAfterBulkMove.tap()
    XCTAssertTrue(
      element(identifier: "files.screen.410").waitForExistence(timeout: 5),
      "Harness Folder did not open for bulk removal"
    )
    let movedBulkRetryFolder = element(identifier: "files.item.416")
    let movedBulkSuccessFolder = element(identifier: "files.item.417")
    XCTAssertTrue(waitUntilHittable(movedBulkRetryFolder, timeout: 5))
    XCTAssertTrue(waitUntilHittable(movedBulkSuccessFolder, timeout: 5))

    let nestedEdit = app.buttons["files.selection.toggle"]
    XCTAssertTrue(waitUntilHittable(nestedEdit, timeout: 5))
    nestedEdit.tap()
    XCTAssertTrue(
      app.buttons["files.bulk.remove"].waitForExistence(timeout: 5),
      "nested bulk toolbar did not appear in edit mode"
    )
    movedBulkRetryFolder.tap()
    movedBulkSuccessFolder.tap()
    XCTAssertEqual(movedBulkRetryFolder.value as? String, "Selected")
    XCTAssertEqual(movedBulkSuccessFolder.value as? String, "Selected")
    let bulkRemove = app.buttons["files.bulk.remove"]
    XCTAssertTrue(
      waitUntilHittable(bulkRemove, timeout: 5),
      "bulk Trash is not hittable: \(bulkRemove.debugDescription)"
    )
    XCTAssertEqual(bulkRemove.label, "Trash")
    bulkRemove.tap()
    XCTAssertTrue(app.staticTexts["Move 2 items to Trash?"].waitForExistence(timeout: 5))
    XCTAssertTrue(app.staticTexts["You can restore these items from Trash."].exists)
    let confirmBulkRemove = app.buttons["files.bulk.remove-confirm"].firstMatch
    XCTAssertTrue(waitUntilHittable(confirmBulkRemove, timeout: 5))
    confirmBulkRemove.tap()
    let bulkProgress = element(identifier: "files.bulk.progress")
    XCTAssertTrue(bulkProgress.waitForExistence(timeout: 5))
    XCTAssertFalse(app.buttons["BackButton"].isHittable, "back remained active during bulk work")
    XCTAssertFalse(app.buttons["Account"].isHittable, "tab remained active during bulk work")
    assertBulkProgressAdvances(bulkProgress, itemNames: ["Bulk Retry", "Bulk Success"])
    let survivingRow = element(identifier: "files.item.411")
    XCTAssertEqual(survivingRow.value as? String, "Not selected")
    survivingRow.tap()
    XCTAssertEqual(survivingRow.value as? String, "Not selected")
    XCTAssertFalse(app.buttons["files.selection.select-all"].isEnabled)
    app.swipeRight()
    XCTAssertTrue(
      element(identifier: "files.screen.410").exists,
      "edge swipe replaced the route during bulk work"
    )

    XCTAssertTrue(
      app.staticTexts["Some items couldn’t be moved to Trash"].waitForExistence(timeout: 10),
      "partial bulk-Trash failure was not surfaced"
    )
    XCTAssertTrue(
      app.staticTexts["Moved 1 item to Trash. 1 couldn’t be moved to Trash."].exists
    )
    addScreenshot(named: "runtime-file-actions")
    XCTAssertTrue(movedBulkRetryFolder.exists, "failed bulk item was not restored")
    XCTAssertFalse(movedBulkSuccessFolder.exists, "successful bulk item was restored")
    let retryBulkRemove = app.buttons["files.bulk.retry"].firstMatch
    XCTAssertTrue(waitUntilHittable(retryBulkRemove, timeout: 5), "bulk retry is unavailable")
    retryBulkRemove.tap()
    XCTAssertTrue(
      app.staticTexts["Moved 1 item to Trash."].waitForExistence(timeout: 10),
      "failed bulk item did not succeed on retry"
    )
    XCTAssertTrue(
      movedBulkRetryFolder.waitForNonExistence(timeout: 5),
      "retried bulk item remained visible"
    )

    let ambiguousMoveFolder = createFolder(named: "Ambiguous Move", expectedID: 418)
    let ambiguousEdit = app.buttons["files.selection.toggle"]
    XCTAssertTrue(waitUntilHittable(ambiguousEdit, timeout: 5))
    ambiguousEdit.tap()
    ambiguousMoveFolder.tap()
    XCTAssertEqual(ambiguousMoveFolder.value as? String, "Selected")
    let ambiguousBulkMove = app.buttons["files.bulk.move"]
    XCTAssertTrue(waitUntilHittable(ambiguousBulkMove, timeout: 5))
    ambiguousBulkMove.tap()
    let moveAmbiguousToRoot = app.buttons["files.move-here.0"]
    XCTAssertTrue(waitUntilHittable(moveAmbiguousToRoot, timeout: 5))
    moveAmbiguousToRoot.tap()

    XCTAssertTrue(
      app.staticTexts["Could not move items"].waitForExistence(timeout: 10),
      "ambiguous bulk-move failure was not surfaced"
    )
    XCTAssertTrue(
      ambiguousMoveFolder.waitForNonExistence(timeout: 5),
      "authoritative source refresh did not remove the applied move"
    )
    let dismissAmbiguousMove = app.buttons["files.bulk.dismiss"].firstMatch
    XCTAssertTrue(waitUntilHittable(dismissAmbiguousMove, timeout: 5))
    dismissAmbiguousMove.tap()
    XCTAssertTrue(waitUntilHittable(ambiguousEdit, timeout: 5))
    ambiguousEdit.tap()

    let backToRefreshedRoot = app.navigationBars["Harness Folder"].buttons["Files"]
    XCTAssertTrue(waitUntilHittable(backToRefreshedRoot, timeout: 5))
    backToRefreshedRoot.tap()
    XCTAssertTrue(element(identifier: "files.screen.0").waitForExistence(timeout: 5))
    let appliedMoveAtRoot = element(identifier: "files.item.418")
    XCTAssertTrue(
      waitUntilHittable(appliedMoveAtRoot, timeout: 5),
      "already-loaded destination did not refresh after the ambiguous move"
    )
    XCTAssertEqual(appliedMoveAtRoot.label, "Ambiguous Move")

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

  private func assertCurrentBulkProgress(_ progress: XCUIElement, itemNames: Set<String>) {
    let completedCount: Int
    switch progress.label {
    case "Moving item 1 of 2 to Trash…":
      completedCount = 0
    case "Moving item 2 of 2 to Trash…":
      completedCount = 1
    default:
      return XCTFail("unexpected bulk progress label: \(progress.label)")
    }
    let value = progress.value as? String
    XCTAssertTrue(
      itemNames.contains { value == "\($0). \(completedCount) of 2 complete." },
      "unexpected bulk progress value: \(value ?? "nil")"
    )
  }

  private func assertBulkProgressAdvances(_ progress: XCUIElement, itemNames: [String]) {
    for (index, itemName) in itemNames.enumerated() {
      let label = "Moving item \(index + 1) of \(itemNames.count) to Trash…"
      let value = "\(itemName). \(index) of \(itemNames.count) complete."
      let expectation = XCTNSPredicateExpectation(
        predicate: NSPredicate(format: "label == %@ AND value == %@", label, value),
        object: progress
      )
      XCTAssertEqual(
        XCTWaiter.wait(for: [expectation], timeout: 10),
        .completed,
        "bulk progress did not reach \(label) for \(itemName)"
      )
    }
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

  @discardableResult
  private func tapUnsupportedFileBeforeEditing() -> XCUIElement {
    // The unsupported row intentionally has no actionable container outside Edit mode.
    let unsupportedFile = app.staticTexts["Document.pdf"]
    XCTAssertTrue(unsupportedFile.exists && unsupportedFile.isHittable)
    unsupportedFile.tap()
    return unsupportedFile
  }

  private func createFolder(named name: String, expectedID: Int) -> XCUIElement {
    let newFolder = app.buttons["files.new-folder"]
    XCTAssertTrue(waitUntilHittable(newFolder, timeout: 5), "new-folder action is unavailable")
    newFolder.tap()
    let field = element(identifier: "files.action-name")
    XCTAssertTrue(field.waitForExistence(timeout: 5), "new-folder field did not appear")
    field.tap()
    field.typeText(name)
    let create = app.buttons["Create"]
    XCTAssertTrue(waitUntilHittable(create, timeout: 5), "create-folder action is unavailable")
    create.tap()
    let folder = element(identifier: "files.item.\(expectedID)")
    XCTAssertTrue(
      folder.waitForExistence(timeout: 5), "created folder \(expectedID) did not appear")
    XCTAssertEqual(folder.label, name)
    return folder
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
