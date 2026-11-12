import XCTest

final class BoardCaptureTests: XCTestCase {
  private var app: XCUIApplication!

  override func setUpWithError() throws {
    try super.setUpWithError()
    continueAfterFailure = false
    app = XCUIApplication()
    app.launchArguments = ["--putio-harness-scenario", "files-browser"]
    app.launchEnvironment["PUTIO_HARNESS_MEDIA_BASE_URL"] = try XCTUnwrap(
      ProcessInfo.processInfo.environment["PUTIO_HARNESS_MEDIA_BASE_URL"]
    )
  }

  override func tearDown() {
    orient(.portrait)
    super.tearDown()
  }

  func testFolder() throws {
    orient(.portrait)
    app.launch()
    openSeasonFolder()
    try captureBoard("rd-ios-02-folder")
  }

  func testEmptyFolder() throws {
    orient(.portrait)
    app.launchArguments.append("--putio-harness-folder-states")
    app.launch()
    openRoot()
    let folder = element("files.item.423")
    XCTAssertTrue(folder.appears(within: 10), "the empty folder never appeared")
    folder.tap()
    XCTAssertTrue(
      app.staticTexts["No files whatsoever!"].appears(within: 10), "the folder never said empty")
    XCTAssertTrue(app.buttons["Create folder"].exists, "the empty folder offers no Create folder")
    try captureBoard("rd-ios-08-empty")
  }

  func testFolderLoading() throws {
    orient(.portrait)
    app.launchArguments.append("--putio-harness-hold-season-listing")
    app.launch()
    openRoot()
    let harnessFolder = element("files.item.410")
    XCTAssertTrue(harnessFolder.appears(within: 10), "seeded folder row never appeared")
    harnessFolder.tap()
    let spinner = labeled("Loading files")
    let season = app.navigationBars["Blue Lights"]
    let harnessScreen = element("files.screen.410")
    let deadline = Date.now.addingTimeInterval(10)
    while !(season.exists && spinner.exists), !harnessScreen.exists, Date.now < deadline {
      _ = season.appears(within: 0.5)
    }
    if !season.exists {
      XCTAssertTrue(harnessScreen.appears(within: 5), "folder did not open")
      let folder = app.revealed("files.item.440")
      XCTAssertTrue(folder.appears(within: 10), "seeded season folder never appeared")
      folder.tap()
    }
    XCTAssertTrue(spinner.appears(within: 5), "the folder shows no loading spinner")
    XCTAssertTrue(season.exists, "the loading folder has no title")
    try captureBoard("rd-ios-40-loading")
  }

  func testFolderLoadingMore() throws {
    orient(.portrait)
    app.launchArguments.append("--putio-harness-season-more-held")
    app.launch()
    openSeasonFolder()
    XCTAssertTrue(
      labeled("Loading more files").appears(within: 5), "the next page shows no spinner")
    try captureBoard("rd-ios-41-loading-more")
  }

  func testFolderLoadMoreFailed() throws {
    orient(.portrait)
    app.launchArguments.append("--putio-harness-season-more-fails")
    app.launch()
    openSeasonFolder()
    XCTAssertTrue(
      app.staticTexts["Couldn’t load more files."].appears(within: 5),
      "the failed next page never said so")
    XCTAssertTrue(element("files.more-retry.440").exists, "the failed next page has no Try again")
    XCTAssertTrue(element("files.item.441").exists, "loaded rows left with the failed page")
    try captureBoard("rd-ios-32-load-more-failed")
  }

  func testRowActions() throws {
    orient(.portrait)
    app.launch()
    openSeasonFolder()
    openItemMenu("files.item.442")
    try captureBoard("rd-ios-03-row-actions")
  }

  func testVLCMenu() throws {
    orient(.portrait)
    app.launchArguments.append("--putio-harness-vlc-installed")
    app.launch()
    openSeasonFolder()
    openItemMenu("files.item.442")
    XCTAssertTrue(app.buttons["Open in VLC"].exists, "the menu has no Open in VLC")
    try captureBoard("rd-ios-64-vlc-menu")
  }

  func testSwipeActions() throws {
    orient(.portrait)
    app.launch()
    openSeasonFolder()
    let row = element("files.item.442")
    XCTAssertTrue(row.appears(within: 5), "the watched episode never appeared")
    row.swipeLeft()
    XCTAssertTrue(app.buttons["Move to trash"].appears(within: 5), "the swipe showed no Trash")
    try captureBoard("rd-ios-11-swipe")
  }

  func testTrashed() throws {
    orient(.portrait)
    app.launch()
    openSeasonFolder()
    openItemMenu("files.item.443")
    app.buttons["Move to trash"].firstMatch.tap()
    XCTAssertTrue(app.buttons["Undo"].appears(within: 5), "the trashed toast offers no Undo")
    XCTAssertTrue(element("files.item.443").disappears(within: 5), "the trashed row stayed")
    try captureBoard("rd-ios-10-trashed")
  }

  func testDeletePermanently() throws {
    orient(.portrait)
    app.launchArguments.append("--putio-harness-trash-disabled")
    app.launch()
    openSeasonFolder()
    openItemMenu("files.item.442")
    app.buttons["Delete permanently"].firstMatch.tap()
    XCTAssertTrue(
      app.alerts["Delete 1 item permanently?"].appears(within: 5), "the delete never asked")
    try captureBoard("rd-ios-22-delete-permanently")
  }

  func testTrashOffMenu() throws {
    orient(.portrait)
    app.launchArguments.append("--putio-harness-trash-disabled")
    app.launch()
    openSeasonFolder()
    openItemMenu("files.item.442")
    XCTAssertTrue(app.buttons["Delete permanently"].exists, "the menu does not delete for good")
    try captureBoard("rd-ios-51-trash-off-menu")
  }

  func testTrashUnknownMenu() throws {
    orient(.portrait)
    app.launchArguments.append("--putio-harness-unconfirmed-settings")
    app.launch()
    reachFilesRoot()
    let account = tabButton("Account")
    XCTAssertTrue(account.appears(within: 10), "the Account tab never appeared")
    account.tap()
    let subtitles = app.switches["playback-settings.subtitles"]
    app.bringIntoView(subtitles)
    XCTAssertTrue(subtitles.appears(within: 10), "Show subtitles never appeared")
    // Form exposes the full row as the switch accessibility frame.
    subtitles.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
    app.showTabBar()
    tabButton("Files").tap()
    openSeasonFolder()
    openItemMenu("files.item.442")
    let trash = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Move to trash"))
      .firstMatch
    XCTAssertTrue(trash.exists, "the menu has no Trash row")
    XCTAssertFalse(trash.isEnabled, "Trash is enabled before the setting is confirmed")
    try captureBoard("rd-ios-52-trash-unknown-menu")
  }

  func testTrashLimit() throws {
    orient(.portrait)
    app.launchArguments.append("--putio-harness-trash-limit")
    app.launch()
    reachFilesRoot()
    openItemMenu("files.item.410")
    app.buttons["Move to trash"].firstMatch.tap()
    XCTAssertTrue(
      app.alerts["We couldn’t send these files to trash"].appears(within: 10),
      "the refused Trash move never asked")
    try captureBoard("rd-ios-53-trash-limit")
  }

