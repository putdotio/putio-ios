import XCTest

final class BoardCaptureTests: XCTestCase {
  private var app: XCUIApplication!
  private var movedHinge = false

  override func setUpWithError() throws {
    try super.setUpWithError()
    continueAfterFailure = false
    app = XCUIApplication()
    app.launchArguments = ["--putio-harness-scenario", "files-browser"]
    app.launchEnvironment["PUTIO_HARNESS_MEDIA_BASE_URL"] = try XCTUnwrap(
      ProcessInfo.processInfo.environment["PUTIO_HARNESS_MEDIA_BASE_URL"]
    )
    if ProcessInfo.processInfo.environment["PUTIO_BOARD_ORIENTATION"] != nil {
      orient(.portrait)
    }
  }

  override func tearDown() {
    orient(.portrait)
    restoreDuoPosture()
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

  func testFolderLoadFailed() throws {
    try captureFolderFailure(
      fault: "500", reason: "Check your connection and try again.", board: "rd-ios-09-error")
  }

  func testFolderNoAccess() throws {
    try captureFolderFailure(
      fault: "403", reason: "You don’t have access to this folder.",
      board: "rd-ios-44-no-access")
  }

  func testFolderRateLimited() throws {
    try captureFolderFailure(
      fault: "429", reason: "put.io is receiving too many requests. Try again shortly.",
      board: "rd-ios-74-rate-limited")
  }

  func testFolderUnavailable() throws {
    try captureFolderFailure(
      fault: "503", reason: "put.io is temporarily unavailable. Try again.",
      board: "rd-ios-75-unavailable")
  }

  func testFolderOffline() throws {
    orientForBoardDevice()
    app.launch()
    reachFilesRoot()
    downloadHarnessTrack()
    app.launchArguments += [
      "--putio-harness-folder-fault", "offline,offline,offline,offline,offline,offline@0",
    ]
    app.launch()
    let signIn = element("auth.sign-in")
    let remove = app.buttons["auth.sign-out-remove-downloads"].firstMatch
    addTeardownBlock { @MainActor [self] in
      if !signIn.exists {
        openSignOut()
        if remove.appears(within: 5) { remove.tap() }
      }
      _ = signIn.appears(within: 15)
    }
    if signIn.appears(within: 10) { signIn.tap() }
    let files = tabButton("Files")
    if files.appears(within: 5) { files.tap() }
    XCTAssertTrue(
      app.staticTexts["put.io is out of reach"].appears(within: 15), "Files never went offline")
    let device =
      ProcessInfo.processInfo.environment["PUTIO_BOARD_DEVICE"] == "ipad"
      ? "iPad" : "iPhone"
    XCTAssertTrue(
      app.staticTexts["Offline. Showing what’s on this \(device)."].exists,
      "the offline banner is missing")
    XCTAssertTrue(
      app.staticTexts["Your connection dropped, or we did. Retrying on its own."].exists,
      "the offline state does not say it retries")
    XCTAssertTrue(element("files.offline-item.408").exists, "the finished download is missing")
    try captureBoard("rd-ios-43-offline")
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

  func testPreviewVLCNotInstalled() throws {
    orient(.portrait)
    app.launchArguments.append("--putio-harness-vlc-removed")
    app.launch()
    openSeasonFolder()
    openItemMenu("files.item.441")
    app.buttons["Open in VLC"].firstMatch.tap()
    XCTAssertTrue(
      app.putioAlert("VLC is not installed").appears(within: 5), "a missing VLC raised no alert")
    try captureBoard("rd-ios-pv-06-vlc")
  }

  func testPreviewVLCFailedToast() throws {
    orient(.portrait)
    app.launchArguments += [
      "--putio-harness-vlc-installed", "--putio-harness-download-token-missing",
    ]
    app.launch()
    openSeasonFolder()
    openItemMenu("files.item.441")
    app.buttons["Open in VLC"].firstMatch.tap()
    XCTAssertTrue(
      app.staticTexts[
        "Couldn’t prepare “Blue.Lights.S04E01.1080p.HDTV.H264-ORGANiC.mkv” for VLC. "
          + "Sign in again."
      ].appears(within: 5), "the failed handoff showed no toast")
    try captureBoard("rd-ios-pv-21-vlc-failed-toast")
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

  func testSwipeLeading() throws {
    orient(.portrait)
    app.launch()
    openSeasonFolder()
    let row = element("files.item.444")
    XCTAssertTrue(row.appears(within: 5), "the fourth episode never appeared")
    row.swipeRight()
    let move = app.buttons["item-swipe.move"]
    XCTAssertTrue(move.appears(within: 5), "the right swipe showed no Move")
    try captureBoard("rd-ios-11-swipe-leading")
    move.tap()
    XCTAssertTrue(element("files.move-screen.0").appears(within: 5), "Move never opened")
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
      app.putioAlert("Delete 1 item permanently?").appears(within: 5), "the delete never asked")
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
      app.putioAlert("We couldn’t send these files to trash").appears(within: 10),
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

  func testPinned() throws {
    try reachPins("three")
    XCTAssertFalse(element("files.pinned.see-all").exists, "three pins offered See all")
    try captureBoard("rd-ios-18-pinned")
  }

  func testPinnedLongPress() throws {
    try reachPins("three")
    element("files.pinned.item.440").press(forDuration: 1)
    XCTAssertTrue(app.buttons["Unpin"].appears(within: 5), "the pin menu has no Unpin")
    XCTAssertTrue(app.buttons["Move"].exists, "the pin menu has no Move")
    XCTAssertTrue(app.buttons["Exclusive link"].exists, "the pin menu has no Exclusive link")
    try captureBoard("rd-ios-34-pinned-long-press")
  }

  func testPinnedSeeAll() throws {
    try reachPins("seven")
    XCTAssertTrue(element("files.pinned.see-all").exists, "seven pins offered no See all")
    XCTAssertFalse(element("files.pinned.item.441").exists, "the section lists more than five")
    try captureBoard("rd-ios-66-pinned-see-all")
  }

  func testPinnedList() throws {
    try reachPins("seven")
    element("files.pinned.see-all").tap()
    XCTAssertTrue(element("files.pinned-list").appears(within: 5), "See all opened no list")
    XCTAssertTrue(app.staticTexts["7 items"].appears(within: 5), "the list does not count pins")
    XCTAssertTrue(element("files.pinned.item.441").exists, "the list leaves out a pin")
    try captureBoard("rd-ios-67-pinned-list")
  }

  private func reachPins(_ mode: String) throws {
    orient(.portrait)
    app.launchArguments += ["--putio-harness-pins", mode]
    app.launch()
    reachFilesRoot()
    XCTAssertTrue(element("files.pinned.item.440").appears(within: 10), "the pins never loaded")
  }

  func testFileMenu() throws {
    orient(.portrait)
    app.launch()
    reachFilesRoot()
    XCTAssertTrue(app.revealed("files.item.407").exists, "the archive row never appeared")
    openItemMenu("files.item.407")
    try captureBoard("rd-ios-63-file-menu")
  }

  func testSharedRoot() throws {
    orient(.portrait)
    app.launchArguments.append("--putio-harness-shared-items")
    app.launch()
    openSharedRoot()
    XCTAssertTrue(element("files.item.522").appears(within: 10), "selin never appeared")
    try captureBoard("rd-ios-54-shared-root")
  }

  func testSharedLongPress() throws {
    orient(.portrait)
    app.launchArguments.append("--putio-harness-shared-items")
    app.launch()
    openSharedFileMenu()
    try captureBoard("rd-ios-55-shared-long-press")
  }

  func testCopy() throws {
    orient(.portrait)
    app.launchArguments.append("--putio-harness-shared-items")
    app.launch()
    openCopySheet()
    try captureBoard("rd-ios-56-copy")
  }

  func testCopied() throws {
    orient(.portrait)
    app.launchArguments.append("--putio-harness-shared-items")
    app.launch()
    openCopySheet()
    app.buttons["Copy to Files"].tap()
    XCTAssertTrue(
      app.staticTexts["Copied “Tears.of.Steel.2012.mkv” to Files."].appears(within: 15),
      "the copy never confirmed")
    try captureBoard("rd-ios-57-copied")
  }

  private func openSharedRoot() {
    openRoot()
    let shared = app.revealed("files.item.520", maximumSwipes: 12)
    XCTAssertTrue(shared.exists, "Items shared with you never appeared")
    shared.tap()
    XCTAssertTrue(element("files.item.521").appears(within: 10), "deniz never appeared")
  }

  private func openSharedFileMenu() {
    openSharedRoot()
    element("files.item.521").tap()
    let video = element("files.item.524")
    XCTAssertTrue(video.appears(within: 10), "the shared video never appeared")
    video.press(forDuration: 1)
    XCTAssertTrue(app.buttons["Make a copy"].appears(within: 5), "the menu has no Make a copy")
    XCTAssertTrue(app.staticTexts["Shared by deniz"].exists, "the row never named deniz")
  }

  private func openCopySheet() {
    openSharedFileMenu()
    app.buttons["Make a copy"].tap()
    XCTAssertTrue(element("files.move-screen.0").appears(within: 5), "Copy never opened")
    XCTAssertTrue(app.staticTexts["Copy 1 item"].exists, "the sheet is not titled for a copy")
    XCTAssertTrue(app.buttons["Copy to Files"].appears(within: 10), "Copy to Files never enabled")
  }

  func testMove() throws {
    orient(.portrait)
    app.launch()
    openSeasonFolder()
    openMoveSheet(for: "files.item.445")
    try captureBoard("rd-ios-19-move")
  }

  func testExclusiveLinkCreating() throws {
    openExclusiveLink(create: "slow")
    app.buttons["files.exclusive-link.create"].tap()
    XCTAssertTrue(app.staticTexts["Creating link…"].appears(within: 5), "creation never started")
    try captureBoard("rd-ios-78-link-create")
  }

  func testExclusiveLinkCreated() throws {
    openExclusiveLink(create: "ready")
    app.buttons["files.exclusive-link.create"].tap()
    XCTAssertTrue(
      element("files.exclusive-link.created").appears(within: 10), "the link was never created")
    try captureBoard("rd-ios-79-link-created")
  }

  func testExclusiveLinkRefused() throws {
    openExclusiveLink(create: "refusals")
    app.buttons["files.exclusive-link.create"].tap()
    XCTAssertTrue(
      app.staticTexts["You can’t create public links with your current plan."].appears(within: 10),
      "the plan refusal never showed")
    try captureBoard("rd-ios-80-link-refused")
  }

  private func openExclusiveLink(create mode: String) {
    orient(.portrait)
    app.launchArguments += ["--putio-harness-public-link-create", mode]
    app.launch()
    openSeasonFolder()
    openItemMenu("files.item.442")
    app.buttons["Exclusive link"].firstMatch.tap()
    XCTAssertTrue(
      app.buttons["files.exclusive-link.create"].appears(within: 5), "Exclusive link never opened")
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
    XCTAssertTrue(
      app.buttons["files.move-new-folder"].isEnabled, "New folder is disabled while the level loads"
    )
    XCTAssertFalse(app.buttons["sheet.primary"].isEnabled, "a loading level is a target")
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
    let alert = app.putioAlert("New folder")
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

  func testNewFolderFailedToast() throws {
    orient(.portrait)
    app.launchArguments.append("--putio-harness-create-folder-fails-once")
    app.launch()
    openSeasonFolder()
    openMoreMenu()
    app.buttons["New folder"].tap()
    let alert = app.putioAlert("New folder")
    XCTAssertTrue(alert.appears(within: 5), "New folder never opened")
    XCTAssertTrue(app.keyboards.firstMatch.appears(within: 5), "the name field never took focus")
    app.typeText("Season 5")
    alert.buttons["Create"].firstMatch.tap()
    XCTAssertTrue(alert.disappears(within: 5), "the alert stayed open after Create")
    XCTAssertTrue(
      app.staticTexts["Couldn’t create folder."].appears(within: 10), "no failure toast")
    let retry = app.buttons["Try again"]
    XCTAssertTrue(retry.exists, "the failure toast offers no Try again")
    XCTAssertFalse(app.staticTexts["Season 5"].exists, "the failed folder appeared")
    try captureBoard("rd-ios-81-new-folder-failed-toast")
    retry.tap()
    XCTAssertTrue(
      app.staticTexts["Season 5"].appears(within: 10), "Try again did not create the same name")
  }

  func testSortMenu() throws {
    orient(.portrait)
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
    orient(.portrait)
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

  func testSelection() throws {
    orient(.portrait)
    app.launch()
    openSeasonFolder()
    select(["files.item.441", "files.item.442", "files.item.443"])
    assertSelectionBar(["move", "download", "watched", "trash"])
    try captureBoard("rd-ios-06-selection")
  }

  func testSelectionMixed() throws {
    orient(.portrait)
    app.launch()
    openRoot()
    select(["files.item.410", "files.item.412", "files.item.413"])
    assertSelectionBar(["move", "trash"])
    try captureBoard("rd-ios-58-selection-mixed")
  }

  func testSelectionNone() throws {
    orient(.portrait)
    app.launch()
    openRoot()
    select([])
    assertSelectionBar(["move", "trash"])
    XCTAssertFalse(element("selection.action.move").isEnabled, "an empty selection can move")
    XCTAssertFalse(element("selection.action.trash").isEnabled, "an empty selection can trash")
    try captureBoard("rd-ios-59-selection-none")
  }

  func testSelectionTrashOff() throws {
    orient(.portrait)
    app.launchArguments.append("--putio-harness-trash-disabled")
    app.launch()
    openSeasonFolder()
    select(["files.item.441", "files.item.442", "files.item.443"])
    assertSelectionBar(["move", "download", "watched", "trash"])
    XCTAssertEqual(element("selection.action.trash").label, "Delete")
    try captureBoard("rd-ios-68-selection-trash-off")
  }

  func testSelectionAll() throws {
    orient(.portrait)
    app.launch()
    openRoot()
    select([])
    app.buttons["selection.toggle-all"].tap()
    XCTAssertEqual(element("files.item.410").value as? String, "Selected")
    XCTAssertEqual(element("files.item.413").value as? String, "Selected")
    assertSelectionBar(["move", "trash"])
    try captureBoard("rd-ios-70-selection-all")
  }

  func testSelectionTrashed() throws {
    orientForBoardDevice()
    app.launch()
    openSeasonFolder()
    select(["files.item.441", "files.item.442", "files.item.443"])
    element("selection.action.trash").tap()
    XCTAssertTrue(
      app.staticTexts["Moved 3 items to trash"].appears(within: 10), "no bulk trash toast")
    XCTAssertTrue(element("selection.bar").disappears(within: 5), "bulk Trash kept selection")
    XCTAssertTrue(app.buttons["Undo"].exists, "the bulk trash toast has no Undo")
    try captureBoard("rd-ios-60-selection-trashed")
  }

  func testSelectionFailed() throws {
    orientForBoardDevice()
    app.launchArguments.append("--putio-harness-bulk-trash-refusal")
    app.launch()
    openSeasonFolder()
    select(["files.item.441", "files.item.442"])
    element("selection.action.trash").tap()
    XCTAssertTrue(
      app.staticTexts["2 items are still in Files."].appears(within: 10), "no failure toast")
    XCTAssertTrue(app.buttons["Try again"].exists, "the failure toast has no Try again")
    XCTAssertLessThanOrEqual(
      app.buttons["Try again"].frame.maxY, element("selection.action.trash").frame.minY,
      "the failure toast covers the selection bar")
    XCTAssertEqual(element("files.item.441").value as? String, "Selected")
    XCTAssertEqual(element("files.item.442").value as? String, "Selected")
    try captureBoard("rd-ios-61-selection-failed")
  }

  func testIPadSelection() throws {
    orient(.landscapeLeft)
    app.launch()
    openSeasonFolder()
    selectVideo(element("files.item.443"), id: 443, primary: "Play")
    select(["files.item.441", "files.item.442"])
    assertSelectionBar(["move", "download", "watched", "trash"])
    XCTAssertTrue(tabButton("Downloads").exists, "selection hid the iPad tab bar")
    XCTAssertTrue(
      element("files.detail.443").disappears(within: 5), "selection kept the open file")
    XCTAssertTrue(app.staticTexts["No file selected"].exists, "selection opened a file")
    try captureBoard("rd-ios-24-ipad-selection")
  }

  func testVideoPlayer() throws {
    orient(.landscapeLeft)
    app.launch()
    openSeasonFolder()
    let episode = element("files.item.441")
    XCTAssertTrue(episode.appears(within: 10), "the first episode never appeared")
    episode.tap()
    let detailPlay = element("files.detail.play")
    if detailPlay.appears(within: 3) { detailPlay.tap() }
    let retry = app.buttons["Try again"]
    if retry.appears(within: 10) { retry.tap() }
    XCTAssertTrue(element("video.ready").appears(within: 15), "the episode never played")
    XCTAssertEqual(
      element("video.title").label, "Blue.Lights.S04E01.1080p.HDTV.H264-ORGANiC.mkv")
    let position = element("video.current-position")
    let advanced = XCTNSPredicateExpectation(
      predicate: NSPredicate(format: "value != '0'"), object: position)
    XCTAssertEqual(
      XCTWaiter.wait(for: [advanced], timeout: 10), .completed, "the episode is not playing")
    let playPause = element("video.play-pause")
    let auditsText = ProcessInfo.processInfo.environment["PUTIO_BOARD_TEXT_AUDIT"] == "1"
    app.setVideoPlaying(!auditsText, with: playPause)
    try captureBoard("rd-ios-pb-02-video")
  }

  func testIPadSplit() throws {
    orient(.landscapeLeft)
    app.launch()
    openSeasonFolder()
    let row = element("files.item.442")
    selectVideo(row, id: 442, primary: "Resume from 21:00")
    XCTAssertGreaterThanOrEqual(
      row.frame.maxX, 384, "the list column is narrower than its 384 pt minimum")
    XCTAssertFalse(element("video.ready").exists, "selecting a video started playback")
    assertFact("length", "Length, 49:49")
    assertFact("subtitles", "Subtitles, English, Turkish")
    assertFact("folder", "Folder, Harness Folder / Blue Lights")
    XCTAssertTrue(element("files.detail.download").exists, "the detail offers no Download")
    XCTAssertTrue(element("files.detail.more").exists, "the detail offers no More")
    try captureBoard("rd-ios-12-ipad-split")

    rotate(.portrait)
    XCTAssertTrue(element("files.screen.440").appears(within: 5), "rotating reset the Files path")
    XCTAssertTrue(element("files.detail.442").disappears(within: 5), "portrait kept the detail")
    rotate(.landscapeLeft)
    XCTAssertTrue(element("files.detail.442").appears(within: 5), "rotating lost the selection")
    XCTAssertTrue(row.isSelected, "rotating lost the selected row")

    app.navigationBars.buttons["BackButton"].firstMatch.tap()
    XCTAssertTrue(element("files.screen.410").appears(within: 5), "Back never left the folder")
    XCTAssertTrue(element("files.detail.442").exists, "going back emptied the detail")
    assertFact("folder", "Folder, Harness Folder / Blue Lights")
    let folder = element("files.item.440")
    XCTAssertTrue(folder.appears(within: 5), "the season folder row is missing")
    folder.tap()
    XCTAssertTrue(element("files.header.440").appears(within: 10), "the folder never pushed")
    XCTAssertTrue(element("files.detail.442").exists, "opening a folder emptied the detail")
    XCTAssertTrue(row.appears(within: 5) && row.isSelected, "the reopened folder lost the tint")

    element("files.detail.play").tap()
    let selection = element("files.selection")
    XCTAssertTrue(selection.appears(within: 10), "Play never opened the video")
    XCTAssertEqual(selection.value as? String, "id=442;parent=440;kind=video")
  }

  func testIPadDetailNotDownloaded() throws {
    orient(.landscapeLeft)
    app.launch()
    openSeasonFolder()
    selectVideo(element("files.item.443"), id: 443, primary: "Play")
    XCTAssertTrue(element("files.detail.download").exists, "the detail offers no Download")
    XCTAssertFalse(element("files.detail.on-device").exists, "a remote file shows on device")
    assertFact("size", "Size, 3.1 GB")
    assertFact("added", "Added, Oct 20, 2026")
    try captureBoard("rd-ios-33-ipad-detail-not-downloaded")

    reachFilesRoot()
    let signIn = element("auth.sign-in")
    let remove = app.buttons["auth.sign-out-remove-downloads"].firstMatch
    addTeardownBlock { @MainActor [self] in
      if !signIn.exists {
        openSignOut()
        if remove.appears(within: 5) { remove.tap() }
      }
      _ = signIn.appears(within: 15)
    }
    selectVideo(element("files.item.412"), id: 412, primary: "Resume from 9:49")
    assertFact("folder", "Folder, Files")
    element("files.detail.download").tap()
    let confirm = app.buttons["downloads.picker.confirm"]
    XCTAssertTrue(confirm.appears(within: 20), "the track picker never appeared")
    confirm.tap()
    XCTAssertTrue(element("downloads.screen").appears(within: 10), "Downloads never opened")
    tabButton("Files").tap()
    let onDevice = element("files.detail.on-device")
    XCTAssertTrue(onDevice.appears(within: 90), "the finished download never showed on device")
    XCTAssertFalse(onDevice.isEnabled, "the on-device button is tappable")
    let window = app.windows.firstMatch.frame.size
    let onDeviceCapture = XCTAttachment(
      image: Self.oriented(Self.screenshot(showing: window), toMatch: window))
    onDeviceCapture.name = "ipad-detail-on-device"
    onDeviceCapture.lifetime = .keepAlways
    add(onDeviceCapture)
    XCTAssertFalse(element("files.detail.download").exists, "Download stayed beside on device")
  }

  func testDuoOpen() throws {
    app.launch()
    openSeasonFolder()
    let row = element("files.item.442")
    selectVideo(row, id: 442, primary: "Resume from 21:00")
    assertFact("folder", "Folder, Harness Folder / Blue Lights")
    try captureBoard("rd-ios-15-duo-open")

    try fold()
    XCTAssertTrue(element("files.detail.442").appears(within: 10), "folding dropped the selection")
    XCTAssertEqual(element("files.detail.play").label, "Resume from 21:00")
    try unfold()
    XCTAssertTrue(element("files.detail.442").appears(within: 10), "unfolding lost the selection")
    XCTAssertTrue(element("files.screen.440").appears(within: 10), "unfolding reset the path")
    XCTAssertTrue(row.appears(within: 5) && row.isSelected, "unfolding lost the selected row")

    navigationBack().tap()
    XCTAssertTrue(element("files.screen.410").appears(within: 5), "Back never left the folder")
    openFolder(440)
    XCTAssertTrue(element("files.detail.442").exists, "opening a folder emptied the detail")

    try fold()
    XCTAssertTrue(element("files.detail.442").appears(within: 10), "folding dropped the selection")
    navigationBack().tap()
    XCTAssertTrue(element("files.screen.440").appears(within: 5), "Back left the folder")
    XCTAssertTrue(element("files.detail.442").disappears(within: 5), "Back kept the file open")
    navigationBack().tap()
    XCTAssertTrue(element("files.screen.410").appears(within: 5), "Back never left the folder")
    openFolder(440)
    try unfold()
    XCTAssertTrue(element("files.screen.440").appears(within: 10), "unfolding reset the path")
    XCTAssertTrue(app.staticTexts["No file selected"].appears(within: 5), "a closed file came back")
  }

  func testDuoNothingSelected() throws {
    app.launch()
    openSeasonFolder()
    XCTAssertTrue(
      app.staticTexts["No file selected"].appears(within: 5), "the empty detail has no title")
    XCTAssertTrue(app.staticTexts["Tap a file to see it here."].exists)
    try captureBoard("rd-ios-16-duo-nothing")
  }

  func testDuoFoldKeepsScroll() throws {
    app.launchArguments += [
      "--putio-harness-continue-watching", "three", "--putio-harness-pins", "three",
    ]
    app.launch()
    reachFilesRoot()
    let card = element("files.continue-watching.item.442")
    XCTAssertTrue(card.appears(within: 10), "Continue watching never loaded")
    try captureBoard("rd-ios-duo-02-closed-files")
    let list = element("files.screen.0")
    for _ in 0..<2 where card.exists && card.isHittable { list.swipeUp() }
    XCTAssertFalse(card.exists && card.isHittable, "the root never scrolled")
    try unfold()
    XCTAssertTrue(app.staticTexts["No file selected"].appears(within: 10), "the root never opened")
    XCTAssertTrue(list.appears(within: 10), "unfolding left the root")
    XCTAssertFalse(card.exists && card.isHittable, "unfolding scrolled the root to the top")
    try fold()
    XCTAssertTrue(list.appears(within: 10), "folding left the root")
    XCTAssertFalse(card.exists && card.isHittable, "folding scrolled the root to the top")
  }

  private func openFolder(_ id: Int) {
    let folder = app.revealed("files.item.\(id)")
    XCTAssertTrue(folder.appears(within: 10), "the folder row \(id) is missing")
    folder.tap()
    XCTAssertTrue(element("files.header.\(id)").appears(within: 10), "the folder never pushed")
  }

  private func fold() throws {
    try setHinge(degrees: 0)
    let window = app.windows.firstMatch
    XCTAssertTrue(
      waitUntil(10) { window.exists && window.frame.width < Self.regularWidthThreshold },
      "the iPhone Duo never folded: window is \(window.frame.size) pt")
  }

  private func unfold() throws {
    try setHinge(degrees: 180)
    let window = app.windows.firstMatch
    XCTAssertTrue(
      waitUntil(10) { window.exists && window.frame.size == Self.openDuoSize },
      "the iPhone Duo never unfolded: window is \(window.frame.size) pt")
  }

  private func restoreDuoPosture() {
    guard movedHinge else { return }
    switch ProcessInfo.processInfo.environment["PUTIO_BOARD_DEVICE"] {
    case "duo-folded": try? setHinge(degrees: 0)
    case "duo-open": try? setHinge(degrees: 180)
    default: break
    }
  }

  private func setHinge(degrees: Int) throws {
    let tool = try XCTUnwrap(
      ProcessInfo.processInfo.environment["PUTIO_DUO_POSTURE_TOOL"],
      "the harness passed no iPhone Duo posture tool")
    let arguments = [tool, "angle", String(degrees)]
    var argv: [UnsafeMutablePointer<CChar>?] = arguments.map { strdup($0) } + [nil]
    defer { for pointer in argv { free(pointer) } }
    var pid: pid_t = 0
    let spawned = posix_spawn(&pid, tool, nil, nil, &argv, environ)
    XCTAssertEqual(
      spawned, 0, "the posture tool did not start: \(String(cString: strerror(spawned)))")
    guard spawned == 0 else { return }
    movedHinge = true
    var status: Int32 = 0
    var waited: pid_t
    repeat { waited = waitpid(pid, &status, 0) } while waited == -1 && errno == EINTR
    XCTAssertEqual(
      waited, pid, "waiting for the posture tool failed: \(String(cString: strerror(errno)))")
    XCTAssertEqual(status, 0, "the posture tool exited with \(status)")
  }

  private func waitUntil(_ timeout: TimeInterval, _ condition: () -> Bool) -> Bool {
    let deadline = Date.now.addingTimeInterval(timeout)
    while !condition() {
      guard Date.now < deadline else { return false }
      RunLoop.current.run(until: Date.now.addingTimeInterval(0.2))
    }
    return true
  }

  func testIPadDetailMore() throws {
    orient(.landscapeLeft)
    app.launch()
    openSeasonFolder()
    selectVideo(element("files.item.441"), id: 441, primary: nil)
    openDetailMore(lacking: ["Play", "Download", "Share", "Select"])
    XCTAssertTrue(
      app.buttons["Mark as watched"].exists || app.buttons["Mark as unwatched"].exists,
      "More has no Mark as watched or unwatched")
    try captureBoard("rd-ios-29-ipad-detail-more")
  }

  func testIPadDetailImage() throws {
    orient(.landscapeLeft)
    app.launch()
    reachFilesRoot()
    selectFile(element("files.item.406"), id: 406)
    XCTAssertTrue(
      element("files.detail.preview-image").appears(within: 15), "the image never showed")
    assertFactShown("size")
    assertFact("added", "Added, Aug 28, 2026")
    assertFact("folder", "Folder, Files")
    XCTAssertFalse(element("files.detail.fact.length").exists, "an image lists a length")
    XCTAssertFalse(element("files.detail.fact.subtitles").exists, "an image lists subtitles")
    XCTAssertFalse(element("files.detail.download").exists, "an image offers Download")
    XCTAssertTrue(element("files.detail.share").exists, "the image detail offers no Share")
    try captureBoard("rd-ios-30-ipad-detail-image")

    openDetailMore(
      lacking: ["Play", "Download", "Share", "Select", "Mark as watched", "Mark as unwatched"])
    element("files.detail.fact.folder").tap()
    XCTAssertTrue(app.buttons["Rename"].disappears(within: 5), "the detail More stayed open")
    let row = element("files.item.406")
    element("files.detail.open").tap()
    assertPreviewFillsWindow(fileID: 406)
    assertPreviewKeepsFileAcrossRotation(fileID: 406) { element("preview.image") }
    assertBackReturnsToDetail(row, fileID: 406)

    row.tap()
    assertPreviewFillsWindow(fileID: 406)
    assertBackReturnsToDetail(row, fileID: 406)
  }

  func testIPadDetailText() throws {
    orient(.landscapeLeft)
    app.launch()
    openSeasonFolder()
    selectFile(element("files.item.445"), id: 445)
    XCTAssertTrue(
      element("files.detail.preview-glyph").appears(within: 5), "the text file shows no glyph")
    assertFactShown("size")
    assertFact("added", "Added, Oct 13, 2026")
    assertFact("folder", "Folder, Harness Folder / Blue Lights")
    XCTAssertFalse(element("files.detail.fact.length").exists, "a text file lists a length")
    try captureBoard("rd-ios-31-ipad-detail-text")

    let renamed = "Blue.Lights.S04E01.de.srt"
    openDetailMore(lacking: ["Share", "Select"])
    app.buttons["Rename"].firstMatch.tap()
    let alert = app.putioAlert("Rename")
    XCTAssertTrue(alert.appears(within: 5), "Rename never opened from the detail")
    app.typeText("Blue.Lights.S04E01.de")
    alert.buttons["Rename"].firstMatch.tap()
    let retry = app.buttons["Try again"]
    XCTAssertTrue(retry.appears(within: 10), "the seeded first rename did not fail")
    retry.tap()
    let title = element("files.detail.title")
    let titled = XCTNSPredicateExpectation(
      predicate: NSPredicate(format: "label == %@", renamed), object: title)
    XCTAssertEqual(
      XCTWaiter.wait(for: [titled], timeout: 10), .completed, "the detail kept the old name")
    XCTAssertTrue(element("files.detail.445").exists, "renaming emptied the detail")

    openDetailMore(lacking: [])
    app.buttons["Move to trash"].firstMatch.tap()
    XCTAssertTrue(element("files.detail.445").disappears(within: 10), "trash kept the detail")
    XCTAssertTrue(app.staticTexts["No file selected"].exists, "trash left a file open")
    XCTAssertTrue(element("files.item.445").disappears(within: 5), "the trashed row stayed")
  }

  private func selectFile(_ row: XCUIElement, id: Int) {
    XCTAssertTrue(row.appears(within: 10), "the row for \(id) never appeared")
    row.tap()
    XCTAssertTrue(
      element("files.detail.\(id)").appears(within: 10), "selecting \(id) showed no detail")
    XCTAssertTrue(row.isSelected, "the selected row is not marked open")
    XCTAssertFalse(element("preview.screen.\(id)").exists, "selecting \(id) opened the preview")
    let open = element("files.detail.open")
    XCTAssertTrue(open.appears(within: 5), "the detail has no Open")
    XCTAssertEqual(open.label, "Open")
    XCTAssertFalse(element("files.detail.play").exists, "a file that is not a video offers Play")
  }

  private func openFileRow(_ row: XCUIElement, id: Int) {
    row.tap()
    let detail = element("files.detail.\(id)")
    let preview = element("preview.screen.\(id)")
    let opened = XCTNSPredicateExpectation(
      predicate: NSPredicate { _, _ in detail.exists || preview.exists }, object: nil)
    XCTAssertEqual(
      XCTWaiter.wait(for: [opened], timeout: 10), .completed,
      "tapping \(id) showed neither the detail nor the preview")
    if detail.exists { element("files.detail.open").tap() }
  }

  private func openDetailMore(lacking absent: [String]) {
    let before = absent.map { labelledButtons($0).count }
    let more = element("files.detail.more")
    XCTAssertTrue(more.appears(within: 5), "the detail has no More")
    more.tap()
    XCTAssertTrue(app.buttons["Rename"].appears(within: 5), "the detail More never opened")
    for label in ["Move", "Exclusive link", "Move to trash"] {
      XCTAssertTrue(app.buttons[label].exists, "the detail More lacks \(label)")
    }
    XCTAssertTrue(
      app.buttons["Pin"].exists || app.buttons["Unpin"].exists, "the detail More has no Pin")
    for (label, count) in zip(absent, before) {
      XCTAssertEqual(labelledButtons(label).count, count, "the detail More repeats \(label)")
    }
  }

  private func labelledButtons(_ label: String) -> XCUIElementQuery {
    app.buttons.matching(NSPredicate(format: "label == %@", label))
  }

  private func selectVideo(_ row: XCUIElement, id: Int, primary: String?) {
    XCTAssertTrue(row.appears(within: 10), "the row for \(id) never appeared")
    row.tap()
    XCTAssertTrue(
      element("files.detail.\(id)").appears(within: 10), "selecting \(id) showed no detail")
    XCTAssertTrue(row.isSelected, "the selected row is not marked open")
    let play = element("files.detail.play")
    XCTAssertTrue(play.appears(within: 5), "the detail has no primary button")
    if let primary { XCTAssertEqual(play.label, primary) }
  }

  private func assertFactShown(_ id: String) {
    XCTAssertTrue(
      element("files.detail.fact.\(id)").appears(within: 10), "the detail lists no \(id)")
  }

  private func assertFact(_ id: String, _ label: String) {
    let fact = element("files.detail.fact.\(id)")
    XCTAssertTrue(fact.appears(within: 10), "the detail lists no \(id)")
    XCTAssertEqual(fact.label, label)
  }

  func testSearch() throws {
    orientForBoardDevice()
    app.launch()
    searchBlue()
    try captureBoard("rd-ios-07-search")
  }

  func testSearchLoading() throws {
    orientForBoardDevice()
    app.launchArguments.append("--putio-harness-hold-search")
    app.launch()
    reachFilesRoot()
    typeSearch("blue")
    XCTAssertTrue(labeled("Searching files").appears(within: 10), "the search shows no spinner")
    XCTAssertTrue(element("files.search-filter.all").exists, "the filters left while loading")
    try captureBoard("rd-ios-42-search-loading")
  }

  func testSearchFilter() throws {
    orientForBoardDevice()
    app.launch()
    searchBlue()
    element("files.search-filter.videos").tap()
    XCTAssertTrue(
      element("files.search-item.440").disappears(within: 10), "Videos kept the folder result")
    XCTAssertTrue(element("files.search-item.441").appears(within: 10), "Videos lost the episode")
    XCTAssertFalse(element("files.search-group.folders").exists, "Videos kept the Folders group")
    try captureBoard("rd-ios-48-search-filter")
  }

  func testSearchLongPress() throws {
    orientForBoardDevice()
    app.launch()
    searchBlue()
    let result = element("files.search-item.441")
    result.press(forDuration: 1)
    XCTAssertTrue(app.buttons["Move"].appears(within: 5), "the result menu never opened")
    XCTAssertFalse(app.buttons["Rename"].exists, "the result menu offers Rename")
    try captureBoard("rd-ios-49-search-long-press")
  }

  func testSearchNone() throws {
    orientForBoardDevice()
    app.launch()
    reachFilesRoot()
    typeSearch("blorp")
    XCTAssertTrue(labeled("Nothing matches").appears(within: 10), "no empty search state")
    try captureBoard("rd-ios-28-search-none")
  }

  func testSearchFailed() throws {
    orientForBoardDevice()
    app.launchArguments.append("--putio-harness-search-offline")
    app.launch()
    reachFilesRoot()
    typeSearch("blue")
    XCTAssertTrue(labeled("Couldn’t search").appears(within: 10), "no failed search state")
    try captureBoard("rd-ios-46-search-failed")
  }

  func testSearchMoreFailed() throws {
    orientForBoardDevice()
    app.launchArguments.append("--putio-harness-search-more-fails")
    app.launch()
    searchBlue()
    XCTAssertTrue(
      element("files.search-more-retry").appears(within: 10), "the next page never failed")
    try captureBoard("rd-ios-47-search-more-failed")
  }

  func testSearchLongQuery() throws {
    orientForBoardDevice()
    app.launch()
    reachFilesRoot()
    typeSearch("blue lights season four episode one organic 1080p hdtv")
    XCTAssertTrue(labeled("Nothing matches").appears(within: 10), "no empty search state")
    try captureBoard("rd-ios-71-search-long-query")
  }

  func testSearchRecent() throws {
    orientForBoardDevice()
    app.launchArguments += ["--putio-harness-search-history", "recent"]
    app.launch()
    reachFilesRoot()
    tabButton("Search").tap()
    XCTAssertTrue(app.staticTexts["Recent searches"].appears(within: 10), "no recent searches")
    XCTAssertTrue(
      app.buttons["files.search-recent.tree rings"].exists, "a recent search is missing")
    try captureBoard("rd-ios-27-search-recent")
  }

  func testSearchStart() throws {
    orientForBoardDevice()
    app.launch()
    reachFilesRoot()
    tabButton("Search").tap()
    XCTAssertTrue(app.staticTexts["Find your files"].appears(within: 10), "no first-use state")
    try captureBoard("rd-ios-45-search-start")
  }

  private func typeSearch(_ query: String) {
    tabButton("Search").tap()
    let field = app.searchFields.firstMatch
    XCTAssertTrue(field.appears(within: 10), "the search field never appeared")
    field.tap()
    field.typeText(query + "\n")
  }

  private func searchBlue() {
    reachFilesRoot()
    typeSearch("blue")
    XCTAssertTrue(element("files.search-item.440").appears(within: 10), "no folder result")
    XCTAssertTrue(element("files.search-item.445").appears(within: 10), "no subtitle result")
    let location = app.staticTexts["in Blue Lights"].firstMatch
    XCTAssertTrue(location.appears(within: 10), "results never named their folder")
  }

  func testFilesRoot() throws {
    orient(.portrait)
    try reachContinueWatching()
    try captureBoard("Main")
  }

  func testContinueWatchingMenu() throws {
    orient(.portrait)
    try reachContinueWatching()
    element("files.continue-watching.item.442").press(forDuration: 1)
    XCTAssertTrue(
      app.buttons["Remove from Continue watching"].appears(within: 5),
      "the card menu has no Remove")
    try captureBoard("rd-ios-25-continue-watching-menu")
  }

  func testIPadRoot() throws {
    orient(.landscapeLeft)
    app.launchArguments += ["--putio-harness-pins", "three"]
    try reachContinueWatching()
    XCTAssertTrue(element("files.pinned.item.440").appears(within: 10), "the pins never loaded")
    XCTAssertTrue(
      app.staticTexts["No file selected"].exists, "the empty detail is missing beside the root")
    XCTAssertTrue(app.staticTexts["Tap a file to see it here."].exists)
    try captureBoard("rd-ios-26-ipad-root")
  }

  func testNowPlaying() throws {
    try playMusic(path: ["files.item.3101", "files.item.3103"], track: 3103)
    XCTAssertTrue(
      expectEnabled(app.buttons["audio.previous"]), "the middle file offers no previous")
    XCTAssertTrue(app.buttons["audio.next"].isEnabled, "the middle file offers no next")
    XCTAssertTrue(labeled("Music").exists, "the folder name is missing")
    try captureBoard("rd-ios-pb-04-now-playing")
  }

  func testSingleAudio() throws {
    try playMusic(
      path: ["files.item.3105", "files.item.3106", "files.item.3107"], track: 3107)
    XCTAssertTrue(labeled("Music").appears(within: 10), "the folder name is missing")
    XCTAssertFalse(app.buttons["audio.previous"].isEnabled)
    XCTAssertFalse(app.buttons["audio.next"].isEnabled)
    XCTAssertFalse(app.buttons["audio.up-next"].isEnabled)
    try captureBoard("rd-ios-pb-39-single-audio")
  }

  func testPreparingAudio() throws {
    app.launchArguments.append("--putio-harness-audio-held")
    try playMusic(path: ["files.item.3101", "files.item.3103"], track: 3103, state: "loading")
    XCTAssertTrue(app.staticTexts["Preparing audio"].exists, "the loading state has no label")
    try captureBoard("rd-ios-pb-25-preparing-audio")
  }

  func testAudioError() throws {
    app.launchArguments.append("--putio-harness-audio-fails-once")
    try playMusic(path: ["files.item.3101", "files.item.3103"], track: 3103, state: "failed")
    XCTAssertTrue(app.staticTexts["Couldn’t play this audio"].exists)
    XCTAssertTrue(app.staticTexts["put.io is temporarily unavailable. Try again."].exists)
    XCTAssertTrue(app.buttons["audio.retry"].exists)
    try captureBoard("rd-ios-pb-37-audio-error")
  }

  func testUpNext() throws {
    try playMusic(path: ["files.item.3101", "files.item.3102"], track: 3102)
    let upNext = app.buttons["audio.up-next"]
    XCTAssertTrue(expectEnabled(upNext), "the four-file folder offers no Up next")
    upNext.tap()
    let current = element("audio.up-next.3102")
    XCTAssertTrue(current.appears(within: 10), "the Up next list never opened")
    XCTAssertTrue(element("audio.up-next.3108").exists, "the list stops short of the folder")
    XCTAssertTrue(current.isSelected, "the playing file is not marked")
    XCTAssertTrue(labeled("56:20").exists, "the list shows no length")
    try captureBoard("rd-ios-pb-12-up-next")
  }

  private func playMusic(path: [String], track: Int, state: String = "playing") throws {
    orientForBoardDevice()
    app.launchArguments.append("--putio-harness-music")
    app.launch()
    openRoot()
    for identifier in path {
      let row = app.revealed(identifier)
      XCTAssertTrue(row.appears(within: 10), "\(identifier) never appeared")
      row.tap()
    }
    let probe = element("audio.state")
    let reached = XCTNSPredicateExpectation(
      predicate: NSPredicate(format: "value == %@", "id=\(track);state=\(state)"), object: probe)
    XCTAssertEqual(
      XCTWaiter.wait(for: [reached], timeout: 15), .completed,
      "Now Playing never reached \(state): \(String(describing: probe.value))")
  }

  private func expectEnabled(_ control: XCUIElement) -> Bool {
    let enabled = XCTNSPredicateExpectation(
      predicate: NSPredicate(format: "enabled == true"), object: control)
    return XCTWaiter.wait(for: [enabled], timeout: 10) == .completed
  }

  private func reachContinueWatching() throws {
    app.launchArguments += ["--putio-harness-continue-watching", "three"]
    app.launch()
    reachFilesRoot()
    for id in [442, 411, 414] {
      XCTAssertTrue(
        element("files.continue-watching.item.\(id)").appears(within: 10),
        "the card for \(id) never appeared")
    }
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
    app.launchArguments += ["--putio-harness-pins", "three"]
    app.launch()
    openHarnessFolder()
    openSidebar()
    XCTAssertTrue(element("files.screen.410").exists, "opening the sidebar reset the Files path")
    assertSidebarPins([440, 410, 412])
    try captureBoard("rd-ios-13-ipad-sidebar")

    sidebarPin(440).tap()
    XCTAssertTrue(element("files.screen.440").appears(within: 10), "the pinned folder never opened")
    sidebarPin(410).tap()
    XCTAssertTrue(element("files.screen.410").appears(within: 10), "the second pin never opened")

    let pinnedRow = element("files.item.440")
    XCTAssertTrue(pinnedRow.appears(within: 10), "the pinned folder row never appeared")
    pinnedRow.press(forDuration: 1)
    XCTAssertTrue(app.buttons["Unpin"].appears(within: 5), "the pinned folder offers no Unpin")
    app.buttons["Unpin"].tap()
    XCTAssertTrue(sidebarPin(440).disappears(within: 5), "Unpin left the pin in the sidebar")
    assertSidebarPins([410, 412])

    let nested = element("files.item.411")
    nested.press(forDuration: 1)
    XCTAssertTrue(app.buttons["Pin"].appears(within: 5), "the nested video offers no Pin")
    app.buttons["Pin"].tap()
    assertSidebarPins([411, 410, 412])

    sidebarPin(411).tap()
    let selection = element("files.selection")
    XCTAssertTrue(selection.appears(within: 10), "the pinned file never opened")
    XCTAssertEqual(selection.value as? String, "id=411;parent=410;kind=video")

    app.terminate()
    app.launchArguments[app.launchArguments.count - 1] = "fail"
    app.launch()
    openHarnessFolder()
    openSidebar()
    XCTAssertTrue(labeled("Account").exists, "failed pins hid the tabs")
    XCTAssertFalse(labeled("Pinned").appears(within: 3), "failed pins drew the Pinned section")
    XCTAssertEqual(sidebarPins().count, 0, "failed pins listed a pin")
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
    let signOut = app.descendants(matching: .any)["auth.sign-out"]
    let list = app.collectionViews.firstMatch
    var swipes = 0
    while !signOut.appears(within: 3), swipes < 6 {
      if list.exists { list.swipeUp() } else { app.swipeUp() }
      swipes += 1
    }
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
    let sizedMessage = app.staticTexts.matching(
      NSPredicate(format: "label BEGINSWITH %@", "Downloads use ")
    ).firstMatch
    if ProcessInfo.processInfo.environment["PUTIO_BOARD_TEXT_AUDIT"] == "1" {
      XCTAssertEqual(remove.label, "Sign out and remove downloads")
      XCTAssertTrue(sizedMessage.exists, "at XX Large the message does not carry the size")
    } else {
      XCTAssertTrue(
        remove.label.range(
          of: #"^Sign out and remove downloads \([^)]*[1-9][^)]*\)$"#, options: .regularExpression)
          != nil, "the remove action does not show the downloads' size: \(remove.label)")
      XCTAssertFalse(sizedMessage.exists, "the message repeats the size the action shows")
    }
    try captureBoard("rd-ios-ses-08-sign-out")
    remove.tap()
    XCTAssertTrue(signIn.appears(within: 15), "sign-out never reached Welcome")
  }

  func testSignOutWithoutDownloads() throws {
    orientForBoardDevice()
    app.launch()
    reachFilesRoot()
    openSignOut()
    let alert = app.putioAlert("Sign out of put.io?")
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

  func testDuoPreviewImage() throws {
    openPosterPreview()
    assertPreviewFillsWindowWithRail()
    try captureBoard("rd-ios-pv-16-duo-image")

    let position = element("preview.position")
    app.windows.firstMatch.swipeLeft(velocity: .fast)
    XCTAssertTrue(
      waitUntil(5) { position.label == "2 of 3" },
      "one swipe did not move one file: \(position.label)")
    app.windows.firstMatch.swipeRight(velocity: .fast)
    XCTAssertTrue(
      waitUntil(5) { position.label == "1 of 3" }, "one swipe did not move back: \(position.label)")
    XCTAssertTrue(app.images["Harness Poster.png"].appears(within: 5), "the poster did not return")

    let image = element("preview.image").images.firstMatch
    let resting = image.frame.width
    element("preview.image").doubleTap()
    XCTAssertTrue(
      waitUntil(5) { image.frame.width > resting * 2.9 },
      "double tap did not zoom 3x into the filled image: \(image.frame.width) from \(resting)")
    element("preview.image").doubleTap()
    XCTAssertTrue(
      waitUntil(5) { abs(image.frame.width - resting) < 1 }, "double tap did not zoom back out")

    try fold()
    assertPreviewFillsWindowWithRail()
    try unfold()
    assertPreviewFillsWindowWithRail()
    element("preview.back").tap()
    XCTAssertTrue(element("preview.image").disappears(within: 5), "Back in the rail never closed")
  }

  private func assertPreviewFillsWindowWithRail() {
    let boardSizes = [CGSize(width: 466, height: 678), Self.openDuoSize]
    XCTAssertTrue(
      waitUntil(10) { boardSizes.contains(app.windows.firstMatch.frame.size) },
      "the window never settled on a Duo board size: \(app.windows.firstMatch.frame.size)")
    let window = app.windows.firstMatch.frame
    let image = element("preview.image").images.firstMatch
    XCTAssertTrue(
      waitUntil(5) { image.exists && image.frame.insetBy(dx: -1, dy: -1).contains(window) },
      "the image letterboxes: \(image.frame) in \(window)")
    XCTAssertFalse(element("preview.title").exists, "the rail viewer shows a title")
    XCTAssertFalse(app.navigationBars.staticTexts["Harness Poster.png"].exists)
    XCTAssertTrue(element("preview.back").appears(within: 5), "the rail has no Back")
    let back = element("preview.back").frame
    let share = element("preview.share").frame
    let more = element("preview.more").frame
    let folded = window.width < window.height
    XCTAssertEqual(back.midX, window.maxX - 42, accuracy: 2, "Back is off the rail column")
    XCTAssertEqual(back.midY, folded ? 174 : 126, accuracy: 3, "Back is off its board height")
    XCTAssertEqual(back.width, 44, accuracy: 1, "Back is not the board's 44 pt circle")
    XCTAssertEqual(share.midX, back.midX, accuracy: 1, "Back and Share are not in one rail")
    XCTAssertEqual(more.midX, back.midX, accuracy: 1, "Back and More are not in one rail")
    XCTAssertEqual(share.midY, folded ? 228 : 180, accuracy: 3, "Share is off its board height")
    XCTAssertEqual(more.midY, folded ? 272 : 224, accuracy: 3, "More is off its board height")
    let position = element("preview.position").frame
    XCTAssertEqual(position.midX, window.midX, accuracy: 1, "the position label is off centre")
  }

  func testPreviewMoreMenu() throws {
    orient(.portrait)
    openPosterPreview()
    openPreviewMore()
    XCTAssertTrue(app.buttons["Exclusive link"].firstMatch.exists, "More has no Exclusive link")
    try captureBoard("rd-ios-pv-02-more")
  }

  func testPreviewRename() throws {
    orient(.portrait)
    openPosterPreview()
    openPreviewMore()
    app.buttons["Rename"].firstMatch.tap()
    let alert = app.putioAlert("Rename")
    XCTAssertTrue(alert.appears(within: 5), "Rename never opened over the viewer")
    XCTAssertTrue(app.keyboards.firstMatch.appears(within: 5), "the name field never took focus")
    XCTAssertEqual(alert.textFields.firstMatch.value as? String, "Harness Poster.png")
    try captureBoard("rd-ios-pv-20-rename")
  }

  func testPreviewTrashed() throws {
    orient(.portrait)
    openGalleryThird()
    let position = element("preview.position")
    let deadline = Date.now.addingTimeInterval(10)
    while !(position.exists && position.label == "3 of 4"), Date.now < deadline {
      RunLoop.current.run(until: Date.now.addingTimeInterval(0.1))
    }
    openPreviewMore()
    app.buttons["Move to trash"].firstMatch.tap()
    let settled = Date.now.addingTimeInterval(4)
    while !(position.exists && position.label == "3 of 3"), Date.now < settled {
      RunLoop.current.run(until: Date.now.addingTimeInterval(0.1))
    }
    try captureBoard("rd-ios-pv-11-trashed")
    XCTAssertTrue(position.exists, "the viewer lost its position")
    XCTAssertEqual(position.label, "3 of 3", "the set still counts the trashed file")
    XCTAssertEqual(element("preview.title").label, "Gallery 4.png", "the viewer did not move on")
  }

  func testPreviewMoreTrashOff() throws {
    orient(.portrait)
    app.launchArguments.append("--putio-harness-trash-disabled")
    openAlbumCover()
    openPreviewMore()
    XCTAssertTrue(app.buttons["Delete permanently"].firstMatch.exists, "More has no delete row")
    XCTAssertTrue(app.buttons["Exclusive link"].firstMatch.exists, "More has no Exclusive link")
    try captureBoard("rd-ios-pv-18-more-trash-off")
    leaveAlbum()
  }

  func testPreviewDeleteConfirm() throws {
    orient(.portrait)
    app.launchArguments.append("--putio-harness-trash-disabled")
    openAlbumCover()
    openPreviewMore()
    app.buttons["Delete permanently"].firstMatch.tap()
    XCTAssertTrue(
      app.putioAlert("Delete 1 item permanently?").appears(within: 5), "the delete never confirmed")
    try captureBoard("rd-ios-pv-19-delete-confirm")
    app.buttons["putio-alert.cancel"].tap()
    leaveAlbum()
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
    rotate(.landscapeLeft)
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
    openDocumentOnSecondPage()
    try captureBoard("rd-ios-pv-03-pdf")
  }

  func testIPadPreviewImage() throws {
    orient(.landscapeLeft)
    openPosterPreview()
    assertPreviewFillsWindow(fileID: 406)
    try captureBoard("rd-ios-pv-14-ipad-image")
    assertPreviewKeepsFileAcrossRotation(fileID: 406) {
      app.images["Harness Poster.png"]
    }
    assertBackReturnsToRow("files.item.406", fileID: 406)
  }

  func testIPadPreviewDocument() throws {
    orient(.landscapeLeft)
    openDocumentOnSecondPage()
    assertPreviewFillsWindow(fileID: 413)
    try captureBoard("rd-ios-pv-15-ipad-pdf")
    assertPreviewKeepsFileAcrossRotation(fileID: 413) {
      element("preview.page")
    }
    assertBackReturnsToRow("files.item.413", fileID: 413)
  }

  func testIPadDetailDocument() throws {
    orient(.landscapeLeft)
    app.launchArguments += ["--putio-harness-previews", "--putio-harness-board-document-name"]
    app.launch()
    reachFilesRoot()
    let row = app.revealed("files.item.413")
    XCTAssertTrue(row.exists, "the document row never appeared")
    let portrait = ProcessInfo.processInfo.environment["PUTIO_BOARD_ORIENTATION"] == "portrait"
    assertWindowSettles(portrait: portrait)
    guard !portrait else {
      row.tap()
      assertPreviewFillsWindow(fileID: 413)
      XCTAssertTrue(
        app.staticTexts["put.io harness page 1"].appears(within: 10), "the document never loaded")
      try captureBoard("rd-ios-pv-17-ipad-detail-pdf")
      assertBackReturnsToRow("files.item.413", fileID: 413)
      return
    }
    selectFile(row, id: 413)
    XCTAssertTrue(
      element("files.detail.preview-glyph").appears(within: 5), "the document shows no glyph")
    XCTAssertEqual(element("files.detail.title").label, "document-scan-march-2026.pdf")
    assertFact("size", "Size, 1.1 MB")
    assertFact("added", "Added, Mar 18, 2026")
    assertFact("folder", "Folder, Files")
    XCTAssertFalse(element("files.detail.fact.length").exists, "a document lists a length")
    XCTAssertFalse(element("files.detail.download").exists, "a document offers Download")
    try captureBoard("rd-ios-pv-17-ipad-detail-pdf")

    let share = element("files.detail.share")
    let sheet = app.openShareSheet(from: share, sharing: "document-scan-march-2026.pdf")
    app.dismissShareSheet(sheet)
    XCTAssertTrue(row.isSelected, "sharing cleared the selection")

    openDetailMore(lacking: ["Open", "Share", "Select", "Download"])
    element("files.detail.fact.folder").tap()
    XCTAssertTrue(app.buttons["Rename"].disappears(within: 5), "the detail More stayed open")

    element("files.detail.open").tap()
    assertPreviewFillsWindow(fileID: 413)
    assertPreviewKeepsFileAcrossRotation(fileID: 413) { element("preview.page") }
    assertBackReturnsToDetail(row, fileID: 413)

    row.tap()
    assertPreviewFillsWindow(fileID: 413)
    assertBackReturnsToDetail(row, fileID: 413)
  }

  private func assertBackReturnsToDetail(_ row: XCUIElement, fileID: Int) {
    assertBackReturnsToRow(row.identifier, fileID: fileID)
    XCTAssertTrue(
      element("files.detail.\(fileID)").appears(within: 5), "Back did not keep the detail")
    XCTAssertTrue(row.isSelected, "Back did not keep the row selected")
  }

  private func openDocumentOnSecondPage() {
    app.launchArguments += ["--putio-harness-previews", "--putio-harness-board-document-name"]
    app.launch()
    reachFilesRoot()
    let row = app.revealed("files.item.413")
    XCTAssertTrue(row.exists, "the document row never appeared")
    openFileRow(row, id: 413)
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
    RunLoop.current.run(until: Date.now.addingTimeInterval(2))
  }

  private func assertPreviewFillsWindow(fileID: Int) {
    let screen = element("preview.screen.\(fileID)")
    XCTAssertTrue(screen.appears(within: 10), "the viewer never opened")
    XCTAssertEqual(
      screen.frame, app.windows.firstMatch.frame, "the viewer does not fill the window")
    XCTAssertFalse(tabButton("Downloads").isHittable, "the tab bar shows over the viewer")
    XCTAssertFalse(element("files.screen.0").isHittable, "the list shows beside the viewer")
  }

  private func assertWindowSettles(portrait: Bool) {
    let window = app.windows.firstMatch
    let deadline = Date.now.addingTimeInterval(10)
    while (window.frame.width < window.frame.height) != portrait, Date.now < deadline {
      RunLoop.current.run(until: Date.now.addingTimeInterval(0.1))
    }
    XCTAssertEqual(
      window.frame.width < window.frame.height, portrait, "the window never settled")
  }

  private func assertPreviewKeepsFileAcrossRotation(
    fileID: Int, content: () -> XCUIElement
  ) {
    for orientation in [UIDeviceOrientation.portrait, .landscapeLeft] {
      rotate(orientation)
      assertWindowSettles(portrait: orientation == .portrait)
      XCTAssertTrue(content().appears(within: 10), "rotating lost the open file")
      assertPreviewFillsWindow(fileID: fileID)
    }
  }

  private func assertBackReturnsToRow(_ identifier: String, fileID: Int) {
    app.buttons["preview.back"].tap()
    XCTAssertTrue(
      element("preview.screen.\(fileID)").disappears(within: 5), "Back did not close the viewer")
    XCTAssertTrue(
      element(identifier).becomesHittable(within: 5), "Back did not return to the same row")
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

  private func openGalleryThird() {
    app.launchArguments.append("--putio-harness-previews")
    app.launch()
    reachFilesRoot()
    let gallery = app.revealed("files.item.470", maximumSwipes: 8)
    XCTAssertTrue(gallery.exists, "the gallery folder never appeared")
    gallery.tap()
    let third = element("files.item.474")
    XCTAssertTrue(third.appears(within: 10), "the gallery never loaded")
    third.tap()
    XCTAssertTrue(app.images["Gallery 3.png"].appears(within: 10), "the third image never loaded")
  }

  private func openAlbumCover() {
    app.launchArguments.append("--putio-harness-previews")
    app.launch()
    reachFilesRoot()
    let gallery = app.revealed("files.item.470", maximumSwipes: 8)
    XCTAssertTrue(gallery.exists, "the gallery folder never appeared")
    gallery.tap()
    let album = element("files.item.496")
    XCTAssertTrue(album.appears(within: 10), "the album never appeared")
    album.tap()
    let cover = element("files.item.497")
    XCTAssertTrue(cover.appears(within: 10), "the album never loaded")
    cover.tap()
    XCTAssertTrue(app.images["Album Cover.png"].appears(within: 10), "the cover never loaded")
  }

  private func leaveAlbum() {
    let viewer = element("preview.screen.497")
    for _ in 0..<3 where viewer.exists {
      app.buttons["preview.back"].tap()
      _ = viewer.disappears(within: 2)
    }
    let album = element("files.screen.496")
    let gallery = element("files.screen.470")
    for _ in 0..<3 where album.exists || gallery.exists {
      app.navigationBars.buttons.firstMatch.tap()
      _ = album.disappears(within: 2)
    }
    XCTAssertFalse(album.exists || gallery.exists, "the album stayed open for the next launch")
  }

  private func openPosterPreview() {
    app.launchArguments.append("--putio-harness-previews")
    app.launch()
    reachFilesRoot()
    let row = app.revealed("files.item.406")
    XCTAssertTrue(row.exists, "the image row never appeared")
    openFileRow(row, id: 406)
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
    assertEmptyFileDetail()
    try captureBoard("rd-ios-ses-26-ipad-inactive")
  }

  private func launchInactiveAccount() throws {
    let account = try XCTUnwrap(ProcessInfo.processInfo.environment["PUTIO_INACTIVE_ACCOUNT"])
    app.launchArguments += ["--putio-harness-account-inactive", account]
    try reachContinueWatching()
    let notice = element("account.inactive-notice")
    XCTAssertTrue(notice.appears(within: 10), "the \(account) notice never showed")
    XCTAssertLessThanOrEqual(
      notice.frame.maxY, element("files.continue-watching.item.442").frame.minY,
      "the \(account) notice is not above Continue watching")
  }

  private func openLongPreview() {
    reachFilesRoot()
    let row = element("files.item.428")
    XCTAssertTrue(row.appears(within: 10), "the long-named image row never appeared")
    openFileRow(row, id: 428)
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
    XCTAssertEqual(element("account.two-factor").label, "Two-factor authentication, Off")
    try captureBoard("rd-ios-acc-43-two-factor-off")
  }

  func testAccountSecurityTwoFactorOn() throws {
    app.launchArguments.append("--putio-harness-two-factor-on")
    openAccount()
    scrollAccount(untilNearTop: "playback-settings.subtitles")
    XCTAssertEqual(element("account.two-factor").label, "Two-factor authentication, On")
    try captureBoard("rd-ios-acc-22-account-security")
  }

  func testAccountDestroy() throws {
    openAccount()
    let destroy = app.revealed("account.destroy-account", maximumSwipes: 8)
    app.bringIntoView(destroy)
    destroy.tap()
    XCTAssertTrue(
      app.navigationBars["Destroy your account"].appears(within: 5), "Destroy never opened")
    XCTAssertTrue(element("danger.destroy").exists, "Destroy has no Destroy account row")
    try captureBoard("rd-ios-acc-17-destroy")
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
    let pattern = /[0-9][0-9.,]*\s?(?:bytes|B|kB|KB|MB|GB|TB)/
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
    app.launchArguments += ["--putio-harness-continue-watching", "three"]
    launchAnalyticsPrompt()
    _ = element("files.continue-watching.item.442").appears(within: 10)
    try captureBoard("rd-ios-ses-25-ipad-analytics")
    let deny = app.buttons["analytics-prompt.deny"]
    deny.tap()
    if element("analytics-prompt.failure").appears(within: 5) { deny.tap() }
    XCTAssertTrue(element("analytics-prompt").disappears(within: 10), "the prompt stayed open")
    XCTAssertTrue(
      element("files.continue-watching.item.442").appears(within: 10),
      "Continue watching was not behind the prompt")
    assertEmptyFileDetail()
  }

  private func assertEmptyFileDetail() {
    XCTAssertTrue(
      element("putio.list-detail.empty").appears(within: 10),
      "the Files root has no detail column")
    XCTAssertTrue(app.staticTexts["No file selected"].exists, "the empty detail has no title")
    XCTAssertTrue(app.staticTexts["Tap a file to see it here."].exists)
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
    XCTAssertTrue(app.sortChoice("Size").appears(within: 5), "the sort menu has no Size field")
    XCTAssertTrue(app.sortChoice("Z to A").exists, "the sort menu has no Z to A order")
    XCTAssertTrue(app.sortChoice("Watched first").exists, "the sort menu has no video order")
    try captureBoard("rd-ios-acc-05-default-sort")
  }

  func testAccountResetSort() throws {
    openAccountSettings()
    let reset = element("settings.reset-sort")
    app.bringIntoView(reset)
    reset.tap()
    XCTAssertTrue(
      app.putioAlert("Reset all folder sorts?").appears(within: 5), "the reset alert never showed")
    try captureBoard("rd-ios-acc-23-reset-sort")
  }

  func testAccountTrashOff() throws {
    openAccountSettings()
    let trash = app.switches["settings.trash"]
    app.bringIntoView(trash)
    trash.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
    XCTAssertTrue(
      app.putioAlert("Turn off trash?").appears(within: 5), "the trash alert never showed")
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
      app.putioAlert("Turn off resume?").appears(within: 5), "the resume alert never showed")
    try captureBoard("rd-ios-acc-60-resume-off-confirm")
  }

  func testAccountPrivacy() throws {
    openAccountSettings()
    let privacy = app.revealed("account.privacy")
    XCTAssertTrue(privacy.appears(within: 5))
    privacy.tap()
    XCTAssertTrue(
      app.switches["privacy.diagnostics"].appears(within: 5), "Privacy controls never opened")
    app.showTabBar()
    let downloads = tabButton("Downloads")
    XCTAssertTrue(downloads.becomesHittable(within: 5), "the tab bar stayed minimized")
    XCTAssertTrue(holdsFrame(downloads, within: 5), "the tab bar never settled")
    try captureBoard("rd-ios-acc-08-privacy")
  }

  func testAccountAppInfo() throws {
    openAppInfo()
    try captureBoard("rd-ios-acc-09-app-info")
  }

  func testAccountAppInfoCopied() throws {
    openAppInfo()
    app.buttons["app-info.copy"].tap()
    XCTAssertTrue(
      app.staticTexts["Copied to clipboard"].appears(within: 5), "the copied toast never showed")
    try captureBoard("rd-ios-acc-34-app-info-copied")
  }

  func testAccountLicenses() throws {
    openAccountSettings()
    let licenses = app.revealed("account.licenses")
    XCTAssertTrue(licenses.appears(within: 5))
    licenses.tap()
    XCTAssertTrue(
      element("licenses.notice").appears(within: 5), "Open source licenses never opened")
    showSettledTabBar()
    try captureBoard("rd-ios-acc-10-licenses")
  }

  private func openAppInfo() {
    openAccountSettings()
    let about = app.revealed("account.about")
    XCTAssertTrue(about.appears(within: 5))
    about.tap()
    XCTAssertTrue(app.buttons["app-info.copy"].appears(within: 5), "App info never opened")
    showSettledTabBar()
  }

  private func showSettledTabBar() {
    app.showTabBar()
    let downloads = tabButton("Downloads")
    XCTAssertTrue(downloads.becomesHittable(within: 5), "the tab bar stayed minimized")
    XCTAssertTrue(holdsFrame(downloads, within: 5), "the tab bar never settled")
  }

  func testAccountHistoryOff() throws {
    openAccountSettings()
    scrollAccount(untilNearTop: "playback-settings.subtitles")
    let history = app.switches["settings.history"]
    app.bringIntoView(history)
    history.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
    XCTAssertTrue(
      app.putioAlert("Turn off history?").appears(within: 5), "the history alert never showed")
    try captureBoard("rd-ios-acc-25-history-off")
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

  func testPlaybackResume() throws {
    app.launch()
    openSeasonFolder()
    let episode = element("files.item.442")
    XCTAssertTrue(episode.appears(within: 10), "the partly watched episode never appeared")
    episode.tap()
    let play = element("files.detail.play")
    if play.appears(within: 3) { play.tap() }
    XCTAssertTrue(
      app.putioAlert("Resume from 21:00?").appears(within: 10),
      "the episode never asked where to start")
    XCTAssertTrue(app.buttons["video.resume.start-over"].exists, "the prompt has no Start over")
    XCTAssertTrue(app.buttons["video.resume.resume"].exists, "the prompt has no Resume")
    XCTAssertFalse(element("video.done").exists, "the player opened before the answer")
    try captureBoard("rd-ios-pb-01-resume")
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
      app.putioAlert("That proxy isn’t available for your account.").appears(within: 10),
      "the refused proxy showed no alert")
    try captureBoard("rd-ios-acc-33-proxy-unavailable")
  }

  func testAccountPublicLinks() throws {
    openPublicLinks("ready")
    XCTAssertTrue(element("public-links.item.903").appears(within: 10), "links never loaded")
    XCTAssertFalse(element("public-links.item.904").exists, "an expired link is listed")
    showSettledTabBar()
    try captureBoard("rd-ios-acc-12-links")
  }

  func testAccountPublicLinksEmpty() throws {
    openPublicLinks("empty")
    XCTAssertTrue(element("public-links.empty").appears(within: 10), "links never read empty")
    showSettledTabBar()
    try captureBoard("rd-ios-acc-11-links-empty")
  }

  func testAccountPublicLinksLoading() throws {
    openPublicLinks("slow")
    XCTAssertTrue(element("public-links.loading").appears(within: 5), "links never loaded")
    try captureBoard("rd-ios-acc-38-links-loading")
  }

  func testAccountPublicLinksFailed() throws {
    openPublicLinks("failing")
    XCTAssertTrue(app.buttons["public-links.retry"].appears(within: 10), "links never failed")
    showSettledTabBar()
    try captureBoard("rd-ios-acc-39-links-failed")
  }

  func testAccountPublicLinkMenu() throws {
    openPublicLinks("ready")
    let sintel = element("public-links.item.902")
    XCTAssertTrue(sintel.appears(within: 10), "links never loaded")
    showSettledTabBar()
    sintel.press(forDuration: 1.2)
    XCTAssertTrue(publicLinkAction("Copy link").appears(within: 5), "long press opened no menu")
    try captureBoard("rd-ios-acc-35-links-menu")
  }

  func testAccountPublicLinkSwipe() throws {
    openPublicLinks("ready")
    let sintel = element("public-links.item.902")
    XCTAssertTrue(sintel.appears(within: 10), "links never loaded")
    showSettledTabBar()
    sintel.swipeLeft()
    XCTAssertTrue(
      app.buttons["public-links.swipe-revoke"].appears(within: 5), "swipe showed no Revoke")
    try captureBoard("rd-ios-acc-36-links-swipe")
  }

  func testAccountPublicLinkRevoke() throws {
    openPublicLinks("ready")
    let sintel = element("public-links.item.902")
    XCTAssertTrue(sintel.appears(within: 10), "links never loaded")
    showSettledTabBar()
    sintel.tap()
    let revoke = publicLinkAction("Revoke")
    XCTAssertTrue(revoke.appears(within: 5), "a tap opened no menu")
    revoke.tap()
    XCTAssertTrue(
      app.putioAlert("Revoke this link?").appears(within: 5), "the revoke alert never showed")
    try captureBoard("rd-ios-acc-37-links-revoke")
  }

  func testIPadAccount() throws {
    openIPadAccount()
    XCTAssertTrue(
      element("putio.list-detail.empty").appears(within: 5), "a screen opened before a row")
    XCTAssertFalse(element("account.public-links").isSelected, "a row is open before a tap")
    try captureBoard("rd-ios-acc-57-ipad-account")
  }

  func testIPadAccountPrivacy() throws {
    openIPadAccount()
    let privacy = scrollIPadAccount(toHit: "account.privacy")
    privacy.tap()
    XCTAssertTrue(
      app.switches["privacy.diagnostics"].appears(within: 5), "Privacy controls never opened")
    assertIPadAccountOpen("account.privacy", "opening Privacy controls")
    try captureBoard("rd-ios-acc-18-ipad-privacy")
  }

  func testIPadAccountProxyKeepsScreenAcrossRotation() throws {
    app.launchArguments += ["--putio-harness-proxy", "ready"]
    openIPadAccount()
    let proxy = scrollIPadAccount(toHit: "playback-settings.route")
    proxy.tap()
    XCTAssertTrue(proxyChoice("Washington, D.C.").appears(within: 10), "proxies never loaded")
    assertIPadAccountOpen("playback-settings.route", "opening Proxy")
    rotate(.portrait)
    XCTAssertTrue(
      app.navigationBars["Choose your proxy"].appears(within: 5), "portrait closed Proxy")
    XCTAssertTrue(
      element("playback-settings.route").becomesUnhittable(within: 5),
      "portrait kept the Account list beside Proxy")
    rotate(.landscapeLeft)
    XCTAssertTrue(proxyChoice("Washington, D.C.").appears(within: 10), "landscape closed Proxy")
    if element("shell.storage").becomesHittable(within: 3) {
      sidebarToggle().tap()
      XCTAssertTrue(
        element("shell.storage").becomesUnhittable(within: 5), "the tab sidebar did not close")
    }
    assertIPadAccountOpen("playback-settings.route", "rotating back to landscape")
    try captureBoard("rd-ios-acc-20-ipad-proxy")
  }

  func testIPadAccountClearData() throws {
    openIPadAccount()
    let clear = scrollIPadAccount(toHit: "account.clear-data")
    clear.tap()
    XCTAssertTrue(
      element("danger.clear.files").appears(within: 5), "Clear your data never opened")
    selectClearCategories()
    assertIPadAccountOpen("account.clear-data", "opening Clear your data")
    try captureBoard("rd-ios-acc-58-ipad-danger")
  }

  func testIPadAccountScreen() throws {
    let identifier = try XCTUnwrap(
      ProcessInfo.processInfo.environment["PUTIO_IPAD_ACCOUNT_ROW"], "no Account row to open")
    openIPadAccount()
    let row = scrollIPadAccount(toHit: identifier)
    row.tap()
    XCTAssertTrue(
      element("putio.list-detail.empty").disappears(within: 5), "\(identifier) never opened")
    assertIPadAccountOpen(identifier, "opening \(identifier)")
    try captureBoard("ipad-account-screen")
  }

  private func openIPadAccount() {
    orient(.landscapeLeft)
    app.launch()
    reachFilesRoot()
    tabButton("Account").tap()
    XCTAssertTrue(element("account.profile").appears(within: 10), "Account never opened")
    XCTAssertTrue(
      element("settings.default-sort").appears(within: 15), "account settings never loaded")
  }

  private func scrollIPadAccount(toHit identifier: String) -> XCUIElement {
    let target = element(identifier)
    var steps = 0
    while !(target.exists && target.isHittable), steps < 12 {
      let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.15, dy: 0.8))
      let end = app.coordinate(withNormalizedOffset: CGVector(dx: 0.15, dy: 0.45))
      start.press(forDuration: 0.05, thenDragTo: end, withVelocity: .slow, thenHoldForDuration: 0.3)
      steps += 1
    }
    XCTAssertTrue(target.isHittable, "\(identifier) never scrolled into the list column")
    XCTAssertTrue(holdsFrame(target, within: 5), "the Account list never stopped scrolling")
    return target
  }

  private func assertIPadAccountOpen(_ identifier: String, _ step: String) {
    let row = element(identifier)
    XCTAssertTrue(row.appears(within: 5), "the Account list is hidden after \(step)")
    XCTAssertTrue(row.becomesHittable(within: 5), "the open row is off screen after \(step)")
    XCTAssertTrue(row.isSelected, "the open row is not selected after \(step)")
    XCTAssertTrue(holdsFrame(row, within: 5), "the open row never settled after \(step)")
    let closedRow = Self.iPadAccountRows.lazy.filter { $0 != identifier }.map { self.element($0) }
      .first {
        $0.exists && $0.isHittable && self.isClearOfListEdges($0)
      }
    if let closedRow {
      XCTAssertGreaterThan(
        Self.fillLuminance(of: row), Self.fillLuminance(of: closedRow) + Self.openRowFillGain,
        "the open row has no lighter fill than \(closedRow.identifier) after \(step)")
    } else {
      XCTFail("no closed Account row is in view to compare with after \(step)")
    }
    let window = app.windows.firstMatch.frame
    XCTAssertLessThan(
      row.frame.maxX, window.midX, "the Account list is not the left column after \(step)")
  }

  private static let openRowFillGain = 0.02

  private static let iPadAccountRows = [
    "account.public-links", "account.trash", "playback-settings.method",
    "playback-settings.route", "account.chromecast", "account.downloads", "account.privacy",
    "security.apps", "security.link-device", "account.two-factor", "account.about",
    "account.licenses", "account.clear-data", "account.destroy-account",
  ]

  private func isClearOfListEdges(_ row: XCUIElement) -> Bool {
    let window = app.windows.firstMatch.frame
    return row.frame.minY > window.minY + window.height * 0.25
      && row.frame.maxY < window.maxY - window.height * 0.08
  }

  private static func fillLuminance(of row: XCUIElement) -> Double {
    guard let image = row.screenshot().image.cgImage else { return 0 }
    let patch = CGRect(x: image.width - 8, y: image.height / 5, width: 6, height: 6)
    guard let corner = image.cropping(to: patch) else { return 0 }
    let side = 6
    var pixels = [UInt8](repeating: 0, count: side * side * 4)
    let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
      guard
        let context = CGContext(
          data: buffer.baseAddress, width: side, height: side, bitsPerComponent: 8,
          bytesPerRow: side * 4, space: CGColorSpaceCreateDeviceRGB(),
          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
      else { return false }
      context.draw(corner, in: CGRect(x: 0, y: 0, width: side, height: side))
      return true
    }
    guard drawn else { return 0 }
    var total = 0.0
    for offset in stride(from: 0, to: pixels.count, by: 4) {
      total +=
        0.2126 * Double(pixels[offset]) + 0.7152 * Double(pixels[offset + 1]) + 0.0722
        * Double(pixels[offset + 2])
    }
    return total / Double(side * side) / 255
  }

  private func openPublicLinks(_ mode: String) {
    app.launchArguments += ["--putio-harness-public-links", mode]
    openAccount()
    let row = element("account.public-links")
    XCTAssertTrue(row.appears(within: 5), "Account has no Exclusive links row")
    row.tap()
    XCTAssertTrue(
      app.navigationBars["Exclusive links"].appears(within: 5), "Exclusive links never opened")
  }

  private func publicLinkAction(_ title: String) -> XCUIElement {
    app.buttons.matching(NSPredicate(format: "label == %@", title)).firstMatch
  }

  func testAccountApps() throws {
    openLoggedInApps()
    try captureBoard("rd-ios-acc-13-apps")
  }

  func testAccountAppsSwipe() throws {
    openLoggedInApps()
    let tv = element("security.app.42")
    tv.swipeLeft()
    XCTAssertTrue(
      app.buttons["security.app.revoke.42"].appears(within: 5), "the swipe showed no Revoke")
    try captureBoard("rd-ios-acc-40-apps-swipe")
  }

  func testAccountAppsRevokeFailed() throws {
    openLoggedInApps()
    element("security.app.42").swipeLeft()
    let revoke = app.buttons["security.app.revoke.42"]
    XCTAssertTrue(revoke.appears(within: 5), "the swipe showed no Revoke")
    revoke.tap()
    XCTAssertTrue(
      app.staticTexts["Check your connection and try again."].appears(within: 10),
      "the revoke never failed")
    XCTAssertTrue(revoke.disappears(within: 5), "the swipe stayed open")
    try captureBoard("rd-ios-acc-41-apps-revoke-failed")
  }

  func testAccountAppsSignOutOthers() throws {
    openLoggedInApps()
    let row = app.revealed("security.apps.sign-out-others")
    XCTAssertTrue(row.becomesHittable(within: 10), "the sign-out row is missing")
    row.tap()
    XCTAssertTrue(
      app.putioAlert("Sign out of all other apps?").appears(within: 5), "the alert never showed")
    try captureBoard("rd-ios-acc-13b-apps-confirm")
  }

  func testAccountLinkDevice() throws {
    let code = openLinkDevice()
    dismissKeyboard()
    XCTAssertEqual(code.value as? String, "X7K2QM")
    showSettledTabBar()
    try captureBoard("rd-ios-acc-49-link-device")
  }

  func testAccountLinkDeviceLinking() throws {
    app.launchArguments += ["--putio-harness-link-device", "hold"]
    let code = openLinkDevice()
    app.buttons["security.link-submit"].tap()
    XCTAssertTrue(code.wait(for: \.isEnabled, toEqual: false, timeout: 5), "linking never started")
    XCTAssertTrue(app.keyboards.firstMatch.disappears(within: 5), "the keyboard stayed up")
    showSettledTabBar()
    try captureBoard("rd-ios-acc-50-link-device-linking")
  }

  func testAccountLinkDeviceFailed() throws {
    let code = openLinkDevice()
    app.buttons["security.link-submit"].tap()
    XCTAssertTrue(element("security.link-failure").appears(within: 10), "the link never failed")
    XCTAssertTrue(app.keyboards.firstMatch.disappears(within: 5), "the keyboard stayed up")
    XCTAssertEqual(code.value as? String, "X7K2QM", "the rejected code was cleared")
    showSettledTabBar()
    try captureBoard("rd-ios-acc-51-link-device-failed")
  }

  func testAccountLinkDeviceLinked() throws {
    app.launchArguments += ["--putio-harness-link-device", "accept"]
    _ = openLinkDevice()
    dismissKeyboard()
    showSettledTabBar()
    app.buttons["security.link-submit"].tap()
    XCTAssertTrue(app.putioAlert("Connected").appears(within: 10), "the link never connected")
    try captureBoard("rd-ios-acc-52-link-device-linked")
  }

  func testAccountClearData() throws {
    openClearData()
    selectClearCategories()
    showClearDataTabBar()
    try captureBoard("rd-ios-acc-15-clear")
  }

  func testAccountClearDataConfirm() throws {
    openClearData()
    selectClearCategories()
    showClearDataTabBar()
    tapClear()
    XCTAssertTrue(
      app.putioAlert("Clear the selected data?").appears(within: 5), "the confirm never showed")
    try captureBoard("rd-ios-acc-16-clear-confirm")
  }

  func testAccountClearDataNone() throws {
    openClearData()
    XCTAssertFalse(app.buttons["danger.clear"].isEnabled, "Clear was enabled with no selection")
    showClearDataTabBar()
    try captureBoard("rd-ios-acc-53-clear-none")
  }

  func testAccountClearDataProgress() throws {
    app.launchArguments += ["--putio-harness-clear-data", "hold"]
    confirmClearData()
    XCTAssertTrue(
      app.buttons["danger.clear.files"].wait(for: \.isEnabled, toEqual: false, timeout: 5),
      "clearing never started")
    showClearDataTabBar()
    try captureBoard("rd-ios-acc-54-clear-progress")
  }

  func testAccountClearDataDone() throws {
    app.launchArguments += ["--putio-harness-clear-data", "accept"]
    confirmClearData()
    XCTAssertTrue(element("danger.clear-success").appears(within: 10), "clearing never finished")
    showClearDataTabBar()
    try captureBoard("rd-ios-acc-55-clear-done")
  }

  func testAccountClearDataFailed() throws {
    confirmClearData()
    XCTAssertTrue(element("danger.clear-failure").appears(within: 10), "clearing never failed")
    showClearDataTabBar()
    try captureBoard("rd-ios-acc-56-clear-failed")
  }

  private func openClearData() {
    app.launchArguments.append("--putio-harness-account-security")
    openAccount()
    let row = app.revealed("account.clear-data", maximumSwipes: 8)
    app.bringIntoView(row)
    XCTAssertTrue(row.becomesHittable(within: 10), "Account has no Clear your data row")
    row.tap()
    XCTAssertTrue(
      app.navigationBars["Clear your data"].appears(within: 5), "Clear your data never opened")
    XCTAssertTrue(app.buttons["danger.clear.files"].appears(within: 5), "the checklist is missing")
  }

  private func selectClearCategories() {
    for category in ["files", "history", "trash"] {
      let row = app.buttons["danger.clear.\(category)"]
      app.bringIntoView(row)
      row.tap()
      XCTAssertTrue(row.isSelected, "\(category) was not checked")
    }
  }

  private func showClearDataTabBar() {
    let downloads = tabButton("Downloads")
    var swipes = 0
    while !downloads.isHittable, swipes < 4 {
      if swipes.isMultiple(of: 2) {
        app.swipeDown()
      } else {
        let top = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.3))
        let bottom = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.7))
        bottom.press(
          forDuration: 0.05, thenDragTo: top, withVelocity: .slow, thenHoldForDuration: 0)
        top.press(
          forDuration: 0.05, thenDragTo: bottom, withVelocity: .slow, thenHoldForDuration: 0.3)
      }
      swipes += 1
    }
    XCTAssertTrue(downloads.becomesHittable(within: 5), "the tab bar stayed minimized")
    XCTAssertTrue(holdsFrame(downloads, within: 5), "the tab bar never settled")
  }

  private func tapClear() {
    let clear = app.buttons["danger.clear"]
    app.bringIntoView(clear)
    clear.tap()
  }

  private func confirmClearData() {
    openClearData()
    selectClearCategories()
    tapClear()
    XCTAssertTrue(
      app.putioAlert("Clear the selected data?").appears(within: 5), "the confirm never showed")
    app.buttons["confirm-alert.confirm"].firstMatch.tap()
  }

  private func dismissKeyboard() {
    app.swipeDown()
    XCTAssertTrue(app.keyboards.firstMatch.disappears(within: 5), "the keyboard stayed up")
  }

  private func openLinkDevice() -> XCUIElement {
    app.launchArguments.append("--putio-harness-account-security")
    openAccount()
    let row = app.revealed("security.link-device")
    app.bringIntoView(row)
    XCTAssertTrue(row.becomesHittable(within: 10), "Account has no Link a device row")
    row.tap()
    XCTAssertTrue(
      app.navigationBars["Link a device"].appears(within: 5), "Link a device never opened")
    let code = app.textFields["security.link-code"]
    XCTAssertTrue(code.becomesHittable(within: 5), "the code field is missing")
    code.tap()
    code.typeText("x7k2qm")
    return code
  }

  private func openLoggedInApps() {
    app.launchArguments.append("--putio-harness-account-security")
    openAccountSettings()
    let apps = app.revealed("security.apps")
    XCTAssertTrue(apps.appears(within: 5))
    apps.tap()
    XCTAssertTrue(
      app.navigationBars["Logged-in apps"].appears(within: 5), "Logged-in apps never opened")
    XCTAssertTrue(element("security.app.44").appears(within: 10), "the apps never loaded")
    XCTAssertTrue(
      app.staticTexts["Used on Oct 30, 2026"].appears(within: 5), "the dates never loaded")
    app.showTabBar()
    let downloads = tabButton("Downloads")
    XCTAssertTrue(downloads.becomesHittable(within: 5), "the tab bar stayed minimized")
    XCTAssertTrue(holdsFrame(downloads, within: 5), "the tab bar never settled")
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
    let signOut = app.descendants(matching: .any)["auth.sign-out"]
    let list = app.collectionViews.firstMatch
    var swipes = 0
    while !signOut.appears(within: 3), swipes < 6 {
      if list.exists { list.swipeUp() } else { app.swipeUp() }
      swipes += 1
    }
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
    let folderScreens = [
      "files.screen.410", "files.screen.440", "files.screen.470", "files.screen.496",
    ].map(element)
    let signIn = element("auth.sign-in")
    let deadline = Date.now.addingTimeInterval(15)
    while !root.exists, !signIn.exists, !folderScreens.contains(where: \.exists),
      Date.now < deadline
    {
      _ = root.appears(within: 0.5)
    }
    if signIn.exists { signIn.tap() }
    for _ in folderScreens where !root.isHittable && folderScreens.contains(where: \.exists) {
      navigationBack().tap()
      _ = root.appears(within: 2)
    }
    XCTAssertTrue(root.appears(within: 15), "seeded session never reached Files")
  }

  private func navigationBack() -> XCUIElement {
    let backs = app.descendants(matching: .any).matching(identifier: "BackButton")
    let hittable = backs.allElementsBoundByIndex.last(where: \.isHittable)
    return hittable ?? app.navigationBars.buttons.firstMatch
  }

  private func tabButton(_ label: String) -> XCUIElement {
    app.buttons.matching(NSPredicate(format: "label == %@", label)).firstMatch
  }

  private func holdsFrame(_ element: XCUIElement, within timeout: TimeInterval) -> Bool {
    let deadline = Date.now.addingTimeInterval(timeout)
    var previous = element.frame
    while Date.now < deadline {
      RunLoop.current.run(until: Date.now.addingTimeInterval(0.3))
      let current = element.frame
      if current == previous { return true }
      previous = current
    }
    return false
  }

  private func openSidebar() {
    let toggle = sidebarToggle()
    XCTAssertTrue(toggle.appears(within: 5), "the top tabs have no sidebar button")
    toggle.tap()
    XCTAssertTrue(element("shell.storage").appears(within: 5), "the sidebar has no storage meter")
  }

  private func sidebarPin(_ id: Int) -> XCUIElement {
    element("shell.pinned.item.\(id)")
  }

  private func sidebarPins() -> [XCUIElement] {
    app.descendants(matching: .any)
      .matching(NSPredicate(format: "identifier BEGINSWITH %@", "shell.pinned.item."))
      .allElementsBoundByIndex
  }

  private func assertSidebarPins(
    _ ids: [Int], file: StaticString = #filePath, line: UInt = #line
  ) {
    XCTAssertTrue(
      labeled("Pinned").appears(within: 10), "the sidebar has no Pinned section",
      file: file, line: line)
    let rows = ids.map(sidebarPin)
    for (id, row) in zip(ids, rows) {
      XCTAssertTrue(row.appears(within: 10), "sidebar pin \(id) is missing", file: file, line: line)
    }
    let tops = rows.map(\.frame.minY)
    XCTAssertEqual(tops, tops.sorted(), "sidebar pins are out of order", file: file, line: line)
    XCTAssertEqual(
      Set(sidebarPins().map(\.identifier)).count, ids.count, "the sidebar lists other pins",
      file: file, line: line)
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

  private func captureFolderFailure(fault: String, reason: String, board: String) throws {
    orientForBoardDevice()
    app.launchArguments += ["--putio-harness-folder-fault", "\(fault),\(fault),\(fault)@440"]
    app.launch()
    openRoot()
    openHarnessFolder()
    let season = element("files.item.440")
    XCTAssertTrue(season.appears(within: 10), "seeded season folder never appeared")
    season.tap()
    XCTAssertTrue(
      app.staticTexts["Couldn’t load this"].appears(within: 10), "the folder never failed")
    XCTAssertTrue(app.staticTexts[reason].exists, "the failure names the wrong reason")
    XCTAssertTrue(element("files.retry.440").exists, "the failure offers no Try again")
    try captureBoard(board)
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
    tapFolderMore()
    XCTAssertTrue(
      app.buttons["New folder"].appears(within: 5), "More never listed New folder")
  }

  private func tapFolderMore() {
    let menu = app.buttons["files.menu"]
    if menu.appears(within: 10) { return menu.tap() }
    let overflow = app.buttons["BottomOverflowBarButtonItem"]
    XCTAssertTrue(overflow.exists, "the folder has no More menu")
    overflow.tap()
    let more = app.collectionViews.buttons["More"]
    XCTAssertTrue(more.appears(within: 5), "the toolbar overflow has no More")
    more.tap()
  }

  private func select(_ identifiers: [String]) {
    tapFolderMore()
    let start = app.buttons["Select"].firstMatch
    XCTAssertTrue(start.appears(within: 5), "More has no Select")
    start.tap()
    XCTAssertTrue(element("selection.bar").appears(within: 5), "the selection bar never appeared")
    for identifier in identifiers {
      let row = element(identifier)
      XCTAssertTrue(row.appears(within: 5), "\(identifier) never appeared")
      row.tap()
      XCTAssertEqual(row.value as? String, "Selected", "\(identifier) did not select")
    }
    XCTAssertTrue(
      app.staticTexts["\(identifiers.count) selected"].exists, "the header miscounts the selection")
  }

  private func assertSelectionBar(_ actions: [String]) {
    let shown = app.buttons.matching(
      NSPredicate(format: "identifier BEGINSWITH %@", "selection.action.")
    ).allElementsBoundByIndex.map(\.identifier)
    XCTAssertEqual(shown, actions.map { "selection.action.\($0)" })
  }

  private func openRename() -> XCUIElement {
    openItemMenu("files.item.445")
    app.buttons["Rename"].firstMatch.tap()
    let alert = app.putioAlert("Rename")
    XCTAssertTrue(alert.appears(within: 5), "Rename never opened")
    XCTAssertTrue(app.keyboards.firstMatch.appears(within: 5), "the name field never took focus")
    return alert
  }

  private func captureBoard(_ defaultBoard: String) throws {
    let board = ProcessInfo.processInfo.environment["PUTIO_BOARD_ID"] ?? defaultBoard
    try requireBoardDevicePosture()
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
    if ProcessInfo.processInfo.environment["PUTIO_BOARD_TEXT_AUDIT"] == "1" {
      try app.performAccessibilityAudit(for: .textClipped) { issue in
        guard let element = issue.element else { return false }
        if element.elementType == .searchField { return true }
        return
          (Self.isMiddleTruncatedFileName(element.label) || Self.containsEmoji(element.label))
          && element.frame.height >= Self.minimumXXLargeLineHeight
      }
    }
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
    let environment = ProcessInfo.processInfo.environment
    guard environment["PUTIO_BOARD_DEVICE"] != "duo-open" else { return }
    switch environment["PUTIO_BOARD_ORIENTATION"] {
    case "portrait": XCUIDevice.shared.orientation = .portrait
    case "landscape": XCUIDevice.shared.orientation = .landscapeLeft
    default: XCUIDevice.shared.orientation = orientation
    }
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

  private static func containsEmoji(_ label: String?) -> Bool {
    label?.unicodeScalars.contains { $0.properties.isEmojiPresentation || $0.value == 0xFE0F }
      ?? false
  }

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