  func testFolderLongPress() throws {
    orient(.portrait)
    app.launch()
    reachFilesRoot()
    openItemMenu("files.item.410")
    try captureBoard("rd-ios-17-folder-long-press")
  }

  func testFileMenu() throws {
    orient(.portrait)
    app.launch()
    reachFilesRoot()
    XCTAssertTrue(app.revealed("files.item.407").exists, "the archive row never appeared")
    openItemMenu("files.item.407")
    try captureBoard("rd-ios-63-file-menu")
  }

  func testMove() throws {
    orient(.portrait)
    app.launch()
    openSeasonFolder()
    openMoveSheet(for: "files.item.445")
    try captureBoard("rd-ios-19-move")
  }

  func testMoveFolder() throws {
    orient(.portrait)
    app.launch()
    openSeasonFolder()
    openMoveSheet(for: "files.item.445")
    openMoveLevel(410)
    XCTAssertTrue(element("files.move-folder.440").appears(within: 10), "Blue Lights is not listed")
    try captureBoard("rd-ios-35-move-folder")
  }

  func testMoveLoading() throws {
    orient(.portrait)
    app.launchArguments.append("--putio-harness-hold-move-folders")
    app.launch()
    openSeasonFolder()
    openMoveSheet(for: "files.item.445")
    openMoveLevel(410)
    XCTAssertTrue(app.staticTexts["Loading folders…"].appears(within: 5), "no loading state")
    try captureBoard("rd-ios-36-move-loading")
  }

  func testMoveCurrentFolder() throws {
    orient(.portrait)
    app.launch()
    openSeasonFolder()
    openMoveSheet(for: "files.item.445")
    openMoveLevel(410)
    openMoveLevel(440)
    XCTAssertTrue(element("files.move-empty.440").appears(within: 10), "no empty state")
    XCTAssertFalse(app.buttons["Move to Blue Lights"].isEnabled, "the current folder is a target")
    try captureBoard("rd-ios-37-move-current-folder")
  }

  func testMoveNameTaken() throws {
    orient(.portrait)
    app.launch()
    openSeasonFolder()
    openMoveSheet(for: "files.item.445")
    openMoveLevel(410)
    XCTAssertTrue(element("files.move-folder.440").appears(within: 10), "Blue Lights is not listed")
    app.buttons["Move to Harness Folder"].tap()
    XCTAssertTrue(element("sheet.failure").appears(within: 10), "a taken name showed no error")
    try captureBoard("rd-ios-38-move-failed")
  }

  func testMoved() throws {
    orient(.portrait)
    app.launch()
    openSeasonFolder()
    openMoveSheet(for: "files.item.446")
    openMoveLevel(410)
    app.buttons["Move to Harness Folder"].tap()
    XCTAssertTrue(
      app.staticTexts["1 item is in the selected folder."].appears(within: 10), "no moved toast")
    XCTAssertTrue(element("files.item.446").disappears(within: 5), "the moved row stayed")
    try captureBoard("rd-ios-39-moved")
  }

  func testMoveIntoItself() throws {
    orient(.portrait)
    app.launch()
    openSeasonFolder()
    app.navigationBars.buttons["BackButton"].firstMatch.tap()
    XCTAssertTrue(element("files.screen.410").appears(within: 10), "Harness Folder never reopened")
    openMoveSheet(for: "files.item.440")
    openMoveLevel(410)
    openMoveLevel(440)
    XCTAssertTrue(element("sheet.failure").appears(within: 10), "into itself showed no error")
    try captureBoard("rd-ios-69-move-into-itself")
  }

  func testMoreMenu() throws {
    orient(.portrait)
    app.launch()
    reachFilesRoot()
    openMoreMenu()
    try captureBoard("rd-ios-05-more")
  }

  func testRename() throws {
    orient(.portrait)
    app.launch()
    openSeasonFolder()
    let alert = openRename()
    XCTAssertEqual(alert.textFields.firstMatch.value as? String, Self.subtitleName)
    XCTAssertFalse(
      alert.buttons["Rename"].firstMatch.isEnabled, "Rename is enabled for an unchanged name")
    try captureBoard("rd-ios-20-rename")
  }

  func testNewFolder() throws {
    orient(.portrait)
    app.launch()
    openSeasonFolder()
    openMoreMenu()
    app.buttons["New folder"].tap()
    let alert = app.alerts["New folder"]
    XCTAssertTrue(alert.appears(within: 5), "New folder never opened")
    XCTAssertTrue(alert.staticTexts["In Blue Lights"].exists, "New folder does not name its folder")
    XCTAssertFalse(
      alert.buttons["Create"].firstMatch.isEnabled, "Create is enabled for an empty name")
    XCTAssertTrue(app.keyboards.firstMatch.appears(within: 5), "the name field never took focus")
    app.typeText("Season 5")
    XCTAssertTrue(
      alert.buttons["Create"].firstMatch.isEnabled, "Create stayed disabled for a name")
    try captureBoard("rd-ios-21-new-folder")
  }

  func testRenameFailedToast() throws {
    orient(.portrait)
    app.launch()
    openSeasonFolder()
    let alert = openRename()
    app.typeText("Blue.Lights.S04E01.de")
    XCTAssertEqual(
      alert.textFields.firstMatch.value as? String, "Blue.Lights.S04E01.de.srt",
      "typing did not replace only the stem")
    alert.buttons["Rename"].firstMatch.tap()
    XCTAssertTrue(alert.disappears(within: 5), "the alert stayed open after Rename")
    XCTAssertTrue(app.staticTexts["Couldn’t rename."].appears(within: 10), "no failure toast")
    XCTAssertTrue(app.buttons["Try again"].exists, "the failure toast offers no Try again")
    XCTAssertTrue(
      element("files.item.445").label.hasPrefix(Self.subtitleName), "the failed rename stuck")
    try captureBoard("rd-ios-77-rename-failed-toast")
  }

  func testSortMenu() throws {
    XCUIDevice.shared.orientation = .portrait
    app.launch()
    reachFilesRoot()
    let sort = app.buttons["files.sort"]
    XCTAssertTrue(sort.appears(within: 5), "the folder has no sort button")
    sort.tap()
    XCTAssertTrue(app.staticTexts["Sort by"].appears(within: 5), "the sort menu did not open")
    XCTAssertTrue(app.staticTexts["Videos"].exists, "the sort menu has no Videos section")
    try captureBoard("rd-ios-04-sort")
  }

  func testSortingUpdate() throws {
    XCUIDevice.shared.orientation = .portrait
    app.launch()
    openSeasonFolder()
    let sort = app.buttons["files.sort"]
    XCTAssertTrue(sort.appears(within: 5), "the folder has no sort button")
    sort.tap()
    let sizeChoice = app.sortChoice("Size")
    XCTAssertTrue(sizeChoice.appears(within: 5), "the sort menu has no Size row")
    sizeChoice.tap()
    XCTAssertTrue(
      element("files.sorting.440").shows(within: 2), "the folder never said it was updating")
    try captureBoard("rd-ios-72-sorting")
  }

  func testIPadSplit() throws {
    orient(.landscapeLeft)
    app.launch()
    openHarnessFolder()
    try captureBoard("rd-ios-12-ipad-split")
  }

  func testFilesRoot() throws {
    orient(.portrait)
    app.launch()
    reachFilesRoot()
    try captureBoard("Main")
  }

  func testHistoryTabHidden() throws {
    orient(.portrait)
    app.launchArguments.append("--putio-harness-history-disabled")
    app.launch()
    reachFilesRoot()
    XCTAssertFalse(tabButton("History").exists, "disabled history remained in the tab bar")
    try captureBoard("rd-ios-hist-13-tab-hidden")
  }

  func testIPadSidebar() throws {
    orient(.landscapeLeft)
    app.launch()
    openHarnessFolder()
    let toggle = sidebarToggle()
    XCTAssertTrue(toggle.appears(within: 5), "the top tabs have no sidebar button")
    toggle.tap()
    XCTAssertTrue(element("shell.storage").appears(within: 5), "the sidebar has no storage meter")
    XCTAssertTrue(element("files.screen.410").exists, "opening the sidebar reset the Files path")
    try captureBoard("rd-ios-13-ipad-sidebar")
  }

  func testIPadPortrait() throws {
    orient(.landscapeLeft)
    app.launch()
    openSeasonFolder()
    let toggle = sidebarToggle()
    XCTAssertTrue(toggle.appears(within: 5), "the top tabs have no sidebar button")
    toggle.tap()
    XCTAssertTrue(element("shell.storage").appears(within: 5))
    sidebarToggle().tap()
    XCTAssertTrue(
      element("shell.storage").becomesUnhittable(within: 5), "the sidebar did not close")
    rotate(.portrait)
    XCTAssertTrue(
      element("files.screen.440").appears(within: 5), "rotating reset the Files path")
    try captureBoard("rd-ios-14-ipad-portrait")
  }

  func testListDetailNothingSelected() throws {
    orient(.landscapeLeft)
    launchListDetailGallery()
    XCTAssertTrue(
      app.staticTexts["No file selected"].appears(within: 5), "the empty detail has no title")
    XCTAssertTrue(app.staticTexts["Tap a file to see it here."].exists)
    XCTAssertFalse(listDetailRow(0).isSelected, "a row is open with nothing selected")
    try captureBoard("gallery-split-ipad-none")
  }

  func testListDetailKeepsSelectionAcrossRotation() throws {
    orient(.landscapeLeft)
    launchListDetailGallery()
    let row = listDetailRow(0)
    row.tap()
    assertListDetailOpen(row, "selecting a row")
    rotate(.portrait)
    assertListDetailOpen(row, "rotating to portrait")
    rotate(.landscapeLeft)
    assertListDetailOpen(row, "rotating back to landscape")
    XCTAssertFalse(listDetailRow(1).isSelected, "a second row opened")
    try captureBoard("gallery-split-ipad-detail")
  }

  func testWelcome() throws {
    launchSignedOut(welcomeFrame: 0)
    XCTAssertTrue(signInButton.appears(within: 15), "the welcome screen never appeared")
    try captureBoard("rd-ios-ses-01-welcome")
  }

  func testWelcomeSecondFrame() throws {
    launchSignedOut(welcomeFrame: 1)
    XCTAssertTrue(signInButton.appears(within: 15), "the welcome screen never appeared")
    let stage = element("welcome.stage").firstMatch
    XCTAssertTrue(stage.appears(within: 5), "the welcome stage probe is missing")
    XCTAssertEqual(
      stage.value as? String, "frame=1;rolling=false;dots=true", "the second frame is not shown")
    try captureBoard("rd-ios-ses-02-welcome-frame-2")
  }

  func testCheckingSession() throws {
    launchSignedOut(welcomeFrame: 0, extra: ["--putio-harness-sign-in-check-seconds", "600"])
    XCTAssertTrue(signInButton.appears(within: 15), "the welcome screen never appeared")
    signInButton.tap()
    XCTAssertTrue(
      app.buttons.matching(NSPredicate(format: "label == %@", "Checking your session"))
        .firstMatch.appears(within: 10),
      "the button never became busy")
    try captureBoard("rd-ios-ses-04-waiting")
  }

  func testSignInFailed() throws {
    launchSignedOut(welcomeFrame: nil, extra: ["--putio-harness-sign-in-fails-once"])
    XCTAssertTrue(signInButton.appears(within: 15), "the welcome screen never appeared")
    signInButton.tap()
    XCTAssertTrue(element("auth.notice").appears(within: 10), "the failed notice never appeared")
    try captureBoard("rd-ios-ses-05-failed")
  }

  func testSessionExpired() throws {
    launchSignedOut(welcomeFrame: 0, extra: ["--putio-harness-session-expires"])
    XCTAssertTrue(signInButton.appears(within: 15), "the welcome screen never appeared")
    signInButton.tap()
    XCTAssertTrue(
      app.staticTexts["Welcome back!"].appears(within: 15), "the session never expired")
    try captureBoard("rd-ios-ses-06-expired")
  }

  func testRestoring() throws {
    launchSavedCredential(extra: ["--putio-harness-restore-seconds", "600"])
    XCTAssertTrue(
      app.staticTexts["Restoring your session"].appears(within: 15), "restore showed no progress")
    try captureBoard("rd-ios-ses-13-restoring")
  }

  func testSessionCheckFailed() throws {
    launchSavedCredential(extra: ["--putio-harness-restore-offline-once"])
    XCTAssertTrue(element("auth.retry").appears(within: 15), "the session check never failed")
    try captureBoard("rd-ios-ses-14-check-failed")
  }

  func testSecureStorageUnavailable() throws {
    launchSavedCredential(extra: ["--putio-harness-credential-read-fails-once"])
    XCTAssertTrue(element("auth.retry").appears(within: 15), "the credential read never failed")
    try captureBoard("rd-ios-ses-07-storage")
  }

  func testSigningOut() throws {
    launchSignedOut(welcomeFrame: 0, extra: ["--putio-harness-sign-out-seconds", "600"])
    XCTAssertTrue(signInButton.appears(within: 15), "the welcome screen never appeared")
    signInButton.tap()
    XCTAssertTrue(element("files.screen.0").appears(within: 15), "sign-in never finished")
    let account = tabButton("Account")
    if !account.appears(within: 3) { sidebarToggle().tap() }
    XCTAssertTrue(account.appears(within: 5), "the Account tab is missing")
    account.tap()
    let signOut = app.revealed("auth.sign-out")
    XCTAssertTrue(signOut.appears(within: 5), "Account has no Sign out")
    signOut.tap()
    app.confirmSignOut()
    XCTAssertTrue(
      app.staticTexts["Signing out"].appears(within: 10), "sign-out showed no progress")
    try captureBoard("rd-ios-ses-15-signing-out")
  }

  func testSignOutWithDownloads() throws {
    orientForBoardDevice()
    app.launch()
    reachFilesRoot()
    downloadHarnessTrack()
    openSignOut()
    let remove = app.buttons["auth.sign-out-remove-downloads"].firstMatch
    let signIn = element("auth.sign-in")
    addTeardownBlock { @MainActor [remove, signIn] in
      guard remove.exists else { return }
      remove.tap()
      _ = signIn.appears(within: 15)
    }
    XCTAssertTrue(remove.appears(within: 5), "the dialog offers no download removal")
    XCTAssertTrue(
      app.buttons["auth.sign-out-confirm"].firstMatch.exists, "the dialog has no plain Sign out")
    try captureBoard("rd-ios-ses-08-sign-out")
    remove.tap()
    XCTAssertTrue(signIn.appears(within: 15), "sign-out never reached Welcome")
  }

  func testSignOutWithoutDownloads() throws {
    orientForBoardDevice()
    app.launch()
    reachFilesRoot()
    openSignOut()
    let alert = app.alerts["Sign out of put.io?"]
    XCTAssertTrue(alert.appears(within: 5), "sign-out with no downloads showed no alert")
    XCTAssertFalse(
      app.buttons["auth.sign-out-remove-downloads"].exists,
      "the alert offers download removal; a download outlived an earlier capture")
    XCTAssertTrue(alert.buttons["Cancel"].exists, "the alert has no Cancel")
    try captureBoard("rd-ios-ses-16-sign-out-no-downloads")
    alert.buttons["Cancel"].tap()
    XCTAssertTrue(alert.disappears(within: 5), "Cancel left the alert open")
  }

  func testPreviewLoading() throws {
    orient(.portrait)
    app.launchArguments.append("--putio-harness-previews")
    app.launch()
    openLongPreview()
    XCTAssertTrue(
      element("preview.loading").appears(within: 10), "the preview never showed loading")
    try captureBoard("rd-ios-pv-07-loading")
  }

  func testPreviewError() throws {
    orient(.portrait)
    app.launchArguments.append("--putio-harness-previews")
    app.launch()
    openLongPreview()
    XCTAssertTrue(
      element("preview.loading").appears(within: 10), "the preview never showed loading")
    app.buttons["preview.back"].tap()
    XCTAssertTrue(
      element("preview.screen.428").disappears(within: 5), "Back did not close the preview")
    openLongPreview()
    XCTAssertTrue(
      app.staticTexts["Couldn’t load this"].appears(within: 10),
      "the failed load has no error state")
    try captureBoard("rd-ios-pv-08-error")
  }

  func testPreviewCannotShow() throws {
    orient(.portrait)
    app.launchArguments.append("--putio-harness-previews")
    app.launch()
    reachFilesRoot()
    let row = app.revealed("files.item.429")
    XCTAssertTrue(row.exists, "the disk image row never appeared")
    row.tap()
    XCTAssertTrue(
      element("preview.cannot-show").appears(within: 10), "the disk image has no cannot-show state")
    try captureBoard("rd-ios-pv-05-unsupported")
  }

  func testPreviewImage() throws {
    orient(.portrait)
    openPosterPreview()
    try captureBoard("rd-ios-pv-01-image")
  }

  func testPreviewMoreMenu() throws {
    XCUIDevice.shared.orientation = .portrait
    openPosterPreview()
    openPreviewMore()
    try captureBoard("rd-ios-pv-02-more")
  }

  func testPreviewRename() throws {
    XCUIDevice.shared.orientation = .portrait
    openPosterPreview()
    openPreviewMore()
    app.buttons["Rename"].firstMatch.tap()
    let alert = app.alerts["Rename"]
    XCTAssertTrue(alert.appears(within: 5), "Rename never opened over the viewer")
    XCTAssertTrue(app.keyboards.firstMatch.appears(within: 5), "the name field never took focus")
    XCTAssertEqual(alert.textFields.firstMatch.value as? String, "Harness Poster.png")
    try captureBoard("rd-ios-pv-20-rename")
  }

  private func openPreviewMore() {
    let more = app.buttons["preview.more"]
    XCTAssertTrue(more.appears(within: 10), "the viewer has no More")
    more.tap()
    let rename = app.descendants(matching: .any)
      .matching(NSPredicate(format: "label == %@", "Rename")).firstMatch
    XCTAssertTrue(rename.appears(within: 15), "the viewer More never opened")
  }

  func testPreviewPosition() throws {
    orient(.portrait)
    app.launchArguments.append("--putio-harness-previews")
    app.launch()
    reachFilesRoot()
    let gallery = app.revealed("files.item.470", maximumSwipes: 8)
    XCTAssertTrue(gallery.exists, "the gallery folder never appeared")
    gallery.tap()
    let first = element("files.item.471")
    XCTAssertTrue(first.appears(within: 10), "the gallery never loaded")
    first.tap()
    let position = element("preview.position")
    XCTAssertTrue(position.appears(within: 10), "the gallery image shows no position")
    for _ in 0..<2 { app.swipeLeft() }
    let deadline = Date.now.addingTimeInterval(10)
    while position.label != "3 of 4", Date.now < deadline {
      RunLoop.current.run(until: Date.now.addingTimeInterval(0.1))
    }
    XCTAssertEqual(position.label, "3 of 4", "the preview did not page to the third image")
    XCTAssertTrue(
      app.images["Gallery 3.png"].appears(within: 10), "the third image did not settle")
    try captureBoard("rd-ios-pv-09-position")
  }

  func testPreviewLandscapeImage() throws {
    orient(.portrait)
    openPosterPreview()
    orient(.landscapeLeft)
    let window = app.windows.firstMatch
    let deadline = Date.now.addingTimeInterval(10)
    while window.frame.width < window.frame.height, Date.now < deadline {
      RunLoop.current.run(until: Date.now.addingTimeInterval(0.1))
    }
    XCTAssertGreaterThan(window.frame.width, window.frame.height, "the viewer did not rotate")
    XCTAssertTrue(
      app.images["Harness Poster.png"].appears(within: 5), "the image did not settle")
    try captureBoard("rd-ios-pv-13-landscape-image")
  }

  func testPreviewDocument() throws {
    orient(.portrait)
    app.launchArguments.append("--putio-harness-previews")
    app.launch()
    reachFilesRoot()
    let row = app.revealed("files.item.413")
    XCTAssertTrue(row.exists, "the document row never appeared")
    row.tap()
    XCTAssertTrue(
      app.staticTexts["put.io harness page 1"].appears(within: 10), "the document never loaded")
    let pill = element("preview.page")
    XCTAssertTrue(pill.appears(within: 5), "the document has no page pill")
    let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.6))
    let end = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.45))
    var drags = 0
    while pill.label != "Page 2 of 12", drags < 12 {
      start.press(forDuration: 0.05, thenDragTo: end)
      drags += 1
    }
    XCTAssertEqual(pill.label, "Page 2 of 12", "the document did not reach page 2")
    try captureBoard("rd-ios-pv-03-pdf")
  }

  func testPreviewText() throws {
    orient(.portrait)
    app.launchArguments.append("--putio-harness-previews")
    app.launch()
    openSeasonFolder()
    let row = app.revealed("files.item.445")
    XCTAssertTrue(row.exists, "the subtitle row never appeared")
    row.tap()
    XCTAssertTrue(element("preview.text").appears(within: 10), "the subtitle never loaded")
    try captureBoard("rd-ios-pv-04-text")
  }

  func testPreviewTextTruncated() throws {
    orient(.portrait)
    app.launchArguments.append("--putio-harness-previews")
    app.launch()
    reachFilesRoot()
    let row = app.revealed("files.item.432", maximumSwipes: 6)
    XCTAssertTrue(row.exists, "the long text row never appeared")
    row.tap()
    let text = element("preview.text")
    XCTAssertTrue(text.appears(within: 10), "the long text never loaded")
    let notice = element("preview.text.truncated")
    text.scrollTextToEnd(revealing: notice)
    XCTAssertTrue(notice.isOnScreen, "scrolling never reached the end line")
    XCTAssertTrue(notice.appears(within: 5))
    try captureBoard("rd-ios-pv-10-text-truncated")
    guard UIDevice.current.userInterfaceIdiom == .pad else { return }
    for control in [app.buttons["preview.text.share"], app.buttons["preview.share"]] {
      let name = control.identifier.replacing(".", with: "-")
      let sheet = app.openShareSheet(from: control, sharing: "Blue.Lights.S04.en.srt")
      let anchored = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
      anchored.name = "share-anchor-\(name)"
      anchored.lifetime = .keepAlways
      add(anchored)
      app.dismissShareSheet(sheet)
    }
  }

  private func openPosterPreview() {
    app.launchArguments.append("--putio-harness-previews")
    app.launch()
    reachFilesRoot()
    let row = app.revealed("files.item.406")
    XCTAssertTrue(row.exists, "the image row never appeared")
    row.tap()
    XCTAssertTrue(element("preview.image").appears(within: 10), "the image never loaded")
    XCTAssertTrue(
      app.images["Harness Poster.png"].appears(within: 5), "the image did not settle")
  }

  func testInactiveNotice() throws {
    orient(.portrait)
    try launchInactiveAccount()
    try captureBoard("rd-ios-ses-19-inactive")
  }

  func testIPadInactiveNotice() throws {
    orient(.landscapeLeft)
    try launchInactiveAccount()
    try captureBoard("rd-ios-ses-26-ipad-inactive")
  }

  private func launchInactiveAccount() throws {
    let account = try XCTUnwrap(ProcessInfo.processInfo.environment["PUTIO_INACTIVE_ACCOUNT"])
    app.launchArguments += ["--putio-harness-account-inactive", account]
    app.launch()
    reachFilesRoot()
    XCTAssertTrue(
      element("account.inactive-notice").appears(within: 10), "the \(account) notice never showed")
  }

  private func openLongPreview() {
    reachFilesRoot()
    let row = element("files.item.428")
    XCTAssertTrue(row.appears(within: 10), "the long-named image row never appeared")
    row.tap()
    XCTAssertTrue(
      element("preview.screen.428").appears(within: 10), "the preview did not open")
  }

  func testAccountTop() throws {
    openAccount()
    try captureBoard("rd-ios-acc-02-account")
  }

  func testAccountPlayback() throws {
    openAccount()
    scrollAccount(untilNearTop: "playback-settings.resume")
    try captureBoard("rd-ios-acc-03-account-middle")
  }

  func testAccountSecurity() throws {
    openAccount()
    scrollAccount(untilNearTop: "playback-settings.subtitles")
    try captureBoard("rd-ios-acc-22-account-security")
  }

  func testAccountEnd() throws {
    openAccount()
    let destroy = element("account.destroy-account")
    var swipes = 0
    while !(destroy.exists && destroy.isHittable), swipes < 8 {
      app.swipeUp()
      swipes += 1
    }
    XCTAssertTrue(destroy.appears(within: 5))
    XCTAssertTrue(destroy.isHittable, "the end of Account never scrolled into view")
    try captureBoard("rd-ios-acc-04-account-end")
  }

  func testAccountDownloads() throws {
    orient(.portrait)
    app.launch()
    reachFilesRoot()
    downloadHarnessTrack()
    XCTAssertFalse(element("downloads.concurrency").exists, "Downloads still sets the limit")
    let header = element("downloads.storage-used")
    XCTAssertTrue(header.appears(within: 5), "Downloads has no storage header")
    let downloaded = try XCTUnwrap(
      Self.byteSize(in: [header.label, header.value as? String ?? ""]),
      "the Downloads header shows no size")
    tabButton("Account").tap()
    let row = app.revealed("account.downloads")
    XCTAssertTrue(row.appears(within: 5), "Account has no Downloads row")
    XCTAssertEqual(Self.byteSize(in: [row.label, row.value as? String ?? ""]), downloaded)
    row.tap()
    let limit = element("downloads.concurrency")
    XCTAssertTrue(limit.appears(within: 5), "Account Downloads never opened")
    XCTAssertTrue(
      [limit.label, limit.value as? String ?? ""].contains { $0.hasSuffix("3") },
      "a fresh install does not allow 3 at a time")
    let stored = element("downloads.settings.stored")
    XCTAssertTrue(stored.appears(within: 5), "Account Downloads has no stored size")
    XCTAssertEqual(Self.byteSize(in: [stored.label, stored.value as? String ?? ""]), downloaded)
    try captureBoard("rd-ios-acc-01-downloads")
  }

  private static func byteSize(in texts: [String]) -> String? {
    let pattern = /[0-9][0-9.,]*\s?(?:bytes|B|KB|MB|GB|TB)/
    return texts.lazy.compactMap { $0.firstMatch(of: pattern).map { String($0.output) } }.first
  }

  func testAccountStorageFull() throws {
    app.launchArguments.append("--putio-harness-account-storage-full")
    openAccount()
    XCTAssertTrue(element("account.storage-full").appears(within: 5), "storage never read full")
    try captureBoard("rd-ios-acc-28-storage-full")
  }

  func testAccountInactive() throws {
    let account = try XCTUnwrap(ProcessInfo.processInfo.environment["PUTIO_INACTIVE_ACCOUNT"])
    app.launchArguments += ["--putio-harness-account-inactive", account]
    openAccount()
    XCTAssertTrue(
      element("account.status-notice").appears(within: 10), "Account has no \(account) notice")
    try captureBoard("rd-ios-acc-29-inactive")
  }

  func testAnalyticsPrompt() throws {
    orient(.portrait)
    launchAnalyticsPrompt()
    try captureBoard("rd-ios-ses-10-analytics")
  }

  func testAnalyticsPromptSaving() throws {
    orient(.portrait)
    launchAnalyticsPrompt()
    let allow = app.buttons["analytics-prompt.allow"]
    allow.tap()
    let saving = XCTNSPredicateExpectation(
      predicate: NSPredicate(format: "isEnabled == false"), object: allow)
    XCTAssertEqual(XCTWaiter.wait(for: [saving], timeout: 2), .completed, "Allow never started")
    try captureBoard("rd-ios-ses-17-analytics-saving")
  }

  func testAnalyticsPromptFailed() throws {
    orient(.portrait)
    launchAnalyticsPrompt()
    app.buttons["analytics-prompt.allow"].tap()
    XCTAssertTrue(
      element("analytics-prompt.failure").appears(within: 10), "the first save never failed")
    try captureBoard("rd-ios-ses-18-analytics-failed")
  }

  func testIPadAnalyticsPrompt() throws {
    orient(.landscapeLeft)
    launchAnalyticsPrompt()
    try captureBoard("rd-ios-ses-25-ipad-analytics")
  }

  func testAccountSettingsLoading() throws {
    app.launchArguments += ["--putio-harness-account-settings", "slow-load"]
    openAccount()
    XCTAssertTrue(element("account.settings-loading").appears(within: 5), "settings never loaded")
    try captureBoard("rd-ios-acc-26-settings-loading")
  }

  func testAccountSettingsFailed() throws {
    app.launchArguments += ["--putio-harness-account-settings", "fail-load"]
    openAccount()
    XCTAssertTrue(element("account.settings-failed").appears(within: 10), "settings never failed")
    try captureBoard("rd-ios-acc-27-settings-failed")
  }

  func testAccountSaveFailed() throws {
    app.launchArguments += ["--putio-harness-account-settings", "slow-load"]
    openAccount()
    XCTAssertTrue(element("settings.default-sort").appears(within: 15), "settings never loaded")
    scrollAccount(untilNearTop: "settings.default-sort")
    let autoplay = app.switches["playback-settings.autoplay"]
    XCTAssertTrue(autoplay.appears(within: 5))
    autoplay.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
    XCTAssertTrue(
      app.staticTexts["Couldn’t save this setting"].appears(within: 10), "no save failure toast")
    let reverted = XCTNSPredicateExpectation(
      predicate: NSPredicate(format: "value == %@ AND enabled == true", "0"), object: autoplay)
    XCTAssertEqual(XCTWaiter.wait(for: [reverted], timeout: 5), .completed)
    try captureBoard("rd-ios-acc-21-save-failed")
  }

  func testAccountDefaultSort() throws {
    openAccountSettings()
    element("settings.default-sort").tap()
    XCTAssertTrue(
      app.buttons["Size, smallest first"].firstMatch.appears(within: 5),
      "the sort menu never opened")
    try captureBoard("rd-ios-acc-05-default-sort")
  }

  func testAccountResetSort() throws {
    openAccountSettings()
    let reset = element("settings.reset-sort")
    app.bringIntoView(reset)
    reset.tap()
    XCTAssertTrue(
      app.alerts["Reset all folder sorts?"].appears(within: 5), "the reset alert never showed")
    try captureBoard("rd-ios-acc-23-reset-sort")
  }

  func testAccountTrashOff() throws {
    openAccountSettings()
    let trash = app.switches["settings.trash"]
    app.bringIntoView(trash)
    trash.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
    XCTAssertTrue(app.alerts["Turn off trash?"].appears(within: 5), "the trash alert never showed")
    try captureBoard("rd-ios-acc-24-trash-off")
  }

  func testAccountWithTrashOff() throws {
    app.launchArguments.append("--putio-harness-trash-disabled")
    openAccountSettings()
    XCTAssertFalse(element("account.trash").exists, "the Trash row shows with trash off")
    try captureBoard("rd-ios-acc-59-trash-off-account")
  }

  func testAccountResumeOff() throws {
    openAccountSettings()
    scrollAccount(untilNearTop: "playback-settings.resume")
    let resume = app.switches["playback-settings.resume"]
    XCTAssertTrue(resume.appears(within: 5))
    resume.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
    XCTAssertTrue(
      app.alerts["Turn off resume?"].appears(within: 5), "the resume alert never showed")
    try captureBoard("rd-ios-acc-60-resume-off-confirm")
  }

  func testAccountPlaybackMethod() throws {
    openAccountSettings()
    let method = app.revealed("playback-settings.method")
    XCTAssertTrue(method.appears(within: 5))
    method.tap()
    XCTAssertTrue(
      app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Direct play")).firstMatch
        .appears(within: 5), "the playback method screen never opened")
    try captureBoard("rd-ios-acc-06-playback-method")
  }

  func testAccountProxy() throws {
    app.launchArguments += ["--putio-harness-proxy", "ready"]
    openProxy()
    XCTAssertTrue(proxyChoice("Washington, D.C.").appears(within: 10), "proxies never loaded")
    try captureBoard("rd-ios-acc-07-proxy")
  }

  func testAccountProxyLoading() throws {
    app.launchArguments += ["--putio-harness-proxy", "slow"]
    openProxy()
    XCTAssertTrue(element("proxy.loading").appears(within: 5), "proxies never started loading")
    try captureBoard("rd-ios-acc-31-proxy-loading")
  }

  func testAccountProxyFailed() throws {
    openProxy()
    XCTAssertTrue(app.buttons["proxy.retry"].appears(within: 10), "proxies never failed")
    try captureBoard("rd-ios-acc-32-proxy-failed")
  }

  func testAccountProxyUnavailable() throws {
    app.launchArguments += ["--putio-harness-proxy", "refused"]
    openProxy()
    let london = proxyChoice("London")
    XCTAssertTrue(london.appears(within: 10), "proxies never loaded")
    london.tap()
    XCTAssertTrue(
      app.alerts["That proxy isn’t available for your account."].appears(within: 10),
      "the refused proxy showed no alert")
    try captureBoard("rd-ios-acc-33-proxy-unavailable")
  }

  private func openProxy() {
    openAccountSettings()
    let proxy = app.revealed("playback-settings.route")
    XCTAssertTrue(proxy.appears(within: 5))
    proxy.tap()
    XCTAssertTrue(
      app.navigationBars["Choose your proxy"].appears(within: 5), "the proxy screen never opened")
  }

  private func proxyChoice(_ title: String) -> XCUIElement {
    app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", title)).firstMatch
  }

  private func openAccountSettings() {
    openAccount()
    XCTAssertTrue(
      element("settings.default-sort").appears(within: 15), "account settings never loaded")
  }

  func testGalleryPage() throws {
    let environment = ProcessInfo.processInfo.environment
    let board = try XCTUnwrap(environment["PUTIO_BOARD_ID"])
    let page = try XCTUnwrap(environment["PUTIO_GALLERY_PAGE"])
    orient(.portrait)
    app.launchArguments = [
      "--putio-harness-scenario", "gallery", "--putio-harness-gallery-page", page,
    ]
    app.launch()
    XCTAssertTrue(app.staticTexts.firstMatch.appears(within: 15), "gallery page never rendered")
    try captureBoard(board)
  }

  private func launchAnalyticsPrompt() {
    app.launchArguments += [
      "--putio-harness-analytics-prompt", "--putio-harness-file-preferences",
      "--putio-harness-reset-file-preferences",
    ]
    app.launch()
    let prompt = element("analytics-prompt")
    let signIn = element("auth.sign-in")
    let deadline = Date.now.addingTimeInterval(15)
    while !prompt.exists, !signIn.exists, Date.now < deadline {
      _ = prompt.appears(within: 0.5)
    }
    if signIn.exists { signIn.tap() }
    XCTAssertTrue(prompt.appears(within: 15), "the analytics prompt never appeared")
    XCTAssertTrue(
      app.buttons["analytics-prompt.allow"].appears(within: 5), "the prompt has no Allow")
  }

  private var signInButton: XCUIElement { element("auth.sign-in").firstMatch }

  private func launchSignedOut(welcomeFrame: Int?, extra: [String] = []) {
    let isPad = ProcessInfo.processInfo.environment["PUTIO_BOARD_DEVICE"] == "ipad"
    orient(isPad ? .landscapeLeft : .portrait)
    app.launchArguments += ["--putio-harness-signed-out-at-launch"] + extra
    if let welcomeFrame {
      app.launchArguments += ["--putio-harness-welcome-frame", String(welcomeFrame)]
    }
    app.launch()
  }

  private func launchSavedCredential(extra: [String]) {
    let isPad = ProcessInfo.processInfo.environment["PUTIO_BOARD_DEVICE"] == "ipad"
    orient(isPad ? .landscapeLeft : .portrait)
    app.launchArguments += ["--putio-harness-saved-credential-at-launch"] + extra
    app.launch()
  }

  private static let listDetailFileName = "Blue.Lights.S04E01.1080p.HDTV.H264-ORGANiC.mkv"

  private func launchListDetailGallery() {
    app.launchArguments = [
      "--putio-harness-scenario", "gallery", "--putio-harness-gallery-page", "split",
    ]
    app.launch()
    XCTAssertTrue(listDetailRow(0).appears(within: 15), "the list and detail page never rendered")
  }

  private func listDetailRow(_ index: Int) -> XCUIElement {
    element("gallery.split.row.\(index)").firstMatch
  }

  private func assertListDetailOpen(_ row: XCUIElement, _ step: String) {
    let title = element("gallery.split.detail-title").firstMatch
    XCTAssertTrue(title.appears(within: 5), "no detail after \(step)")
    XCTAssertEqual(title.label, Self.listDetailFileName, "the detail changed after \(step)")
    XCTAssertTrue(row.appears(within: 5), "the list column is hidden after \(step)")
    XCTAssertTrue(row.isSelected, "the open row lost its selection after \(step)")
    XCTAssertFalse(app.staticTexts["No file selected"].exists, "the detail emptied after \(step)")
  }

  private func orientForBoardDevice() {
    let isPad = ProcessInfo.processInfo.environment["PUTIO_BOARD_DEVICE"] == "ipad"
    orient(isPad ? .landscapeLeft : .portrait)
  }

  private func downloadHarnessTrack() {
    openItemMenu("files.item.408")
    app.buttons["Download"].firstMatch.tap()
    tabButton("Downloads").tap()
    let item = element("downloads.item.408")
    XCTAssertTrue(item.appears(within: 10), "the harness track never queued")
    let completed = XCTNSPredicateExpectation(
      predicate: NSPredicate(format: "value == %@", "completed"), object: item)
    XCTAssertEqual(
      XCTWaiter.wait(for: [completed], timeout: 60), .completed,
      "the harness track never finished downloading")
  }

  private func openSignOut() {
    let account = tabButton("Account")
    if !account.appears(within: 3) { sidebarToggle().tap() }
    XCTAssertTrue(account.appears(within: 5), "the Account tab is missing")
    account.tap()
    let signOut = app.revealed("auth.sign-out")
    XCTAssertTrue(signOut.appears(within: 5), "Account has no Sign out")
    app.bringIntoView(signOut)
    XCTAssertTrue(signOut.becomesHittable(within: 5), "Sign out never became tappable")
    signOut.tap()
  }

  private func openAccount() {
    orient(.portrait)
    app.launch()
    reachFilesRoot()
    tabButton("Account").tap()
    XCTAssertTrue(element("account.profile").appears(within: 10), "Account never opened")
    XCTAssertTrue(element("account.storage-used").exists, "Account has no storage row")
  }

  private func scrollAccount(untilNearTop identifier: String) {
    let target = element(identifier)
    let window = app.windows.firstMatch.frame
    let ceiling = window.minY + window.height * 0.24
    var steps = 0
    while !(target.exists && target.frame.minY < ceiling), steps < 60 {
      let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.6))
      let end = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.52))
      start.press(forDuration: 0.05, thenDragTo: end, withVelocity: .slow, thenHoldForDuration: 0.3)
      steps += 1
    }
    XCTAssertTrue(target.exists, "\(identifier) never scrolled into view")
    XCTAssertLessThan(target.frame.minY, ceiling, "\(identifier) did not reach the top")
    XCTAssertTrue(target.appears(within: 5))
  }

  private func reachFilesRoot() {
    let root = element("files.screen.0")
    let folderScreens = ["files.screen.410", "files.screen.440", "files.screen.470"].map(element)
    let signIn = element("auth.sign-in")
    let deadline = Date.now.addingTimeInterval(15)
    while !root.exists, !signIn.exists, !folderScreens.contains(where: \.exists),
      Date.now < deadline
    {
      _ = root.appears(within: 0.5)
    }
    if signIn.exists { signIn.tap() }
    for _ in folderScreens where !root.isHittable && folderScreens.contains(where: \.exists) {
      app.navigationBars.buttons.firstMatch.tap()
      _ = root.appears(within: 2)
    }
    XCTAssertTrue(root.appears(within: 15), "seeded session never reached Files")
  }

  private func tabButton(_ label: String) -> XCUIElement {
    app.buttons.matching(NSPredicate(format: "label == %@", label)).firstMatch
  }

  private func sidebarToggle() -> XCUIElement {
    app.buttons.matching(NSPredicate(format: "label CONTAINS[c] %@", "sidebar")).firstMatch
  }

  private func openRoot() {
    let root = element("files.screen.0")
    let signIn = element("auth.sign-in")
    let back = app.navigationBars.buttons["BackButton"].firstMatch
    var settledSince: Date?
    let deadline = Date.now.addingTimeInterval(30)
    while Date.now < deadline {
      if signIn.exists {
        signIn.tap()
      } else if back.exists {
        back.tap()
      } else if root.exists {
        if Date.now.timeIntervalSince(settledSince ?? .now) >= 2 { break }
        settledSince = settledSince ?? .now
      } else {
        settledSince = nil
      }
      _ = root.appears(within: 0.5)
    }
    XCTAssertTrue(root.exists && !back.exists, "seeded session never reached Files")
  }

  private func labeled(_ label: String) -> XCUIElement {
    app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", label)).firstMatch
  }

  private func openHarnessFolder() {
    let root = element("files.screen.0")
    let folderScreen = element("files.screen.410")
    let signIn = element("auth.sign-in")
    let deadline = Date.now.addingTimeInterval(15)
    while !root.exists, !folderScreen.exists, !signIn.exists, Date.now < deadline {
      _ = root.appears(within: 0.5)
    }
    if signIn.exists { signIn.tap() }
    if !folderScreen.exists {
      XCTAssertTrue(root.appears(within: 15), "seeded session never reached Files")
      let folder = element("files.item.410")
      XCTAssertTrue(folder.appears(within: 10), "seeded folder row never appeared")
      folder.tap()
    }
    XCTAssertTrue(folderScreen.appears(within: 10), "folder did not open")
  }

  private func openSeasonFolder() {
    if !element("files.screen.440").appears(within: 5) {
      if !element("files.screen.410").exists { openHarnessFolder() }
      let folder = element("files.item.440")
      XCTAssertTrue(folder.appears(within: 10), "seeded season folder never appeared")
      folder.tap()
    }
    XCTAssertTrue(element("files.header.440").appears(within: 10), "season folder has no header")
  }

  private func openItemMenu(_ identifier: String) {
    let row = element(identifier)
    XCTAssertTrue(row.appears(within: 10), "\(identifier) never appeared")
    row.press(forDuration: 1)
    XCTAssertTrue(app.buttons["Rename"].appears(within: 5), "the item menu never opened")
  }

  private func openMoveSheet(for identifier: String) {
    openItemMenu(identifier)
    app.buttons["Move"].firstMatch.tap()
    XCTAssertTrue(element("files.move-screen.0").appears(within: 5), "Move never opened")
    XCTAssertTrue(element("files.move-folder.410").appears(within: 10), "Files lists no folders")
  }

  private func openMoveLevel(_ id: Int) {
    let row = element("files.move-folder.\(id)")
    XCTAssertTrue(row.appears(within: 10), "move folder \(id) never appeared")
    row.tap()
    XCTAssertTrue(element("files.move-screen.\(id)").appears(within: 5), "level \(id) never opened")
  }

  private static let subtitleName = "Blue.Lights.S04E01.en.srt"

  private func openMoreMenu() {
    let menu = app.buttons["files.menu"]
    XCTAssertTrue(menu.appears(within: 10), "the folder has no More menu")
    menu.tap()
    XCTAssertTrue(
      app.buttons["New folder"].appears(within: 5), "More never listed New folder")
  }

  private func openRename() -> XCUIElement {
    openItemMenu("files.item.445")
    app.buttons["Rename"].firstMatch.tap()
    let alert = app.alerts["Rename"]
    XCTAssertTrue(alert.appears(within: 5), "Rename never opened")
    XCTAssertTrue(app.keyboards.firstMatch.appears(within: 5), "the name field never took focus")
    return alert
  }

  private func captureBoard(_ defaultBoard: String) throws {
    let board = ProcessInfo.processInfo.environment["PUTIO_BOARD_ID"] ?? defaultBoard
    try requireBoardDevicePosture()
    if ProcessInfo.processInfo.environment["PUTIO_BOARD_TEXT_AUDIT"] == "1" {
      try app.performAccessibilityAudit(for: .textClipped) { issue in
        guard let element = issue.element else { return false }
        return Self.isMiddleTruncatedFileName(element.label)
          && element.frame.height >= Self.minimumXXLargeLineHeight
      }
    }
    let window = app.windows.firstMatch.frame
    let screen = Self.screenshot(showing: window.size)
    let capture = Self.oriented(screen, toMatch: window.size)
    let image = XCTAttachment(image: capture)
    image.name = board
    image.lifetime = .keepAlways
    add(image)

    let layout = try JSONSerialization.data(
      withJSONObject: [
        "width": Double(window.width),
        "height": Double(window.height),
        "scale": Double(capture.scale),
      ],
      options: [.sortedKeys])
    let data = XCTAttachment(data: layout, uniformTypeIdentifier: "public.json")
    data.name = "\(board)-layout"
    data.lifetime = .keepAlways
    add(data)
  }

  private func requireBoardDevicePosture() throws {
    let device = ProcessInfo.processInfo.environment["PUTIO_BOARD_DEVICE"]
    guard device == "duo-folded" || device == "duo-open" else { return }
    let window = app.windows.firstMatch
    XCTAssertTrue(window.appears(within: 10), "app window never appeared")
    if device == "duo-folded" {
      XCTAssertLessThan(
        window.frame.width, Self.regularWidthThreshold,
        "folded iPhone Duo window is \(window.frame.width) pt wide")
      return
    }
    XCTAssertEqual(
      window.frame.size, Self.openDuoSize,
      "open iPhone Duo window is \(window.frame.size) pt, not the book posture")
    XCTAssertEqual(
      window.horizontalSizeClass, .regular,
      "open iPhone Duo window is \(window.frame.size) pt with compact width")
    XCTAssertEqual(
      window.verticalSizeClass, .regular,
      "open iPhone Duo window is \(window.frame.size) pt with compact height")
  }

  private static let regularWidthThreshold: CGFloat = 600
  private static let openDuoSize = CGSize(width: 951, height: 669)

  private func orient(_ orientation: UIDeviceOrientation) {
    guard ProcessInfo.processInfo.environment["PUTIO_BOARD_DEVICE"] != "duo-open" else { return }
    XCUIDevice.shared.orientation = orientation
  }

  private func rotate(_ orientation: UIDeviceOrientation) {
    guard ProcessInfo.processInfo.environment["PUTIO_BOARD_DEVICE"] != "duo-open" else {
      XCTFail("this board rotates the device, and the open iPhone Duo is never rotated")
      return
    }
    XCUIDevice.shared.orientation = orientation
  }

  private static func screenshot(showing size: CGSize) -> UIImage {
    let main = XCUIScreen.main.screenshot().image
    guard !fits(main.size, size) else { return main }
    return XCUIScreen.screens.lazy.map { $0.screenshot().image }.first { fits($0.size, size) }
      ?? main
  }

  private static func fits(_ image: CGSize, _ window: CGSize) -> Bool {
    let sides = { (size: CGSize) in [size.width, size.height].sorted() }
    return zip(sides(image), sides(window)).allSatisfy { abs($0 - $1) < 1 }
  }

  private static func oriented(_ screen: UIImage, toMatch size: CGSize) -> UIImage {
    let upright = UIGraphicsImageRenderer(size: screen.size, format: rendererFormat(screen)).image {
      _ in screen.draw(in: CGRect(origin: .zero, size: screen.size))
    }
    return rotated(upright, toMatch: size)
  }

  private static func rendererFormat(_ image: UIImage) -> UIGraphicsImageRendererFormat {
    let format = UIGraphicsImageRendererFormat()
    format.scale = image.scale
    return format
  }

  private static func rotated(_ image: UIImage, toMatch size: CGSize) -> UIImage {
    let landscapeImage = image.size.width > image.size.height
    guard landscapeImage != (size.width > size.height) else { return image }
    let clockwise =
      XCUIDevice.shared.orientation == .landscapeRight
      || ProcessInfo.processInfo.environment["PUTIO_BOARD_DEVICE"] == "duo-open"
    let rotated = CGSize(width: image.size.height, height: image.size.width)
    return UIGraphicsImageRenderer(size: rotated, format: rendererFormat(image)).image {
      context in
      let cg = context.cgContext
      cg.translateBy(x: rotated.width / 2, y: rotated.height / 2)
      cg.rotate(by: clockwise ? .pi / 2 : -.pi / 2)
      image.draw(
        in: CGRect(
          x: -image.size.width / 2, y: -image.size.height / 2, width: image.size.width,
          height: image.size.height))
    }
  }

  private static let minimumXXLargeLineHeight: CGFloat = 24

  private static func isMiddleTruncatedFileName(_ label: String?) -> Bool {
    guard let label, let dot = label.lastIndex(of: "."), dot != label.startIndex else {
      return false
    }
    let fileExtension = label[label.index(after: dot)...]
    return (1...5).contains(fileExtension.count)
      && fileExtension.allSatisfy { $0.isLetter || $0.isNumber }
      && fileExtension.contains(where: \.isLetter)
  }

  private func element(_ identifier: String) -> XCUIElement {
    app.descendants(matching: .any)[identifier]
  }
}
