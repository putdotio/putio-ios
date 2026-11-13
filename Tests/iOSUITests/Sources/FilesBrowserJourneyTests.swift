import XCTest

final class FilesBrowserJourneyTests: XCTestCase {
  private var app: XCUIApplication!
  private let toastDuration: TimeInterval = 5

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
    XCTAssertTrue(signIn.appears(within: 10), "sign-in screen never appeared")
    let root = element(identifier: "files.screen.0")
    addScreenshot(named: "runtime-sign-in")

    XCTAssertTrue(signIn.isHittable, "sign-in action is not tappable")
    signIn.tap()
    XCTAssertTrue(root.appears(within: 10), "signed-in root browser never appeared")

    let rootVideo = element(identifier: "files.item.412")
    let done = element(identifier: "video.done")
    XCTAssertEqual(rootVideo.value as? String, "Watched, resume at \(resumeText(seconds: 560))")
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
    XCTAssertTrue(done.appears(within: 5), "root video screen never appeared")
    let playbackError = element(identifier: "video.error")
    XCTAssertTrue(
      playbackError.appears(within: 5),
      "invalid playback fixture did not produce a recoverable failure"
    )
    let retry = app.buttons["Try again"]
    XCTAssertTrue(retry.isHittable, "playback retry is not tappable")
    retry.tap()
    XCTAssertTrue(
      element(identifier: "video.ready").appears(within: 10),
      "root video never became ready near EOF"
    )
    let nextTitle = element(identifier: "video.next-title")
    XCTAssertTrue(nextTitle.appears(within: 45), "next-video suggestion never appeared")
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
      element(identifier: "video.ended").appears(within: 5),
      "root video never reached EOF"
    )
    let reportedPosition = element(identifier: "video.position-reported")
    let endSeconds = reportedSeconds(of: 412, from: reportedPosition.value as? String)
    XCTAssertGreaterThanOrEqual(
      endSeconds ?? -1, 589,
      "next-video suggestion appeared before the watched end position drained"
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

    XCTAssertTrue(root.appears(within: 5), "successor video did not return to root")
    let watchedRow = XCTNSPredicateExpectation(
      predicate: NSPredicate(
        format: "value == %@", "Watched, resume at \(resumeText(seconds: endSeconds ?? -1))"),
      object: rootVideo
    )
    XCTAssertEqual(
      XCTWaiter.wait(for: [watchedRow], timeout: 5),
      .completed,
      "root row did not show the watched mark after EOF"
    )

    let account = app.buttons["Account"]
    XCTAssertTrue(account.isHittable, "Account tab is not tappable")
    account.tap()
    let signOut = app.revealed("auth.sign-out")
    XCTAssertTrue(signOut.appears(within: 5), "sign-out action never appeared")
    if !signOut.isHittable { app.swipeUp() }
    XCTAssertTrue(
      waitUntilHittable(signOut, timeout: 5), "sign-out action is not tappable")
    signOut.tap()
    app.confirmSignOut()

    XCTAssertTrue(signIn.appears(within: 10), "sign-out did not return to sign-in")
    addScreenshot(named: "runtime-signed-out")
  }

  func testFolderHeadersCountItemsAndBackKeepsTheParentPlace() {
    app.launch()
    let signIn = element(identifier: "auth.sign-in")
    XCTAssertTrue(signIn.appears(within: 10), "sign-in screen never appeared")
    signIn.tap()
    XCTAssertTrue(element(identifier: "files.screen.0").appears(within: 10))
    XCTAssertFalse(element(identifier: "files.header.0").exists, "the root drew a folder header")

    let harnessRow = element(identifier: "files.item.410")
    XCTAssertTrue(harnessRow.appears(within: 10), "seeded folder never appeared")
    let rootPlace = harnessRow.frame
    harnessRow.tap()
    let harnessHeader = element(identifier: "files.header.410")
    XCTAssertTrue(harnessHeader.appears(within: 10), "the folder has no header")
    XCTAssertTrue(harnessHeader.label.hasPrefix("2 items"), harnessHeader.label)

    let seasonRow = element(identifier: "files.item.440")
    XCTAssertTrue(seasonRow.appears(within: 5), "nested folder row never appeared")
    let parentPlace = seasonRow.frame
    seasonRow.tap()
    let seasonHeader = element(identifier: "files.header.440")
    XCTAssertTrue(seasonHeader.appears(within: 10), "the nested folder has no header")
    XCTAssertEqual(seasonHeader.label, "6 items, 13.1 GB")
    XCTAssertTrue(
      (element(identifier: "files.item.442").value as? String)?.hasPrefix("Watched") == true,
      "the watched episode is not reported as watched")
    addScreenshot(named: "runtime-folder-header")

    app.navigationBars.buttons["BackButton"].tap()
    XCTAssertTrue(seasonRow.appears(within: 5), "back did not return to the parent folder")
    XCTAssertEqual(seasonRow.frame, parentPlace, "back moved the parent folder's rows")
    app.navigationBars.buttons["BackButton"].tap()
    XCTAssertTrue(harnessRow.appears(within: 5), "back did not return to the root")
    XCTAssertEqual(harnessRow.frame, rootPlace, "back moved the root's rows")

    app.buttons["Account"].tap()
    let signOut = app.revealed("auth.sign-out")
    XCTAssertTrue(signOut.appears(within: 5), "sign-out action never appeared")
    if !signOut.isHittable { app.swipeUp() }
    XCTAssertTrue(waitUntilHittable(signOut, timeout: 5), "sign-out action is not tappable")
    signOut.tap()
    app.confirmSignOut()
    XCTAssertTrue(signIn.appears(within: 10), "sign-out did not return to sign-in")
  }

  func testItemMenusSwipesAndWatchStatus() {
    app.launch()
    openSeasonFolder()

    let unwatched = element(identifier: "files.item.443")
    XCTAssertEqual(
      itemMenu(for: unwatched),
      [
        "Play", "Download", "Select", "Mark as watched", "Rename", "Move", "Exclusive link",
        "Move to trash",
      ])
    app.buttons["Mark as watched"].tap()
    XCTAssertTrue(app.staticTexts["Marked as watched"].appears(within: 5), "no watched toast")
    XCTAssertTrue(
      waitForValuePrefix(unwatched, "Watched"), "the eye did not follow Mark as watched")

    let watched = element(identifier: "files.item.442")
    XCTAssertEqual(
      itemMenu(for: watched),
      [
        "Play", "Download", "Select", "Mark as unwatched", "Rename", "Move", "Exclusive link",
        "Move to trash",
      ])
    app.buttons["Mark as unwatched"].tap()
    XCTAssertTrue(
      app.staticTexts["Could not update watch status"].appears(within: 5),
      "the seeded watch-status failure was not reported")
    XCTAssertTrue(
      waitForValuePrefix(watched, "Watched"), "the eye did not roll back after the failure")
    XCTAssertEqual(
      itemMenu(for: watched).filter { $0.hasPrefix("Mark") }, ["Mark as unwatched"])
    app.buttons["Mark as unwatched"].tap()
    XCTAssertTrue(app.staticTexts["Marked as unwatched"].appears(within: 5))
    XCTAssertTrue(waitForValuePrefix(watched, "Not watched"), "the eye stayed after unwatched")

    let subtitle = element(identifier: "files.item.445")
    XCTAssertEqual(
      itemMenu(for: subtitle), ["Select", "Rename", "Move", "Exclusive link", "Move to trash"])
    dismissMenu()
    XCTAssertTrue(app.buttons["Rename"].disappears(within: 5))

    let episode = element(identifier: "files.item.441")
    episode.swipeLeft()
    let more = swipeMore(beside: episode)
    XCTAssertTrue(more.appears(within: 5), "the left swipe has no More")
    XCTAssertTrue(app.buttons["Download"].exists, "the left swipe has no Download")
    XCTAssertTrue(app.buttons["Move to trash"].exists, "the left swipe has no Trash")
    addScreenshot(named: "runtime-item-swipe-left")
    more.tap()
    XCTAssertEqual(
      menuLabels(),
      [
        "Play", "Download", "Select", "Mark as watched", "Rename", "Move", "Exclusive link",
        "Move to trash",
      ])
    dismissMenu()
    XCTAssertTrue(app.buttons["Rename"].disappears(within: 5))

    app.navigationBars.buttons["BackButton"].tap()
    let folder = element(identifier: "files.item.440")
    XCTAssertTrue(folder.appears(within: 5))
    XCTAssertEqual(
      itemMenu(for: folder), ["Select", "Rename", "Move", "Exclusive link", "Move to trash"])
    addScreenshot(named: "runtime-item-menu-folder")
    app.buttons["Select"].tap()
    XCTAssertTrue(
      waitForValuePrefix(folder, "Selected"), "Select did not start selection on the row")
    app.buttons["selection.close"].tap()
    XCTAssertTrue(waitUntilHittable(folder, timeout: 5))
    folder.swipeRight()
    let move = app.buttons["Move"]
    XCTAssertTrue(waitUntilHittable(move, timeout: 5), "the right swipe has no Move")
    addScreenshot(named: "runtime-item-swipe-right")
    move.tap()
    XCTAssertTrue(element(identifier: "files.move-picker").appears(within: 5))
    app.buttons["sheet.dismiss"].tap()
    XCTAssertTrue(element(identifier: "files.move-picker").disappears(within: 5))

    app.terminate()
    app.launchArguments.append("--putio-harness-vlc-installed")
    app.launch()
    openSeasonFolder()
    XCTAssertEqual(
      itemMenu(for: element(identifier: "files.item.444")),
      [
        "Play", "Download", "Open in VLC", "Select", "Mark as watched", "Rename", "Move",
        "Exclusive link",
        "Move to trash",
      ])
    addScreenshot(named: "runtime-item-menu-vlc")
    dismissMenu()
    let root = element(identifier: "files.screen.0")
    for _ in 0..<2 where !root.exists {
      app.navigationBars.buttons["BackButton"].tap()
      _ = root.appears(within: 3)
    }
    XCTAssertTrue(root.appears(within: 5), "Files never returned to its root")

    app.buttons["Account"].tap()
    let signOut = app.revealed("auth.sign-out")
    XCTAssertTrue(signOut.appears(within: 5), "sign-out action never appeared")
    if !signOut.isHittable { app.swipeUp() }
    XCTAssertTrue(waitUntilHittable(signOut, timeout: 5), "sign-out action is not tappable")
    signOut.tap()
    app.confirmSignOut()
    XCTAssertTrue(
      element(identifier: "auth.sign-in").appears(within: 10), "sign-out did not return to sign-in")
  }

  private static let itemMenuLabels = [
    "Play", "Download", "Open in VLC", "Cast", "Select", "Mark as watched", "Mark as unwatched",
    "Rename", "Move", "Exclusive link", "Move to trash",
  ]

  private func itemMenu(for row: XCUIElement) -> [String] {
    XCTAssertTrue(waitUntilHittable(row, timeout: 5), "row is not available for its menu")
    row.press(forDuration: 1)
    return menuLabels()
  }

  private func menuLabels() -> [String] {
    XCTAssertTrue(app.buttons["Rename"].appears(within: 5), "item menu never opened")
    return app.buttons.matching(NSPredicate(format: "label IN %@", Self.itemMenuLabels))
      .allElementsBoundByIndex
      .filter { $0.isHittable }
      .sorted { $0.frame.minY < $1.frame.minY }
      .map(\.label)
  }

  private func swipeMore(beside row: XCUIElement) -> XCUIElement {
    let identified = app.buttons["item-swipe.more"].firstMatch
    if identified.appears(within: 2) { return identified }
    let labelled = app.buttons.matching(
      NSPredicate(format: "label == %@ AND identifier != %@", "More", "files.menu"))
    return labelled.allElementsBoundByIndex.first { abs($0.frame.midY - row.frame.midY) < 30 }
      ?? labelled.firstMatch
  }

  func testMoveSheetLevelsNameTakenNewFolderAndIntoItself() {
    app.launch()
    openSeasonFolder()

    let subtitle = element(identifier: "files.item.445")
    openContextMenu(for: subtitle, actionLabel: "Move").tap()
    XCTAssertTrue(element(identifier: "files.move-screen.0").appears(within: 5))
    XCTAssertTrue(app.navigationBars["Move 1 item"].exists, "the sheet does not count its items")
    openMoveLevel(410, path: "Files / Harness Folder")
    let moveToHarness = app.buttons["Move to Harness Folder"]
    XCTAssertTrue(
      waitUntilHittable(moveToHarness, timeout: 5), "Move to Harness Folder is disabled")
    moveToHarness.tap()
    let moveError = element(identifier: "sheet.failure")
    XCTAssertTrue(moveError.appears(within: 10), "a taken name showed no error")
    XCTAssertEqual(
      moveError.label,
      "A file or folder named “Blue.Lights.S04E01.en.srt” already exists there. Choose another folder."
    )
    XCTAssertTrue(element(identifier: "files.move-picker").exists, "a taken name closed the sheet")
    addScreenshot(named: "runtime-move-name-taken")

    openMoveLevel(440, path: "Files / Harness Folder / Blue Lights")
    XCTAssertTrue(element(identifier: "files.move-empty.440").appears(within: 5))
    XCTAssertFalse(app.buttons["Move to Blue Lights"].isEnabled, "the current folder is a target")
    XCTAssertFalse(moveError.exists, "the taken name followed the sheet to another folder")

    let newFolder = app.buttons["files.move-new-folder"]
    XCTAssertTrue(waitUntilHittable(newFolder, timeout: 5))
    newFolder.tap()
    let alert = nameAlert("New folder")
    XCTAssertTrue(alert.staticTexts["In Blue Lights"].exists, "New folder does not name its level")
    submitName("Extras", in: alert, as: "Create")
    XCTAssertTrue(element(identifier: "files.move-folder.415").appears(within: 5))
    openMoveLevel(415, path: "Files / Harness Folder / Blue Lights / Extras")
    let moveToExtras = app.buttons["Move to Extras"]
    XCTAssertTrue(waitUntilHittable(moveToExtras, timeout: 5), "Move to Extras is disabled")
    moveToExtras.tap()
    XCTAssertTrue(element(identifier: "files.move-picker").disappears(within: 10))
    XCTAssertTrue(subtitle.disappears(within: 5), "the moved subtitle stayed in its folder")
    let movedToast = app.descendants(matching: .any)
      .matching(NSPredicate(format: "label == %@", "1 item is in the selected folder.")).firstMatch
    XCTAssertTrue(movedToast.appears(within: 10), "the move showed no toast")

    let extras = element(identifier: "files.item.415")
    XCTAssertTrue(waitUntilHittable(extras, timeout: 10), "the folder made in the sheet is missing")
    openContextMenu(for: extras, actionLabel: "Move").tap()
    XCTAssertTrue(element(identifier: "files.move-screen.0").appears(within: 5))
    openMoveLevel(410, path: "Files / Harness Folder")
    openMoveLevel(440, path: "Files / Harness Folder / Blue Lights")
    openMoveLevel(415, path: "Files / Harness Folder / Blue Lights / Extras")
    XCTAssertTrue(moveError.appears(within: 5), "moving a folder into itself showed no error")
    XCTAssertEqual(moveError.label, "A folder can’t be moved into itself or a folder inside it.")
    XCTAssertFalse(app.buttons["Move to Extras"].isEnabled, "a folder can move into itself")

    for _ in 0..<3 { tapSheetBack() }
    let cancel = app.buttons["sheet.dismiss"]
    XCTAssertTrue(waitUntilHittable(cancel, timeout: 5), "the sheet lost Cancel at Files")
    cancel.tap()
    XCTAssertTrue(element(identifier: "files.move-picker").disappears(within: 5))
    XCTAssertTrue(extras.exists, "cancelling the move removed its source")

    app.buttons["Account"].tap()
    let signOut = app.revealed("auth.sign-out")
    XCTAssertTrue(signOut.appears(within: 5), "sign-out action never appeared")
    signOut.tap()
    app.confirmSignOut()
    XCTAssertTrue(
      element(identifier: "auth.sign-in").appears(within: 10), "sign-out did not return to sign-in")
  }

  func testPinnedFilesPinUnpinSeeAllGoneFailureAndRelaunch() {
    launch(pins: "three")
    reachRoot()
    assertPins([440, 410, 412])
    XCTAssertTrue(app.staticTexts["in Harness Folder"].exists, "a pin does not name its folder")
    XCTAssertFalse(element(identifier: "files.pinned.see-all").exists, "three pins offered See all")
    addScreenshot(named: "runtime-pinned")

    let harness = element(identifier: "files.item.410")
    XCTAssertTrue(waitUntilHittable(harness, timeout: 5), "the root list lost its rows")
    harness.tap()
    let nested = element(identifier: "files.item.411")
    XCTAssertTrue(waitUntilHittable(nested, timeout: 10), "the folder never listed its video")
    openContextMenu(for: nested, actionLabel: "Pin").tap()
    _ = openContextMenu(for: nested, actionLabel: "Unpin")
    XCTAssertFalse(app.buttons["Pin"].exists, "the pinned video still offers Pin")
    app.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.7)).tap()
    XCTAssertTrue(app.buttons["Unpin"].disappears(within: 5), "the item menu never closed")
    tapSheetBack()
    reachRoot()
    assertPins([411, 440, 410, 412])

    openContextMenu(for: pin(412), actionLabel: "Unpin").tap()
    XCTAssertTrue(pin(412).disappears(within: 5), "Unpin left the row in the section")
    XCTAssertTrue(element(identifier: "files.item.412").exists, "Unpin touched All files")

    app.terminate()
    launch(pins: "keep")
    reachRoot()
    assertPins([411, 440, 410])

    app.terminate()
    launch(pins: "seven")
    reachRoot()
    assertPins([440, 410, 412, 411, 413])
    let seeAll = element(identifier: "files.pinned.see-all")
    XCTAssertTrue(waitUntilHittable(seeAll, timeout: 5), "seven pins offered no See all")
    seeAll.tap()
    XCTAssertTrue(element(identifier: "files.pinned-list").appears(within: 5))
    XCTAssertTrue(app.staticTexts["7 items"].appears(within: 5), "the list does not count pins")
    XCTAssertTrue(waitUntilHittable(pin(441), timeout: 5), "the list leaves out the last pin")
    openContextMenu(for: pin(441), actionLabel: "Unpin").tap()
    XCTAssertTrue(pin(441).disappears(within: 5), "Unpin left the row in the list")
    XCTAssertTrue(app.staticTexts["6 items"].appears(within: 5), "the count kept the unpinned row")
    addScreenshot(named: "runtime-pinned-list")
    tapSheetBack()
    reachRoot()
    XCTAssertTrue(seeAll.appears(within: 5), "six pins lost See all")

    app.terminate()
    launch(pins: "gone")
    reachRoot()
    assertPins([440, 412])
    XCTAssertFalse(pin(999).exists, "a pin whose file is gone was shown")

    app.terminate()
    launch(pins: "fail")
    reachRoot()
    XCTAssertTrue(
      element(identifier: "files.item.410").appears(within: 10), "failed pins blocked the list")
    XCTAssertFalse(
      element(identifier: "files.pinned").appears(within: 3), "failed pins drew the section")
  }

  private func launch(pins mode: String) {
    if let flag = app.launchArguments.firstIndex(of: "--putio-harness-pins") {
      app.launchArguments.removeSubrange(flag...(flag + 1))
    }
    app.launchArguments += ["--putio-harness-pins", mode]
    app.launch()
  }

  private func reachRoot() {
    let root = element(identifier: "files.screen.0")
    let signIn = element(identifier: "auth.sign-in")
    let back = app.navigationBars.buttons["BackButton"].firstMatch
    let deadline = Date.now.addingTimeInterval(20)
    while Date.now < deadline {
      if signIn.exists {
        signIn.tap()
      } else if root.exists, root.isHittable {
        break
      } else if back.exists {
        back.tap()
      }
      _ = root.waitForExistence(timeout: 0.5)
    }
    XCTAssertTrue(root.appears(within: 5), "the seeded session never reached the Files root")
  }

  private func pin(_ id: Int) -> XCUIElement {
    element(identifier: "files.pinned.item.\(id)")
  }

  private func assertPins(_ ids: [Int], file: StaticString = #filePath, line: UInt = #line) {
    XCTAssertTrue(
      element(identifier: "files.pinned").appears(within: 10), "the section never appeared",
      file: file, line: line)
    let rows = ids.map(pin)
    for (id, row) in zip(ids, rows) {
      XCTAssertTrue(row.appears(within: 10), "pin \(id) is missing", file: file, line: line)
    }
    let tops = rows.map(\.frame.minY)
    XCTAssertEqual(tops, tops.sorted(), "pins are out of order", file: file, line: line)
    let shown = app.descendants(matching: .any)
      .matching(NSPredicate(format: "identifier BEGINSWITH %@", "files.pinned.item."))
      .allElementsBoundByIndex.map(\.identifier)
    XCTAssertEqual(
      Set(shown), Set(ids.map { "files.pinned.item.\($0)" }), "the section shows other pins",
      file: file, line: line)
  }

  private func openMoveLevel(_ id: Int, path: String) {
    let row = element(identifier: "files.move-folder.\(id)")
    XCTAssertTrue(waitUntilHittable(row, timeout: 10), "move folder \(id) never appeared")
    row.tap()
    XCTAssertTrue(element(identifier: "files.move-screen.\(id)").appears(within: 5))
    XCTAssertTrue(app.staticTexts[path].appears(within: 5), "the level has no path \(path)")
  }

  private func tapSheetBack() {
    let back = app.navigationBars.buttons.matching(identifier: "BackButton")
      .allElementsBoundByIndex.first { $0.isHittable }
    XCTAssertNotNil(back, "the move sheet has no back control")
    back?.tap()
  }

  private func openSeasonFolder() {
    let signIn = element(identifier: "auth.sign-in")
    let harness = element(identifier: "files.item.410")
    let seasonRow = element(identifier: "files.item.440")
    let season = element(identifier: "files.screen.440")
    let deadline = Date.now.addingTimeInterval(15)
    while !signIn.exists, !harness.exists, !seasonRow.exists, !season.exists, Date.now < deadline {
      _ = season.appears(within: 0.5)
    }
    if signIn.exists { signIn.tap() }
    if !season.exists {
      if !seasonRow.exists {
        XCTAssertTrue(waitUntilHittable(harness, timeout: 10), "seeded folder never appeared")
        harness.tap()
      }
      XCTAssertTrue(waitUntilHittable(seasonRow, timeout: 10), "season folder never appeared")
      seasonRow.tap()
    }
    XCTAssertTrue(element(identifier: "files.header.440").appears(within: 10))
  }

  private func waitForValuePrefix(_ element: XCUIElement, _ prefix: String) -> Bool {
    let expectation = XCTNSPredicateExpectation(
      predicate: NSPredicate(format: "value BEGINSWITH %@", prefix), object: element)
    return XCTWaiter.wait(for: [expectation], timeout: 5) == .completed
  }

  func testSelectionBarFollowsTheSelectionAndSelectAllTakesLoadedRows() {
    app.launchArguments.append("--putio-harness-folder-states")
    app.launch()
    let signIn = element(identifier: "auth.sign-in")
    XCTAssertTrue(signIn.appears(within: 10), "sign-in screen never appeared")
    signIn.tap()
    XCTAssertTrue(element(identifier: "files.screen.0").appears(within: 10))

    beginSelection()
    XCTAssertEqual(selectionBar(), ["move", "trash"])
    XCTAssertFalse(app.buttons["selection.action.move"].isEnabled, "nothing selected can move")
    XCTAssertFalse(app.buttons["selection.action.trash"].isEnabled, "nothing selected can trash")
    toggle("files.item.412")
    XCTAssertEqual(selectionBar(), ["move", "download", "unwatched", "trash"])
    toggle("files.item.408")
    XCTAssertEqual(selectionBar(), ["move", "download", "trash"], "audio offered Watched")
    toggle("files.item.410")
    XCTAssertEqual(selectionBar(), ["move", "trash"], "a folder kept the playable actions")
    XCTAssertTrue(app.staticTexts["3 selected"].exists)
    addScreenshot(named: "runtime-selection-mixed")
    endSelection()

    let paging = element(identifier: "files.item.460")
    XCTAssertTrue(waitUntilHittable(paging, timeout: 10), "the paging folder never appeared")
    paging.tap()
    XCTAssertTrue(app.staticTexts["Paging File 001.txt"].appears(within: 10))
    beginSelection()
    app.buttons["selection.toggle-all"].tap()
    XCTAssertTrue(app.staticTexts["50 selected"].appears(within: 5), "Select all took other rows")
    let summary = element(identifier: "files.selection.summary")
    XCTAssertTrue(summary.label.hasPrefix("450 items"), summary.label)
    XCTAssertTrue(summary.label.contains("selected"), summary.label)
    addScreenshot(named: "runtime-selection-all-loaded")

    let failed = app.staticTexts["Couldn’t load more files."]
    XCTAssertTrue(scrollUntilShown(failed, swipes: 15), "page 2 never failed")
    let retry = element(identifier: "files.more-retry.460")
    XCTAssertTrue(waitUntilHittable(retry, timeout: 5), "the failed page has no Try again")
    retry.tap()
    let paged = element(identifier: "files.item.5051")
    XCTAssertTrue(paged.appears(within: 10), "Try again never appended page 2")
    XCTAssertEqual(paged.value as? String, "Not selected", "a paged row arrived selected")
    XCTAssertTrue(app.staticTexts["50 selected"].exists, "paging changed the selection")

    let last = element(identifier: "files.item.5050")
    XCTAssertTrue(scrollUntilShown(last, swipes: 5) || last.exists)
    toggle("files.item.5050", to: "Not selected")
    XCTAssertTrue(app.staticTexts["49 selected"].exists, "unticking kept the row selected")
    endSelection()
    beginSelection()
    XCTAssertTrue(app.staticTexts["0 selected"].exists, "closing kept the selection")
    endSelection()

    app.navigationBars.buttons["BackButton"].tap()
    XCTAssertTrue(element(identifier: "files.screen.0").appears(within: 5))
    signOutFromAccount()
  }

  func testSelectionBarWithTrashOffDeletesAndReportsPartialWatchedFailures() {
    app.launchArguments += [
      "--putio-harness-trash-disabled", "--putio-harness-watched-refusal",
    ]
    app.launch()
    openSeasonFolder()

    beginSelection()
    toggle("files.item.441")
    toggle("files.item.442")
    toggle("files.item.443")
    XCTAssertEqual(selectionBar(), ["move", "download", "watched", "trash"])
    let delete = app.buttons["selection.action.trash"]
    XCTAssertEqual(delete.label, "Delete")
    XCTAssertTrue(
      element(identifier: "files.selection.summary").label.contains("9.6 GB selected"),
      element(identifier: "files.selection.summary").label)
    addScreenshot(named: "runtime-selection-trash-off")
    delete.tap()
    let alert = app.putioAlert("Delete 3 items permanently?")
    XCTAssertTrue(alert.appears(within: 5), "Delete did not ask first")
    alert.buttons["Cancel"].firstMatch.tap()
    XCTAssertTrue(alert.disappears(within: 5))
    XCTAssertTrue(app.staticTexts["3 selected"].exists, "Cancel ended the selection")

    app.buttons["selection.action.watched"].tap()
    let failure = app.staticTexts["Couldn’t mark 1 item as watched."]
    XCTAssertTrue(failure.appears(within: 10), "the refused video was not reported")
    XCTAssertTrue(app.buttons["Try again"].exists, "the watched failure offers no Try again")
    XCTAssertTrue(waitForValuePrefix(element(identifier: "files.item.443"), "Not selected"))
    XCTAssertEqual(
      element(identifier: "files.item.441").value as? String, "Selected",
      "the refused video left the selection")
    XCTAssertTrue(app.staticTexts["1 selected"].exists)
    endSelection()
    XCTAssertTrue(
      waitForValuePrefix(element(identifier: "files.item.443"), "Watched"),
      "the accepted video did not turn watched")
    XCTAssertTrue(
      waitForValuePrefix(element(identifier: "files.item.441"), "Not watched"),
      "the refused video did not roll back")
  }

  func testBulkTrashUndoAndWatchedLeaveSelection() {
    app.launch()
    openSeasonFolder()
    let episodes = ["files.item.441", "files.item.442", "files.item.443"]

    beginSelection()
    for id in episodes { toggle(id) }
    app.buttons["selection.action.trash"].tap()
    XCTAssertTrue(
      app.staticTexts["Moved 3 items to trash"].appears(within: 10), "bulk Trash has no toast")
    XCTAssertTrue(
      element(identifier: "selection.bar").disappears(within: 5), "bulk Trash kept selection")
    for id in episodes {
      XCTAssertTrue(element(identifier: id).disappears(within: 5), "\(id) stayed after Trash")
    }
    addScreenshot(named: "runtime-bulk-trashed")
    let undo = app.buttons["Undo"]
    XCTAssertTrue(waitUntilHittable(undo, timeout: 5), "the bulk Trash toast has no Undo")
    undo.tap()
    for id in episodes {
      XCTAssertTrue(element(identifier: id).appears(within: 10), "Undo did not restore \(id)")
    }

    beginSelection()
    for id in episodes { toggle(id) }
    app.buttons["selection.action.watched"].tap()
    XCTAssertTrue(
      app.staticTexts["Marked as watched"].appears(within: 10), "bulk Watched has no toast")
    XCTAssertTrue(
      element(identifier: "selection.bar").disappears(within: 5), "bulk Watched kept selection")
    for id in episodes {
      XCTAssertTrue(waitForValuePrefix(element(identifier: id), "Watched"), "\(id) is not watched")
    }
  }

  private func beginSelection() {
    openBrowseMenu()
    let select = app.buttons["Select"].firstMatch
    XCTAssertTrue(waitUntilHittable(select, timeout: 5), "More has no Select")
    select.tap()
    XCTAssertTrue(element(identifier: "selection.bar").appears(within: 5), "no selection bar")
  }

  private func endSelection() {
    let close = app.buttons["selection.close"]
    XCTAssertTrue(waitUntilHittable(close, timeout: 5), "selection has no close button")
    close.tap()
    XCTAssertTrue(element(identifier: "selection.bar").disappears(within: 5), "the bar stayed")
  }

  private func toggle(_ identifier: String, to value: String = "Selected") {
    let row = element(identifier: identifier)
    XCTAssertTrue(waitUntilHittable(row, timeout: 5), "\(identifier) is not tappable")
    row.tap()
    XCTAssertTrue(waitForValuePrefix(row, value), "\(identifier) did not become \(value)")
  }

  private func selectionBar() -> [String] {
    app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "selection.action."))
      .allElementsBoundByIndex.map { String($0.identifier.dropFirst("selection.action.".count)) }
  }

  private func signOutFromAccount() {
    let account = app.buttons["Account"]
    let closeSearch = app.buttons["Close"]
    if closeSearch.exists { closeSearch.tap() }
    if !account.exists { app.buttons["Files"].tap() }
    XCTAssertTrue(account.appears(within: 5), "the tab bar stayed collapsed")
    account.tap()
    let signOut = app.revealed("auth.sign-out")
    XCTAssertTrue(signOut.appears(within: 5), "sign-out action never appeared")
    signOut.tap()
    app.confirmSignOut()
    XCTAssertTrue(element(identifier: "auth.sign-in").appears(within: 10))
  }

  func testFailedSignOutLandsOnWelcomeAndNeverRestoresOnRelaunch() {
    let failure = "--putio-harness-sign-out-failure"
    app.launchArguments += [failure, "--putio-harness-sign-out-seconds", "3"]
    app.launch()
    let signIn = element(identifier: "auth.sign-in")
    let root = element(identifier: "files.screen.0")
    XCTAssertTrue(signIn.appears(within: 10), "sign-in screen never appeared")
    signIn.tap()
    XCTAssertTrue(root.appears(within: 10), "signed-in root browser never appeared")
    app.buttons["Account"].tap()
    let signOut = app.revealed("auth.sign-out")
    XCTAssertTrue(signOut.appears(within: 5), "sign-out action never appeared")
    if !signOut.isHittable { app.swipeUp() }
    XCTAssertTrue(waitUntilHittable(signOut, timeout: 5), "sign-out action is not tappable")
    signOut.tap()
    app.confirmSignOut()
    XCTAssertTrue(
      app.staticTexts["Signing out"].appears(within: 5), "sign-out showed no progress")
    XCTAssertFalse(app.buttons["Account"].exists, "the tab bar stayed while signing out")
    XCTAssertFalse(root.exists, "signed-in content stayed while signing out")
    addScreenshot(named: "runtime-signing-out")
    XCTAssertTrue(signIn.appears(within: 15), "failed sign-out did not land on the welcome")
    XCTAssertEqual(element(identifier: "auth.welcome-title").label, "Welcome!")
    XCTAssertEqual(signIn.label, "Sign in", "a failed sign-out changed the welcome")
    XCTAssertFalse(
      element(identifier: "auth.notice").exists, "a failed sign-out showed a notice")
    addScreenshot(named: "runtime-sign-out-failure")

    app.terminate()
    app.launch()
    XCTAssertTrue(signIn.appears(within: 15), "pending sign-out did not relaunch to the welcome")
    XCTAssertFalse(root.exists, "pending sign-out restored the session")

    app.terminate()
    app.launchArguments.removeAll { $0 == failure }
    app.launch()
    XCTAssertTrue(signIn.appears(within: 15), "sign-out cleanup did not relaunch to the welcome")
    XCTAssertFalse(root.exists, "sign-out cleanup restored the session")

    app.terminate()
    app.launch()
    XCTAssertTrue(signIn.appears(within: 15), "a saved credential survived the sign-out cleanup")
    XCTAssertFalse(root.exists, "a saved credential survived the sign-out cleanup")
  }

  func testTrashDisabledUsesPermanentDeleteCopyInContextMenu() {
    app.launchArguments.append("--putio-harness-trash-disabled")
    app.launch()

    let signIn = element(identifier: "auth.sign-in")
    XCTAssertTrue(signIn.appears(within: 10), "sign-in screen never appeared")
    signIn.tap()
    XCTAssertTrue(
      element(identifier: "files.screen.0").appears(within: 10),
      "signed-in root browser never appeared"
    )

    let folder = createFolder(named: "Delete Forever", expectedID: 415)
    XCTAssertFalse(app.buttons["files.actions.415"].exists)
    folder.swipeLeft()
    let swipeDelete = app.buttons["Delete permanently"]
    XCTAssertTrue(
      waitUntilHittable(swipeDelete, timeout: 5), "the swipe does not say Delete permanently")
    swipeDelete.tap()
    let alert = app.putioAlert("Delete 1 item permanently?")
    XCTAssertTrue(alert.appears(within: 5), "the swipe deleted without asking")
    alert.buttons["Cancel"].firstMatch.tap()
    XCTAssertTrue(alert.disappears(within: 5))
    XCTAssertTrue(folder.exists, "Cancel removed the row")

    let delete = openContextMenu(for: folder, actionLabel: "Delete permanently")
    delete.tap()
    XCTAssertTrue(alert.appears(within: 5), "the menu deleted without asking")
    XCTAssertTrue(
      alert.staticTexts["Trash is off for this account, so this can’t be undone."].exists)
    let confirm = alert.buttons["confirm-alert.confirm"].firstMatch
    XCTAssertTrue(waitUntilHittable(confirm, timeout: 5))
    XCTAssertEqual(confirm.label, "Delete")
    confirm.tap()
    XCTAssertTrue(app.staticTexts["Item deleted"].appears(within: 5))
    XCTAssertFalse(app.buttons["Undo"].exists, "a permanent delete offered Undo")
    XCTAssertTrue(folder.disappears(within: 5))

    app.buttons["Account"].tap()
    XCTAssertTrue(element(identifier: "account.storage-used").appears(within: 5))
    XCTAssertTrue(element(identifier: "settings.default-sort").appears(within: 15))
    XCTAssertFalse(
      element(identifier: "account.trash").exists, "the Trash row shows with trash off")
    let signOut = app.revealed("auth.sign-out")
    XCTAssertTrue(signOut.appears(within: 5), "sign-out action never appeared")
    signOut.tap()
    app.confirmSignOut()
    XCTAssertTrue(signIn.appears(within: 10), "sign-out did not return to sign-in")
  }

  func testTrashUndoSwipeAndFailedTrashKeepRowsInPlace() {
    app.launch()
    openSeasonFolder()

    let header = element(identifier: "files.header.440")
    let second = element(identifier: "files.item.442")
    let third = element(identifier: "files.item.443")
    let fourth = element(identifier: "files.item.444")
    openContextMenu(for: third, actionLabel: "Move to trash").tap()
    XCTAssertFalse(app.putioAlerts.firstMatch.exists, "a recoverable Trash move asked to confirm")
    XCTAssertTrue(third.disappears(within: 5), "the trashed row stayed")
    XCTAssertTrue(app.staticTexts["Moved to trash"].appears(within: 5), "no trashed toast")
    XCTAssertTrue(waitForLabelPrefix(header, "5 items"), "the header still counts the row")
    let undo = app.buttons["Undo"]
    XCTAssertTrue(waitUntilHittable(undo, timeout: 5), "the toast offers no Undo")
    addScreenshot(named: "runtime-trash-undo")
    undo.tap()
    XCTAssertTrue(third.appears(within: 5), "Undo did not put the row back")
    XCTAssertTrue(waitForLabelPrefix(header, "6 items"), "the restore did not reach the server")
    XCTAssertTrue(waitUntilHittable(third, timeout: 5))
    XCTAssertLessThan(second.frame.minY, third.frame.minY, "Undo moved the row up")
    XCTAssertLessThan(third.frame.minY, fourth.frame.minY, "Undo moved the row down")

    let subtitle = element(identifier: "files.item.446")
    XCTAssertTrue(waitUntilHittable(subtitle, timeout: 5))
    subtitle.swipeLeft()
    let swipeTrash = app.buttons["Move to trash"]
    XCTAssertTrue(waitUntilHittable(swipeTrash, timeout: 5), "the swipe offers no Move to trash")
    swipeTrash.tap()
    XCTAssertFalse(app.putioAlerts.firstMatch.exists, "a swiped Trash move asked to confirm")
    XCTAssertTrue(subtitle.disappears(within: 5), "the swiped row stayed")
    XCTAssertTrue(app.buttons["Undo"].appears(within: 5), "the swipe toast offers no Undo")

    XCTAssertTrue(waitUntilHittable(fourth, timeout: 5))
    openContextMenu(for: fourth, actionLabel: "Move to trash").tap()
    XCTAssertTrue(
      app.staticTexts["Could not move item to Trash"].appears(within: 10),
      "the failed Trash move was not reported")
    XCTAssertTrue(fourth.appears(within: 5), "the failed Trash move did not put the row back")
    XCTAssertTrue(waitForLabelPrefix(header, "5 items"), "the failed row is not counted again")
    addScreenshot(named: "runtime-trash-failed")
    signOutToWelcome()
  }

  func testTrashLimitAsksBeforeDeletingAndUnknownSettingBlocksTrash() {
    app.launchArguments += ["--putio-harness-trash-limit", "--putio-harness-unconfirmed-settings"]
    app.launch()
    let signIn = element(identifier: "auth.sign-in")
    XCTAssertTrue(signIn.appears(within: 10), "sign-in screen never appeared")
    signIn.tap()
    XCTAssertTrue(element(identifier: "files.screen.0").appears(within: 10))

    let folder = element(identifier: "files.item.410")
    XCTAssertTrue(waitUntilHittable(folder, timeout: 10))
    openContextMenu(for: folder, actionLabel: "Move to trash").tap()
    let limit = app.putioAlert("We couldn’t send these files to trash")
    XCTAssertTrue(limit.appears(within: 10), "the refused Trash move did not ask")
    XCTAssertTrue(
      limit.staticTexts["This folder contains too many files. Delete it permanently?"].exists)
    XCTAssertTrue(folder.exists, "the refused Trash move removed the row")
    addScreenshot(named: "runtime-trash-limit")
    limit.buttons["Cancel"].firstMatch.tap()
    XCTAssertTrue(limit.disappears(within: 5))
    XCTAssertTrue(waitUntilHittable(folder, timeout: 5), "Cancel removed the row")

    openContextMenu(for: folder, actionLabel: "Move to trash").tap()
    XCTAssertTrue(limit.appears(within: 10))
    limit.buttons["Delete permanently"].firstMatch.tap()
    XCTAssertTrue(app.staticTexts["Item deleted"].appears(within: 10), "no deleted toast")
    XCTAssertFalse(app.buttons["Undo"].exists, "a permanent delete offered Undo")
    XCTAssertTrue(folder.disappears(within: 5), "the permanently deleted row stayed")

    app.buttons["Account"].tap()
    let subtitles = app.switches["playback-settings.subtitles"]
    app.bringIntoView(subtitles)
    XCTAssertTrue(waitUntilHittable(subtitles, timeout: 10))
    // Form exposes the full row as the switch accessibility frame.
    subtitles.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
    app.showTabBar()
    app.buttons["Files"].tap()
    let document = element(identifier: "files.item.413")
    XCTAssertTrue(waitUntilHittable(document, timeout: 10))
    document.press(forDuration: 1)
    let trash = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Move to trash"))
      .firstMatch
    XCTAssertTrue(trash.appears(within: 5), "the menu has no Trash row")
    XCTAssertFalse(trash.isEnabled, "Trash ran before the setting was confirmed")
    XCTAssertTrue(
      trash.label.contains("Waiting for confirmed trash settings.")
        || app.staticTexts["Waiting for confirmed trash settings."].exists,
      "the disabled row does not say why")
    addScreenshot(named: "runtime-trash-unknown")
    dismissMenu()
    signOutToWelcome()
  }

  private func signOutToWelcome() {
    app.showTabBar()
    app.buttons["Account"].tap()
    let signOut = app.revealed("auth.sign-out")
    XCTAssertTrue(signOut.appears(within: 5), "sign-out action never appeared")
    if !signOut.isHittable { app.swipeUp() }
    XCTAssertTrue(waitUntilHittable(signOut, timeout: 5), "sign-out action is not tappable")
    signOut.tap()
    app.confirmSignOut()
    XCTAssertTrue(
      element(identifier: "auth.sign-in").appears(within: 10), "sign-out did not return to sign-in")
  }

  private func waitForLabelPrefix(_ element: XCUIElement, _ prefix: String) -> Bool {
    let expectation = XCTNSPredicateExpectation(
      predicate: NSPredicate(format: "label BEGINSWITH %@", prefix), object: element)
    return XCTWaiter.wait(for: [expectation], timeout: 10) == .completed
  }

  func testTrashManagementRestoreRetryDeleteAndEmpty() {
    app.launch()

    let signIn = element(identifier: "auth.sign-in")
    XCTAssertTrue(signIn.appears(within: 10))
    signIn.tap()
    XCTAssertTrue(element(identifier: "files.screen.0").appears(within: 10))

    app.buttons["Account"].tap()
    let trashEntry = element(identifier: "account.trash")
    XCTAssertTrue(waitUntilHittable(trashEntry, timeout: 5))
    let usedStorage = element(identifier: "account.storage-used")
    XCTAssertTrue(usedStorage.appears(within: 5))
    let usedBeforeDeletions = usedStorage.label
    trashEntry.tap()

    let restoreRow = app.staticTexts["Restore Me"]
    XCTAssertTrue(restoreRow.appears(within: 10))
    let refreshStart = restoreRow.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
    refreshStart.press(
      forDuration: 0.1,
      thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.85)),
      withVelocity: .slow,
      thenHoldForDuration: 1
    )
    let refreshError = app.staticTexts["Could not refresh Trash"]
    XCTAssertTrue(refreshError.appears(within: 5), app.debugDescription)
    XCTAssertTrue(restoreRow.exists, "failed refresh discarded the loaded Trash page")
    addScreenshot(named: "runtime-trash-refresh-error")
    let retryRefresh = app.buttons["Try again"]
    XCTAssertTrue(waitUntilHittable(retryRefresh, timeout: 5))
    retryRefresh.tap()
    XCTAssertTrue(refreshError.disappears(within: 5))
    // The second page loads on its own, as Files pages do.
    XCTAssertTrue(app.staticTexts["Empty Me"].appears(within: 5))
    XCTAssertTrue(element(identifier: "trash.load-more").disappears(within: 5))
    XCTAssertTrue(element(identifier: "trash.expiry-notice").exists)
    let restoreDetail = app.staticTexts.matching(
      NSPredicate(format: "label BEGINSWITH %@", "Expires on ")
    ).firstMatch
    XCTAssertTrue(restoreDetail.exists, "Trash rows do not show their expiry date")
    addScreenshot(named: "runtime-trash-loaded")

    let trashMenu = app.buttons["trash.menu"]
    XCTAssertTrue(waitUntilHittable(trashMenu, timeout: 5))
    XCTAssertEqual(trashMenu.label, "Trash Actions")
    trashMenu.tap()
    XCTAssertTrue(app.buttons["trash.restore-all"].appears(within: 5))
    let select = app.buttons["trash.select"]
    XCTAssertTrue(waitUntilHittable(select, timeout: 5))
    select.tap()
    let bulkRestore = app.buttons["trash.bulk.restore"]
    XCTAssertTrue(bulkRestore.appears(within: 5))
    XCTAssertFalse(bulkRestore.isEnabled)
    app.staticTexts["Empty Me"].tap()
    XCTAssertTrue(bulkRestore.isEnabled, "selecting a Trash row did not enable Restore")
    addScreenshot(named: "runtime-trash-selection")
    XCTAssertTrue(app.buttons["trash.bulk.delete"].isEnabled)
    app.buttons["trash.selection.done"].tap()
    XCTAssertTrue(bulkRestore.disappears(within: 5))
    let restoreActions = app.buttons["trash.item.419.actions"]
    XCTAssertTrue(waitUntilHittable(restoreActions, timeout: 5))
    restoreActions.tap()
    let restore = app.buttons["trash.restore.419"]
    XCTAssertTrue(waitUntilHittable(restore, timeout: 5))
    restore.tap()
    XCTAssertTrue(element(identifier: "trash.progress").appears(within: 5))
    app.navigationBars.buttons.element(boundBy: 0).tap()

    app.buttons["Files"].tap()
    XCTAssertTrue(
      element(identifier: "files.item.419").appears(within: 10),
      "restored item did not return to its authoritative root destination"
    )
    app.buttons["Account"].tap()
    XCTAssertTrue(waitUntilHittable(trashEntry, timeout: 5))
    trashEntry.tap()
    XCTAssertTrue(app.staticTexts["Delete Me"].appears(within: 5))
    XCTAssertTrue(restoreRow.disappears(within: 5))

    let deleteRow = app.staticTexts["Delete Me"]
    XCTAssertTrue(deleteRow.appears(within: 5))
    permanentlyDeleteTrashItem(id: 420, name: "Delete Me")
    XCTAssertTrue(
      app.staticTexts["Could not permanently delete item"].appears(within: 5)
    )
    XCTAssertTrue(deleteRow.exists, "failed permanent delete removed the row")

    permanentlyDeleteTrashItem(id: 420, name: "Delete Me")
    XCTAssertTrue(app.staticTexts["Item deleted"].appears(within: 5))
    XCTAssertTrue(deleteRow.disappears(within: 5))

    XCTAssertTrue(waitUntilHittable(trashMenu, timeout: 5))
    trashMenu.tap()
    let emptyTrash = app.buttons["trash.empty"]
    XCTAssertTrue(waitUntilHittable(emptyTrash, timeout: 5))
    emptyTrash.tap()
    XCTAssertTrue(app.staticTexts["Empty Trash permanently?"].appears(within: 5))
    XCTAssertTrue(
      app.staticTexts["Every item in Trash will be deleted and cannot be restored."].exists
    )
    let confirmEmpty = app.buttons["trash.empty-confirm"].firstMatch
    XCTAssertTrue(waitUntilHittable(confirmEmpty, timeout: 5))
    confirmEmpty.tap()
    XCTAssertTrue(app.staticTexts["Trash is empty"].appears(within: 10))
    XCTAssertTrue(app.staticTexts["Trash emptied"].appears(within: 5))
    // The seeded account refresh after emptying fails once: the stale-storage
    // warning must stay visible with its own retry, alongside the empty state.
    let staleStorage = app.staticTexts["Storage totals are out of date"]
    XCTAssertTrue(staleStorage.appears(within: 5), app.debugDescription)
    XCTAssertTrue(app.staticTexts["Trash is empty"].exists, "empty state hidden behind the error")
    let updateStorage = app.buttons["Update storage"]
    XCTAssertTrue(waitUntilHittable(updateStorage, timeout: 5))
    updateStorage.tap()
    XCTAssertTrue(staleStorage.disappears(within: 5), "storage retry did not clear")
    let emptyRefreshStart = app.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.25))
    emptyRefreshStart.press(
      forDuration: 0.1,
      thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.85)),
      withVelocity: .slow,
      thenHoldForDuration: 1
    )
    XCTAssertTrue(refreshError.appears(within: 5), app.debugDescription)
    XCTAssertTrue(waitUntilHittable(retryRefresh, timeout: 5))
    retryRefresh.tap()
    XCTAssertTrue(refreshError.disappears(within: 5))
    XCTAssertTrue(app.staticTexts["Trash is empty"].appears(within: 5))
    addScreenshot(named: "runtime-trash-empty")

    app.navigationBars.buttons.element(boundBy: 0).tap()
    XCTAssertTrue(usedStorage.appears(within: 5))
    let storageChanged = expectation(
      for: NSPredicate(format: "label != %@", usedBeforeDeletions), evaluatedWith: usedStorage)
    wait(for: [storageChanged], timeout: 5)
    XCTAssertNotEqual(
      usedStorage.label, usedBeforeDeletions, "emptying Trash did not change account storage")
    let signOut = app.revealed("auth.sign-out")
    XCTAssertTrue(signOut.appears(within: 5), "sign-out action never appeared")
    signOut.tap()
    app.confirmSignOut()
    XCTAssertTrue(signIn.appears(within: 10), "sign-out did not return to sign-in")
  }

  func testSortRoundTripAndContinuationAppendsTheSecondPage() {
    app.launch()

    let signIn = element(identifier: "auth.sign-in")
    XCTAssertTrue(signIn.appears(within: 10), "sign-in screen never appeared")
    signIn.tap()
    let root = element(identifier: "files.screen.0")
    XCTAssertTrue(root.appears(within: 10), "signed-in root browser never appeared")

    // Continuation: the second page lands without a tap once the footer renders.
    let secondPageRow = app.staticTexts["Season Pack.zip"]
    XCTAssertTrue(secondPageRow.appears(within: 10), "continuation page never appended")
    XCTAssertFalse(element(identifier: "files.more.0").exists, "load-more footer lingered")
    XCTAssertFalse(app.showsAccent(on: app.buttons["files.sort"]), "the sort button is yellow")

    app.swipeUp()
    openSortMenu()
    assertChecked(["Name", "A to Z"], unchecked: ["Z to A", "Unwatched first", "Watched first"])
    XCTAssertTrue(
      app.showsAccent(in: imageColumn(of: "A to Z")), "the sort checkmark is not yellow")
    XCTAssertFalse(
      app.showsAccent(in: imageColumn(of: "Z to A")), "an unchecked sort row is yellow")
    addScreenshot(named: "runtime-sort-menu-ascending")
    app.sortChoice("Z to A").tap()
    XCTAssertTrue(
      waitForFirstItem("files.item.413"), "reload did not apply the server order from the top")
    XCTAssertTrue(firstItem().isHittable, "the sorted list did not scroll to the top")
    XCTAssertFalse(app.staticTexts["Sorting changed"].exists, "sorting still shows a toast")
    openSortMenu()
    assertChecked(["Name", "Z to A"], unchecked: ["A to Z"])
    addScreenshot(named: "runtime-sort-menu-descending")
    dismissMenu()
    addScreenshot(named: "runtime-sorted-root")

    app.buttons["Account"].tap()
    let signOut = app.revealed("auth.sign-out")
    XCTAssertTrue(signOut.appears(within: 5), "sign-out action never appeared")
    signOut.tap()
    app.confirmSignOut()
    XCTAssertTrue(signIn.appears(within: 10), "sign-out did not return to sign-in")
  }

  func testSortMenuSectionsFailureRelaunchAndAccountDefault() {
    app.launchArguments += [
      "--putio-harness-persist-folder-sorts", "--putio-harness-reset-folder-sorts",
    ]
    app.launch()
    let signIn = element(identifier: "auth.sign-in")
    XCTAssertTrue(signIn.appears(within: 10), "sign-in screen never appeared")
    signIn.tap()
    openSeasonFolder()

    openSortMenu()
    assertChecked(["Name", "A to Z"], unchecked: ["Size", "Unwatched first", "Watched first"])
    addScreenshot(named: "runtime-sort-account-default")

    let steps: [(field: String, orders: [String], ascendingFirst: Int, descendingFirst: Int)] = [
      ("Size", ["Smallest first", "Largest first"], 446, 444),
      ("Date added", ["Oldest first", "Newest first"], 441, 444),
      ("Date modified", ["Oldest first", "Newest first"], 441, 444),
    ]
    var ascending = true
    for step in steps {
      app.sortChoice(step.field).tap()
      assertSortUpdated(firstItem: ascending ? step.ascendingFirst : step.descendingFirst)
      openSortMenu()
      let current = ascending ? step.orders[0] : step.orders[1]
      let other = ascending ? step.orders[1] : step.orders[0]
      assertChecked([step.field, current], unchecked: ["Name", other])
      app.sortChoice(other).tap()
      ascending.toggle()
      assertSortUpdated(firstItem: ascending ? step.ascendingFirst : step.descendingFirst)
      openSortMenu()
      assertChecked([step.field, other], unchecked: [current])
    }

    XCTAssertFalse(ascending, "the walk should leave a descending order checked")
    app.sortChoice("Type").tap()
    XCTAssertTrue(
      app.staticTexts["Couldn’t change sorting."].appears(within: 10),
      "a failed sort did not say so")
    XCTAssertTrue(waitForFirstItem("files.item.444"), "a failed sort changed the order")
    addScreenshot(named: "runtime-sort-failed")
    openSortMenu()
    assertChecked(["Date modified", "Newest first"], unchecked: ["Type", "Z to A"])

    app.sortChoice("Type").tap()
    assertSortUpdated(firstItem: 444)
    openSortMenu()
    assertChecked(["Type", "Z to A"], unchecked: ["A to Z"])
    app.sortChoice("A to Z").tap()
    assertSortUpdated(firstItem: 445)
    openSortMenu()
    app.sortChoice("Name").tap()
    assertSortUpdated(firstItem: 441)
    openSortMenu()
    assertChecked(["Name", "A to Z"], unchecked: ["Type"])
    app.sortChoice("Z to A").tap()
    assertSortUpdated(firstItem: 444)

    openSortMenu()
    app.sortChoice("Unwatched first").tap()
    assertSortUpdated(firstItem: 441)
    openSortMenu()
    assertChecked(
      ["Unwatched first"],
      unchecked: [
        "Name", "Size", "Date added", "Date modified", "Type", "A to Z", "Z to A", "Watched first",
      ])
    addScreenshot(named: "runtime-sort-unwatched-first")
    app.sortChoice("Watched first").tap()
    assertSortUpdated(firstItem: 442)

    app.terminate()
    app.launchArguments.removeAll { $0 == "--putio-harness-reset-folder-sorts" }
    app.launch()
    if signIn.appears(within: 3) { signIn.tap() }
    openSeasonFolder()
    XCTAssertTrue(waitForFirstItem("files.item.442"), "relaunch lost the folder's own order")
    openSortMenu()
    assertChecked(["Watched first"], unchecked: ["Name", "Unwatched first"])
    dismissMenu()

    let back = app.navigationBars.buttons["BackButton"]
    XCTAssertTrue(waitUntilHittable(back, timeout: 5))
    back.tap()
    XCTAssertTrue(element(identifier: "files.screen.410").appears(within: 5))
    openSortMenu()
    assertChecked(["Name", "A to Z"], unchecked: ["Unwatched first", "Z to A"])
    addScreenshot(named: "runtime-sort-other-folder-default")
    dismissMenu()
  }

  func testSearchPaginationRetryAndFolderRestoration() {
    app.launch()
    let signIn = element(identifier: "auth.sign-in")
    XCTAssertTrue(signIn.appears(within: 10))
    signIn.tap()
    XCTAssertTrue(element(identifier: "files.screen.0").appears(within: 10))

    let folder = element(identifier: "files.item.410")
    XCTAssertTrue(waitUntilHittable(folder, timeout: 5))
    folder.tap()
    XCTAssertTrue(element(identifier: "files.screen.410").appears(within: 10))
    XCTAssertFalse(element(identifier: "files.item.415").exists)

    app.buttons["Search"].tap()
    let searchField = app.searchFields.firstMatch
    XCTAssertTrue(searchField.appears(within: 5))
    searchField.tap()
    searchField.typeText("Harness\n")
    let folderResult = element(identifier: "files.search-item.410")
    let videoResult = element(identifier: "files.search-item.411")
    XCTAssertTrue(folderResult.appears(within: 10))
    let moreRetry = app.buttons["files.search-more-retry"]
    XCTAssertTrue(moreRetry.appears(within: 10))
    XCTAssertTrue(
      app.staticTexts["Couldn’t load more results."].exists, "the failed page never said so")
    XCTAssertTrue(folderResult.exists, "failed continuation removed the first page")
    moreRetry.tap()
    XCTAssertTrue(videoResult.appears(within: 10), "search continuation never appended")
    addScreenshot(named: "runtime-search-results")
    let searchMove = openContextMenu(for: videoResult, actionLabel: "Move")
    XCTAssertFalse(app.buttons["Rename"].exists, "search result menu offers Rename")
    XCTAssertFalse(app.buttons["Move to trash"].exists, "search result menu offers Trash")
    XCTAssertFalse(app.buttons["Select"].exists, "search result menu offers Select")
    dismissMenu()
    XCTAssertTrue(searchMove.disappears(within: 5))
    videoResult.tap()
    XCTAssertTrue(element(identifier: "video.error").appears(within: 5))
    app.buttons["Try again"].tap()
    XCTAssertTrue(element(identifier: "video.ready").appears(within: 15))
    element(identifier: "video.done").tap()
    XCTAssertTrue(folderResult.appears(within: 10))
    folderResult.tap()
    XCTAssertTrue(element(identifier: "files.screen.410").appears(within: 10))
    XCTAssertTrue(element(identifier: "files.item.411").exists)
    createFolder(named: "Cross-tab Refresh", expectedID: 415)
    app.navigationBars.buttons["BackButton"].tap()
    XCTAssertTrue(searchField.appears(within: 5))

    app.buttons["Files"].tap()
    XCTAssertTrue(element(identifier: "files.screen.410").appears(within: 5))
    let crossTabFolder = element(identifier: "files.item.415")
    XCTAssertTrue(
      crossTabFolder.appears(within: 10),
      "the Files folder did not refresh after its Search counterpart was popped"
    )
    XCTAssertEqual(crossTabFolder.label.components(separatedBy: ", ").first, "Cross-tab Refresh")
    app.navigationBars.buttons["BackButton"].tap()
    XCTAssertTrue(element(identifier: "files.screen.0").appears(within: 5))
    app.buttons["Search"].tap()
    XCTAssertTrue(searchField.appears(within: 5))

    replaceSearchQuery("no-matching-file", in: searchField)
    XCTAssertTrue(app.staticTexts["Nothing matches"].appears(within: 10))
    XCTAssertFalse(folderResult.exists)
    let refreshStart = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.25))
    let refreshEnd = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.7))
    refreshStart.press(forDuration: 0.1, thenDragTo: refreshEnd)
    let emptyRefreshRetry = app.buttons["files.search-retry"]
    XCTAssertTrue(emptyRefreshRetry.appears(within: 10))
    emptyRefreshRetry.tap()
    XCTAssertTrue(app.staticTexts["Nothing matches"].appears(within: 10))
    replaceSearchQuery("retry", in: searchField)
    let retry = element(identifier: "files.search-retry")
    XCTAssertTrue(retry.appears(within: 10))
    retry.tap()
    XCTAssertTrue(videoResult.appears(within: 10))

    app.buttons["Files"].tap()
    XCTAssertTrue(folder.appears(within: 5))
    folder.tap()
    XCTAssertTrue(element(identifier: "files.screen.410").appears(within: 10))
    app.terminate()
    app.launch()
    XCTAssertTrue(
      element(identifier: "files.screen.410").appears(within: 15),
      "relaunch did not restore the folder for the signed-in account")
    let back = app.navigationBars.buttons["BackButton"]
    XCTAssertTrue(waitUntilHittable(back, timeout: 5))
    back.tap()
    XCTAssertTrue(element(identifier: "files.screen.0").appears(within: 5))
    folder.tap()
    XCTAssertTrue(element(identifier: "files.screen.410").appears(within: 5))
    app.buttons["Account"].tap()
    let signOut = app.revealed("auth.sign-out")
    XCTAssertTrue(signOut.appears(within: 5))
    signOut.tap()
    app.confirmSignOut()
    XCTAssertTrue(signIn.appears(within: 10))
    signIn.tap()
    XCTAssertTrue(element(identifier: "files.screen.0").appears(within: 10))
    XCTAssertFalse(element(identifier: "files.screen.410").exists)
    app.buttons["Account"].tap()
    XCTAssertTrue(app.revealed("auth.sign-out").appears(within: 5))
    signOut.tap()
    app.confirmSignOut()
    XCTAssertTrue(signIn.appears(within: 10))
  }

  func testFolderEmptyPagingFailedPageAndPullToRefresh() {
    app.launchArguments.append("--putio-harness-folder-states")
    app.launch()
    let signIn = element(identifier: "auth.sign-in")
    XCTAssertTrue(signIn.appears(within: 10), "sign-in screen never appeared")
    signIn.tap()
    XCTAssertTrue(element(identifier: "files.screen.0").appears(within: 10))

    element(identifier: "files.item.423").tap()
    let empty = app.staticTexts["No files whatsoever!"]
    XCTAssertTrue(empty.appears(within: 10), "the empty folder never said so")
    XCTAssertTrue(app.staticTexts["Maybe you’d like to create a new folder?"].exists)
    pullToRefresh()
    XCTAssertTrue(empty.appears(within: 5), "pull to refresh lost the empty state")
    addScreenshot(named: "runtime-folder-empty")
    let createFolder = app.buttons["Create folder"]
    XCTAssertTrue(waitUntilHittable(createFolder, timeout: 5), "Create folder is unavailable")
    createFolder.tap()
    let alert = nameAlert("New folder")
    XCTAssertTrue(alert.staticTexts["In Empty"].exists, "New folder names another folder")
    submitName("From Empty", in: alert, as: "Create")
    let created = element(identifier: "files.item.415")
    XCTAssertTrue(created.appears(within: 10), "the created folder never replaced the empty state")
    XCTAssertFalse(empty.exists, "the empty state outlived the new folder")
    app.navigationBars.buttons["BackButton"].tap()

    let paging = element(identifier: "files.item.460")
    XCTAssertTrue(waitUntilHittable(paging, timeout: 10), "the paging folder never appeared")
    paging.tap()
    let firstRow = app.staticTexts["Paging File 001.txt"]
    XCTAssertTrue(firstRow.appears(within: 10), "the paging folder never listed its first page")
    XCTAssertTrue(element(identifier: "files.header.460").label.hasPrefix("450 items"))
    pullToRefresh()
    XCTAssertTrue(firstRow.exists, "pull to refresh cleared rows before new ones arrived")
    XCTAssertTrue(firstRow.appears(within: 5), "pull to refresh lost the first page")

    let failed = app.staticTexts["Couldn’t load more files."]
    XCTAssertTrue(scrollUntilShown(failed, swipes: 15), "page 2 never failed")
    XCTAssertTrue(app.staticTexts["Paging File 050.txt"].exists, "loaded rows left on failure")
    XCTAssertFalse(app.staticTexts["Paging File 051.txt"].exists, "the failed page appended rows")
    addScreenshot(named: "runtime-folder-load-more-failed")
    let retry = element(identifier: "files.more-retry.460")
    XCTAssertTrue(waitUntilHittable(retry, timeout: 5), "the failed page has no Try again")
    retry.tap()
    XCTAssertTrue(
      app.staticTexts["Paging File 051.txt"].appears(within: 10), "Try again never appended page 2")
    XCTAssertFalse(failed.exists, "the failure stayed after Try again")

    let lastRow = app.staticTexts["Paging File 450.txt"]
    XCTAssertTrue(scrollUntilShown(lastRow, swipes: 120), "paging never reached the 450th file")
    XCTAssertFalse(element(identifier: "files.more.460").exists, "the last page kept a footer")
    XCTAssertFalse(failed.exists, "a later page failed")

    app.navigationBars.buttons["BackButton"].tap()
    XCTAssertTrue(element(identifier: "files.screen.0").appears(within: 5))
    let account = app.buttons["Account"]
    if !account.exists { app.buttons["Files"].tap() }
    XCTAssertTrue(account.appears(within: 5), "the tab bar stayed collapsed")
    account.tap()
    let signOut = app.revealed("auth.sign-out")
    XCTAssertTrue(signOut.appears(within: 5), "sign-out action never appeared")
    signOut.tap()
    app.confirmSignOut()
    XCTAssertTrue(signIn.appears(within: 10), "sign-out did not return to sign-in")
  }

  func testFolderFailuresNameTheirReasonAndRecover() {
    app.launchArguments += ["--putio-harness-folder-fault", "403,429,503,offline@440"]
    app.launch()
    let signIn = element(identifier: "auth.sign-in")
    XCTAssertTrue(signIn.appears(within: 10), "sign-in screen never appeared")
    signIn.tap()
    XCTAssertTrue(element(identifier: "files.screen.0").appears(within: 10))
    element(identifier: "files.item.410").tap()
    XCTAssertTrue(element(identifier: "files.header.410").appears(within: 10))
    let season = element(identifier: "files.item.440")
    XCTAssertTrue(waitUntilHittable(season, timeout: 5), "the season folder never appeared")
    season.tap()

    let retry = element(identifier: "files.retry.440")
    let reasons = [
      "You don’t have access to this folder.",
      "put.io is receiving too many requests. Try again shortly.",
      "put.io is temporarily unavailable. Try again.",
    ]
    for reason in reasons {
      XCTAssertTrue(app.staticTexts[reason].appears(within: 10), "never said: \(reason)")
      XCTAssertTrue(app.staticTexts["Couldn’t load this"].exists, "the failure has no title")
      XCTAssertTrue(app.navigationBars["Blue Lights"].exists, "the failure lost its folder")
      if reason == reasons[0] { addScreenshot(named: "runtime-folder-forbidden") }
      XCTAssertTrue(waitUntilHittable(retry, timeout: 5), "the failure offers no Try again")
      retry.tap()
    }

    XCTAssertTrue(
      app.staticTexts["put.io is out of reach"].appears(within: 10), "the folder never went offline"
    )
    XCTAssertTrue(
      app.staticTexts["Your connection dropped, or we did. Retrying on its own."].exists,
      "the offline state does not say it retries")
    XCTAssertFalse(
      element(identifier: "files.offline-banner").exists, "the banner shows with no downloads")
    addScreenshot(named: "runtime-folder-offline")
    let header = element(identifier: "files.header.440")
    XCTAssertTrue(header.appears(within: 15), "the offline folder never retried on its own")

    app.navigationBars.buttons["BackButton"].tap()
    XCTAssertTrue(
      element(identifier: "files.header.410").appears(within: 5), "recovery lost the folder path")
    app.navigationBars.buttons["BackButton"].tap()
    XCTAssertTrue(element(identifier: "files.screen.0").appears(within: 5))
    let account = app.buttons["Account"]
    if !account.exists { app.buttons["Files"].tap() }
    XCTAssertTrue(account.appears(within: 5), "the tab bar stayed collapsed")
    account.tap()
    let signOut = app.revealed("auth.sign-out")
    XCTAssertTrue(signOut.appears(within: 5), "sign-out action never appeared")
    signOut.tap()
    app.confirmSignOut()
    XCTAssertTrue(signIn.appears(within: 10), "sign-out did not return to sign-in")
  }

  func testRenamingAndDeletingOpenFolderReconcilesOtherTabs() {
    app.launch()
    let signIn = element(identifier: "auth.sign-in")
    XCTAssertTrue(signIn.appears(within: 10))
    signIn.tap()
    XCTAssertTrue(element(identifier: "files.screen.0").appears(within: 10))
    app.buttons["Search"].tap()
    let search = app.searchFields.firstMatch
    XCTAssertTrue(waitUntilHittable(search, timeout: 5))
    search.tap()
    search.typeText("Harness\n")
    let folderResult = element(identifier: "files.search-item.410")
    XCTAssertTrue(waitUntilHittable(folderResult, timeout: 10))
    folderResult.tap()
    XCTAssertTrue(element(identifier: "files.screen.410").appears(within: 10))
    XCTAssertTrue(element(identifier: "files.item.411").exists)
    let child = createFolder(named: "Deleted Ancestor Child", expectedID: 415)
    app.buttons["Files"].tap()
    XCTAssertTrue(element(identifier: "files.screen.0").appears(within: 5))
    let folder = element(identifier: "files.item.410")
    openContextMenu(for: folder, actionLabel: "Rename").tap()
    submitName("Renamed Harness", in: nameAlert("Rename"), as: "Rename")
    let renamed = XCTNSPredicateExpectation(
      predicate: NSPredicate(
        format: "(label == %@ OR label BEGINSWITH %@) AND enabled == true", "Renamed Harness",
        "Renamed Harness, "),
      object: folder
    )
    XCTAssertEqual(XCTWaiter.wait(for: [renamed], timeout: 10), .completed)
    app.buttons["Search"].tap()
    XCTAssertTrue(
      app.navigationBars["Renamed Harness"].appears(within: 10),
      "the open Search folder kept its old name after a rename in Files"
    )
    XCTAssertTrue(waitUntilHittable(child, timeout: 5))
    child.tap()
    XCTAssertTrue(element(identifier: "files.screen.415").appears(within: 10))
    XCTAssertTrue(app.staticTexts["No files whatsoever!"].appears(within: 5))
    XCTAssertFalse(app.staticTexts["Folder not found"].exists)

    app.buttons["Files"].tap()
    XCTAssertTrue(element(identifier: "files.screen.0").appears(within: 5))
    let trash = openContextMenu(for: folder, actionLabel: "Move to trash")
    trash.tap()
    XCTAssertTrue(folder.disappears(within: 10))

    app.buttons["Search"].tap()
    XCTAssertTrue(app.navigationBars["Deleted Ancestor Child"].appears(within: 5))
    XCTAssertTrue(
      app.staticTexts["Folder not found"].appears(within: 10),
      "the open descendant kept its listing after its ancestor was deleted"
    )
    XCTAssertFalse(app.staticTexts["No files whatsoever!"].exists)
    app.navigationBars.buttons["BackButton"].tap()
    XCTAssertTrue(app.navigationBars["Renamed Harness"].appears(within: 5))
    XCTAssertTrue(
      app.staticTexts["Folder not found"].appears(within: 10),
      "the deleted folder kept its listing when returning from its descendant"
    )
    XCTAssertFalse(
      element(identifier: "files.item.411").exists, "deleted folder kept a playable video")
    XCTAssertFalse(
      element(identifier: "files.item.415").exists, "deleted folder kept its child row")
    app.navigationBars.buttons["BackButton"].tap()
    XCTAssertTrue(app.staticTexts["Nothing matches"].appears(within: 10))
    XCTAssertFalse(folderResult.exists, "search kept the deleted folder")
    XCTAssertFalse(element(identifier: "files.search-item.411").exists)
    app.buttons["Files"].tap()
    XCTAssertTrue(element(identifier: "files.screen.0").appears(within: 5))
    app.buttons["Account"].tap()
    let signOut = app.revealed("auth.sign-out")
    XCTAssertTrue(signOut.appears(within: 5))
    signOut.tap()
    app.confirmSignOut()
    XCTAssertTrue(signIn.appears(within: 10))
  }

  func testSearchFiltersGroupsAndResultMenu() {
    app.launch()
    let signIn = element(identifier: "auth.sign-in")
    XCTAssertTrue(signIn.appears(within: 10))
    signIn.tap()
    XCTAssertTrue(element(identifier: "files.screen.0").appears(within: 10))

    app.buttons["Search"].tap()
    let searchField = app.searchFields.firstMatch
    XCTAssertTrue(waitUntilHittable(searchField, timeout: 5))
    searchField.tap()
    searchField.typeText("blue")
    let folder = element(identifier: "files.search-item.440")
    let episode = element(identifier: "files.search-item.441")
    let subtitle = element(identifier: "files.search-item.445")
    XCTAssertTrue(folder.appears(within: 10), "the folder result never appeared")
    XCTAssertTrue(subtitle.exists, "the subtitle result is missing")
    let requests = element(identifier: "search.requests")
    XCTAssertEqual(requests.value as? String, "blue|", "typing sent more than one search")
    XCTAssertEqual(
      element(identifier: "files.search-group.folders").label, "Folders, 1",
      "the Folders group lacks its count")
    XCTAssertEqual(
      element(identifier: "files.search-group.files").label, "Files, 3",
      "the Files group lacks its count")
    XCTAssertTrue(app.staticTexts["in Blue Lights"].firstMatch.appears(within: 10))
    addScreenshot(named: "runtime-search-grouped")

    element(identifier: "files.search-filter.videos").tap()
    XCTAssertTrue(folder.disappears(within: 10), "Videos kept the folder")
    XCTAssertTrue(episode.appears(within: 10), "Videos lost the episode")
    XCTAssertFalse(subtitle.exists, "Videos kept the subtitle")
    XCTAssertEqual(requests.value as? String, "blue|;blue|VIDEO", "Videos sent the wrong type")
    element(identifier: "files.search-filter.all").tap()
    XCTAssertTrue(folder.appears(within: 10), "All never brought the folder back")
    XCTAssertEqual(requests.value as? String, "blue|;blue|VIDEO;blue|")

    _ = openContextMenu(for: episode, actionLabel: "Move")
    XCTAssertTrue(app.buttons["Play"].exists, "the result menu lacks Play")
    XCTAssertFalse(app.buttons["Select"].exists, "the result menu offers Select")
    XCTAssertFalse(app.buttons["Rename"].exists, "the result menu offers Rename")
    XCTAssertFalse(app.buttons["Move to trash"].exists, "the result menu offers Trash")
    dismissMenu()

    folder.tap()
    XCTAssertTrue(element(identifier: "files.screen.440").appears(within: 10))
    app.navigationBars.buttons["BackButton"].tap()
    XCTAssertTrue(folder.appears(within: 5), "Back lost the results")
    XCTAssertTrue(subtitle.exists, "Back lost the Files group")

    if app.keyboards.firstMatch.exists { searchField.typeText("\n") }
    signOutFromAccount()
  }

  func testSearchEmptyAndFailureStates() {
    app.launch()
    let signIn = element(identifier: "auth.sign-in")
    XCTAssertTrue(signIn.appears(within: 10))
    signIn.tap()
    XCTAssertTrue(element(identifier: "files.screen.0").appears(within: 10))

    app.buttons["Search"].tap()
    let searchField = app.searchFields.firstMatch
    XCTAssertTrue(waitUntilHittable(searchField, timeout: 5))
    searchField.tap()
    searchField.typeText("blorp\n")
    let nothing = app.staticTexts["Nothing matches"]
    XCTAssertTrue(nothing.appears(within: 10), "an unmatched query never said so")
    XCTAssertTrue(
      app.staticTexts["No files or folders named blorp. Try fewer words."].exists,
      "the empty state does not name the query")
    XCTAssertTrue(element(identifier: "files.search-filters").exists, "no filters on no results")
    addScreenshot(named: "runtime-search-none")

    let long = "blue lights season four episode one organic 1080p hdtv"
    replaceSearchQuery(long, in: searchField)
    let shown =
      "No files or folders named blue lights season four episode one organic 1080p…. "
      + "Try fewer words."
    XCTAssertTrue(app.staticTexts[shown].appears(within: 10), "the long query was not cut")
    XCTAssertTrue(element(identifier: "files.search-filters").exists)
    addScreenshot(named: "runtime-search-long-query")

    element(identifier: "files.search-filter.videos").tap()
    replaceSearchQuery("retry", in: searchField)
    let retry = element(identifier: "files.search-retry")
    XCTAssertTrue(retry.appears(within: 10), "the seeded search failure never showed")
    XCTAssertTrue(app.staticTexts["Couldn’t search"].exists)
    XCTAssertTrue(app.staticTexts["Check your connection and try again."].exists)
    XCTAssertTrue(element(identifier: "files.search-filters").exists, "no filters on failure")
    addScreenshot(named: "runtime-search-failed")
    let requests = element(identifier: "search.requests")
    retry.tap()
    XCTAssertTrue(
      element(identifier: "files.search-item.411").appears(within: 10), "Try again never loaded")
    let repeated = XCTNSPredicateExpectation(
      predicate: NSPredicate(format: "value ENDSWITH %@", "retry|VIDEO;retry|VIDEO"),
      object: requests)
    XCTAssertEqual(
      XCTWaiter().wait(for: [repeated], timeout: 5), .completed,
      "Try again changed the query or filter")

    if app.keyboards.firstMatch.exists { searchField.typeText("\n") }
    app.terminate()
    app.launchArguments.append("--putio-harness-search-offline")
    app.launch()
    XCTAssertTrue(waitUntilHittable(app.buttons["Search"], timeout: 15))
    app.buttons["Search"].tap()
    XCTAssertTrue(waitUntilHittable(searchField, timeout: 5))
    searchField.tap()
    searchField.typeText("blue\n")
    XCTAssertTrue(
      app.staticTexts["Couldn’t search"].appears(within: 10), "offline search never failed")
    XCTAssertTrue(element(identifier: "files.search-filters").exists)
    addScreenshot(named: "runtime-search-offline")

    signOutFromAccount()
  }

  func testRecentSearchesRecordRunRemoveClearTurnedOffAndFailedWrite() {
    app.launch()
    let signIn = element(identifier: "auth.sign-in")
    XCTAssertTrue(signIn.appears(within: 10))
    signIn.tap()
    XCTAssertTrue(element(identifier: "files.screen.0").appears(within: 10))

    app.buttons["Search"].tap()
    let field = app.searchFields.firstMatch
    XCTAssertTrue(waitUntilHittable(field, timeout: 5))
    XCTAssertTrue(app.staticTexts["Find your files"].appears(within: 5), "no first-use state")
    XCTAssertFalse(app.staticTexts["Recent searches"].exists)
    addScreenshot(named: "runtime-search-start")

    field.tap()
    field.typeText("one\n")
    for query in ["two", "three", "four", "five", "six"] {
      replaceSearchQuery(query, in: field)
    }
    clearSearchQuery(in: field)
    assertRecentSearches(["six", "five", "four", "three", "two"])

    recentSearch("three").tap()
    XCTAssertEqual(field.value as? String, "three", "the recent search did not run")
    clearSearchQuery(in: field)
    assertRecentSearches(["three", "six", "five", "four", "two"])
    addScreenshot(named: "runtime-search-recent")

    app.buttons["files.search-recent-remove.two"].tap()
    assertRecentSearches(["three", "six", "five", "four"])

    app.buttons["files.search-recent-clear"].tap()
    XCTAssertTrue(
      app.staticTexts["Find your files"].appears(within: 5), "Clear left recent searches")

    app.launchArguments += ["--putio-harness-search-history", "off"]
    relaunchSignedIn()
    app.buttons["Search"].tap()
    XCTAssertTrue(
      app.staticTexts["Find your files"].appears(within: 5), "history off showed searches")
    field.tap()
    field.typeText("blue\n")
    XCTAssertTrue(element(identifier: "files.search-item.440").appears(within: 10))
    clearSearchQuery(in: field)
    XCTAssertTrue(
      app.staticTexts["Find your files"].appears(within: 5), "history off recorded blue")

    app.launchArguments[app.launchArguments.count - 1] = "fail-write"
    relaunchSignedIn()
    app.buttons["Search"].tap()
    assertRecentSearches(["blue lights", "sintel", "mp3", "tree rings"])
    app.buttons["files.search-recent-remove.mp3"].tap()
    XCTAssertTrue(
      app.staticTexts["Couldn’t update recent searches"].appears(within: 10),
      "no write failure toast")
    assertRecentSearches(["blue lights", "sintel", "mp3", "tree rings"])
    addScreenshot(named: "runtime-search-recent-failed")
    app.buttons["files.search-recent-remove.mp3"].tap()
    assertRecentSearches(["blue lights", "sintel", "tree rings"])

    signOutFromAccount()
  }

  private func relaunchSignedIn() {
    app.launch()
    let signIn = element(identifier: "auth.sign-in")
    let root = element(identifier: "files.screen.0")
    if signIn.appears(within: 5) { signIn.tap() }
    XCTAssertTrue(root.appears(within: 10), "Files never opened after relaunch")
  }

  private func recentSearch(_ term: String) -> XCUIElement {
    app.buttons["files.search-recent.\(term)"]
  }

  private func assertRecentSearches(
    _ terms: [String], file: StaticString = #filePath, line: UInt = #line
  ) {
    XCTAssertTrue(
      app.staticTexts["Recent searches"].appears(within: 5), "no Recent searches header",
      file: file, line: line)
    for term in terms {
      XCTAssertTrue(
        recentSearch(term).appears(within: 5), "\(term) is missing", file: file, line: line)
    }
    let shown = app.buttons.matching(
      NSPredicate(format: "identifier BEGINSWITH %@", "files.search-recent.")
    ).allElementsBoundByIndex.sorted { $0.frame.minY < $1.frame.minY }.map(\.identifier)
    XCTAssertEqual(
      shown, terms.map { "files.search-recent.\($0)" }, "recent searches out of order",
      file: file, line: line)
  }

  private func clearSearchQuery(in field: XCUIElement) {
    field.tap()
    let clear = field.buttons["Clear text"]
    XCTAssertTrue(waitUntilHittable(clear, timeout: 5))
    clear.tap()
  }

  private func replaceSearchQuery(_ query: String, in field: XCUIElement) {
    field.tap()
    let clear = field.buttons["Clear text"]
    XCTAssertTrue(waitUntilHittable(clear, timeout: 5))
    clear.tap()
    field.typeText(query + "\n")
    XCTAssertEqual(field.value as? String, query)
  }

  private func permanentlyDeleteTrashItem(id: Int, name: String) {
    let actions = app.buttons["trash.item.\(id).actions"]
    XCTAssertTrue(waitUntilHittable(actions, timeout: 5))
    actions.tap()
    let delete = app.buttons["trash.delete.\(id)"]
    XCTAssertTrue(waitUntilHittable(delete, timeout: 5))
    delete.tap()
    XCTAssertTrue(
      app.staticTexts["Delete “\(name)” permanently?"].appears(within: 5)
    )
    XCTAssertTrue(app.staticTexts["This item cannot be restored."].exists)
    let confirm = app.buttons["trash.delete-confirm"].firstMatch
    XCTAssertTrue(waitUntilHittable(confirm, timeout: 5))
    confirm.tap()
  }

  func testPlaybackPositionPersistsAcrossReopen() {
    app.launch()

    let signIn = element(identifier: "auth.sign-in")
    XCTAssertTrue(signIn.appears(within: 10), "sign-in screen never appeared")
    signIn.tap()

    let folder = element(identifier: "files.item.410")
    XCTAssertTrue(folder.appears(within: 10), "seeded folder never appeared")
    folder.tap()

    let nested = element(identifier: "files.screen.410")
    let nestedFile = element(identifier: "files.item.411")
    XCTAssertTrue(nested.appears(within: 10), "nested browser never appeared")
    XCTAssertTrue(nestedFile.appears(within: 5), "seeded nested file never appeared")
    nestedFile.tap()

    let done = element(identifier: "video.done")
    XCTAssertTrue(done.appears(within: 5), "video screen never appeared")
    let conversionError = element(identifier: "video.error")
    XCTAssertTrue(
      conversionError.appears(within: 5),
      "first conversion request did not produce a recoverable failure"
    )
    let retry = app.buttons["Try again"]
    XCTAssertTrue(retry.isHittable, "conversion retry is not tappable")
    retry.tap()
    XCTAssertTrue(
      element(identifier: "video.conversion-progress").appears(within: 5),
      "conversion progress never appeared"
    )
    XCTAssertTrue(
      element(identifier: "video.ready").appears(within: 10),
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

    XCTAssertTrue(nested.appears(within: 5), "video did not return to folder")
    let reportedPosition = element(identifier: "video.position-reported")
    XCTAssertTrue(
      reportedPosition.appears(within: 5),
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
      "Watched, resume at \(resumeText(seconds: $0))"
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
    XCTAssertTrue(done.appears(within: 5), "reopened video screen never appeared")
    XCTAssertTrue(
      resumePosition.appears(within: 5),
      "persisted resume position did not resolve on reopen"
    )
    XCTAssertEqual(resumePosition.value as? String, persistedSeconds.map(String.init))
    XCTAssertTrue(done.isHittable, "reopened video Done button is not tappable")
    done.tap()

    XCTAssertTrue(nested.appears(within: 5), "reopened video did not return to folder")
    let navigationBar = app.navigationBars["Harness Folder"]
    let backButton = navigationBar.buttons["Files"]
    XCTAssertTrue(backButton.isHittable, "native Files back button is not tappable")
    backButton.tap()

    XCTAssertTrue(
      element(identifier: "files.screen.0").appears(within: 5),
      "root browser did not return"
    )
    assertPlayingToTheEndMarksWatchedAndReopensFromTheStart()

    app.buttons["Account"].tap()
    let signOut = app.revealed("auth.sign-out")
    XCTAssertTrue(signOut.appears(within: 5), "sign-out action never appeared")
    signOut.tap()
    app.confirmSignOut()
    XCTAssertTrue(signIn.appears(within: 10), "sign-out did not return to sign-in")
  }

  private func assertPlayingToTheEndMarksWatchedAndReopensFromTheStart() {
    let rootVideo = element(identifier: "files.item.412")
    let done = element(identifier: "video.done")
    let ready = element(identifier: "video.ready")
    XCTAssertTrue(rootVideo.appears(within: 5), "root video row never appeared")
    XCTAssertEqual(rootVideo.value as? String, "Watched, resume at \(resumeText(seconds: 560))")
    rootVideo.tap()
    if !ready.appears(within: 10), element(identifier: "video.error").exists {
      app.buttons["Try again"].tap()
    }
    XCTAssertTrue(ready.appears(within: 10), "root video never became ready")
    XCTAssertEqual(element(identifier: "video.resume-position").value as? String, "560")
    let cancelNext = element(identifier: "video.cancel-next")
    XCTAssertTrue(cancelNext.appears(within: 45), "root video never played to its end")
    cancelNext.tap()
    let endSeconds = reportedSeconds(
      of: 412, from: element(identifier: "video.position-reported").value as? String)
    XCTAssertGreaterThanOrEqual(endSeconds ?? -1, 567, "the save did not reach 96% of 590 s")
    done.tap()

    let watchedRow = XCTNSPredicateExpectation(
      predicate: NSPredicate(
        format: "value == %@", "Watched, resume at \(resumeText(seconds: endSeconds ?? -1))"),
      object: rootVideo
    )
    XCTAssertEqual(
      XCTWaiter.wait(for: [watchedRow], timeout: 5), .completed,
      "the folder did not show the watched mark after playing to the end")

    rootVideo.tap()
    XCTAssertTrue(ready.appears(within: 10), "the watched video never became ready")
    XCTAssertEqual(
      element(identifier: "video.resume-position").value as? String, endSeconds.map(String.init))
    let currentPosition = element(identifier: "video.current-position")
    let fromTheStart = XCTNSPredicateExpectation(
      predicate: NSPredicate { object, _ in
        guard let value = (object as? XCUIElement)?.value as? String, let seconds = Int(value)
        else { return false }
        return seconds > 0 && seconds < 30
      },
      object: currentPosition
    )
    XCTAssertEqual(
      XCTWaiter.wait(for: [fromTheStart], timeout: 10), .completed,
      "the watched video did not open from the start: \(currentPosition.value ?? "none")")
    XCTAssertFalse(element(identifier: "video.ended").exists, "the watched video opened at its end")
    done.tap()
    XCTAssertTrue(rootVideo.appears(within: 5), "the watched video did not return to the root")
  }

  func testFileActionsCreateRenameRollbackRetryAndTrash() {
    app.launch()

    let signIn = element(identifier: "auth.sign-in")
    XCTAssertTrue(signIn.appears(within: 10), "sign-in screen never appeared")
    signIn.tap()

    let root = element(identifier: "files.screen.0")
    XCTAssertTrue(root.appears(within: 10), "signed-in root browser never appeared")
    documentRowBeforeEditing()
    openBrowseMenu()
    let newFolder = app.buttons["New folder"]
    XCTAssertTrue(
      waitUntilHittable(newFolder, timeout: 5),
      "new-folder action is not tappable"
    )
    newFolder.tap()

    let newFolderAlert = nameAlert("New folder")
    XCTAssertTrue(
      newFolderAlert.staticTexts["In Files"].exists, "New folder does not name its folder")
    let create = newFolderAlert.buttons["Create"].firstMatch
    XCTAssertFalse(create.isEnabled, "Create is enabled for an empty name")
    submitName("Watch Later", in: newFolderAlert, as: "Create")

    let createdFolder = element(identifier: "files.item.415")
    XCTAssertTrue(createdFolder.appears(within: 5), "created folder never appeared")
    XCTAssertEqual(createdFolder.label.components(separatedBy: ", ").first, "Watch Later")

    openContextMenu(for: createdFolder, actionLabel: "Rename").tap()
    let renameAlert = nameAlert("Rename")
    let renameField = renameAlert.textFields.firstMatch
    let rename = renameAlert.buttons["Rename"].firstMatch
    XCTAssertEqual(renameField.value as? String, "Watch Later")
    XCTAssertFalse(rename.isEnabled, "Rename is enabled for an unchanged name")
    XCTAssertTrue(app.keyboards.firstMatch.appears(within: 5), "the name field never took focus")
    app.typeText(XCUIKeyboardKey.delete.rawValue)
    XCTAssertFalse(rename.isEnabled, "Rename is enabled for an empty name")
    submitName("Weekend", in: renameAlert, as: "Rename")

    let createdFolderButton = app.buttons["files.item.415"]
    XCTAssertTrue(
      createdFolderButton.appears(within: 3),
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
    XCTAssertEqual(createdFolderButton.label.components(separatedBy: ", ").first, "Weekend")
    let createdFolderScreen = element(identifier: "files.screen.415")
    XCTAssertFalse(
      createdFolderScreen.appears(within: 1),
      "folder navigation remained enabled while rename was pending"
    )

    let renameFailure = app.staticTexts["Couldn’t rename."]
    XCTAssertTrue(renameFailure.appears(within: 10), "rename failure was not surfaced")
    let tryAgain = app.buttons["Try again"]
    XCTAssertTrue(tryAgain.isHittable, "the rename toast offers no Try again")
    let rolledBack = createdFolderButton.label
    let reenabled = createdFolderButton.isEnabled
    addScreenshot(named: "runtime-rename-failed-toast")
    tryAgain.tap()
    XCTAssertTrue(reenabled, "folder navigation did not re-enable after rename failure")
    XCTAssertEqual(
      rolledBack.components(separatedBy: ", ").first, "Watch Later",
      "failed rename did not roll back")

    let renamedFolder = element(identifier: "files.item.415")
    let renamed = XCTNSPredicateExpectation(
      predicate: NSPredicate(format: "label == %@ OR label BEGINSWITH %@", "Weekend", "Weekend, "),
      object: renamedFolder
    )
    XCTAssertEqual(
      XCTWaiter.wait(for: [renamed], timeout: 5),
      .completed,
      "rename retry did not update the folder"
    )

    openContextMenu(for: renamedFolder, actionLabel: "Move").tap()
    XCTAssertTrue(
      element(identifier: "files.move-screen.0").appears(within: 5),
      "move picker did not open at Files"
    )
    let moveToCurrentFolder = app.buttons["Move to Files"]
    XCTAssertTrue(moveToCurrentFolder.exists, "current-folder move action is missing")
    XCTAssertFalse(moveToCurrentFolder.isEnabled, "moving to the current folder is enabled")
    XCTAssertTrue(
      element(identifier: "files.move-folder.415").exists,
      "the moved folder is not listed for its into-itself state"
    )

    let harnessDestination = element(identifier: "files.move-folder.410")
    XCTAssertTrue(
      waitUntilHittable(harnessDestination, timeout: 5),
      "Harness Folder is not available as a move destination"
    )
    harnessDestination.tap()
    XCTAssertTrue(
      element(identifier: "files.move-screen.410").appears(within: 5),
      "move picker did not enter Harness Folder"
    )
    let moveHere = app.buttons["Move to Harness Folder"]
    XCTAssertTrue(waitUntilHittable(moveHere, timeout: 5), "Move is not tappable")
    moveHere.tap()

    XCTAssertTrue(
      app.staticTexts["1 item is in the selected folder."].appears(within: 5),
      "move success was not surfaced"
    )
    XCTAssertTrue(
      renamedFolder.disappears(within: 5),
      "moved folder remained in its source list"
    )

    let harnessFolder = element(identifier: "files.item.410")
    XCTAssertTrue(waitUntilHittable(harnessFolder, timeout: 5))
    harnessFolder.tap()
    XCTAssertTrue(
      element(identifier: "files.screen.410").appears(within: 5),
      "Harness Folder did not open after the move"
    )
    let movedFolder = element(identifier: "files.item.415")
    XCTAssertTrue(
      movedFolder.appears(within: 5),
      "moved folder is missing at destination"
    )
    XCTAssertEqual(movedFolder.label.components(separatedBy: ", ").first, "Weekend")

    movedFolder.swipeRight()
    let swipeMove = app.buttons["Move"]
    XCTAssertTrue(waitUntilHittable(swipeMove, timeout: 5), "leading swipe did not offer Move")
    swipeMove.tap()
    XCTAssertTrue(
      element(identifier: "files.move-screen.0").appears(within: 5),
      "move picker did not reopen at Files"
    )
    let moveBackToRoot = app.buttons["Move to Files"]
    XCTAssertTrue(waitUntilHittable(moveBackToRoot, timeout: 5), "moving back to Files is disabled")
    moveBackToRoot.tap()
    XCTAssertTrue(
      app.staticTexts["1 item is in the selected folder."].appears(within: 5),
      "move back to Files did not settle"
    )

    let backToFiles = app.navigationBars["Harness Folder"].buttons["Files"]
    XCTAssertTrue(waitUntilHittable(backToFiles, timeout: 5), "Files back button is unavailable")
    backToFiles.tap()
    XCTAssertTrue(
      element(identifier: "files.screen.0").appears(within: 5),
      "Files did not reappear after moving to the ancestor"
    )
    let movedFolderAtRoot = element(identifier: "files.item.415")
    XCTAssertTrue(
      waitUntilHittable(movedFolderAtRoot, timeout: 5),
      "ancestor Files list did not refresh after the move"
    )
    XCTAssertEqual(movedFolderAtRoot.label.components(separatedBy: ", ").first, "Weekend")
    XCTAssertTrue(
      app.staticTexts["1 item is in the selected folder."].disappears(within: 10),
      "the move toast still covers the moved folder")

    movedFolderAtRoot.swipeLeft()
    let swipeTrash = app.buttons["Move to trash"]
    XCTAssertTrue(waitUntilHittable(swipeTrash, timeout: 5), "trailing swipe did not offer Trash")
    swipeTrash.tap()
    XCTAssertFalse(
      app.buttons["confirm-alert.confirm"].exists, "a recoverable Trash move asked to confirm")
    XCTAssertTrue(
      app.staticTexts["Moved to trash"].appears(within: 5),
      "Trash success was not surfaced"
    )
    let trashToastExpiry = Date.now.addingTimeInterval(toastDuration)
    XCTAssertTrue(
      movedFolderAtRoot.disappears(within: 5), "trashed folder remained visible")
    XCTAssertTrue(
      waitUntilHittable(app.buttons["Undo"], timeout: 5), "the Trash toast offers no Undo")

    openBrowseMenu()
    let newFolderUnderToast = app.buttons["New folder"]
    XCTAssertTrue(
      waitUntilHittable(newFolderUnderToast, timeout: 5),
      "new-folder action is unavailable while the Undo toast shows")
    newFolderUnderToast.tap()
    let alertOverToast = nameAlert("New folder")
    RunLoop.current.run(until: trashToastExpiry.addingTimeInterval(1))
    XCTAssertTrue(alertOverToast.exists, "the alert closed before the toast timed out")
    submitName("Bulk Retry", in: alertOverToast, as: "Create")
    XCTAssertFalse(
      app.buttons["Undo"].exists, "the Undo toast outlived its timeout under the alert")
    let bulkRetryFolder = element(identifier: "files.item.416")
    XCTAssertTrue(
      bulkRetryFolder.appears(within: 5),
      "a folder created after a toast timed out under its alert did not appear")
    let bulkSuccessFolder = createFolder(named: "Bulk Success", expectedID: 417)
    openBrowseMenu()
    let select = app.buttons["Select"]
    XCTAssertTrue(waitUntilHittable(select, timeout: 5), "file selection control is unavailable")
    select.tap()
    let edit = app.buttons["selection.close"]
    XCTAssertTrue(
      app.buttons["selection.action.move"].appears(within: 5),
      "the selection bar did not appear"
    )
    XCTAssertEqual(element(identifier: "files.item.413").value as? String, "Not selected")
    let bulkMove = app.buttons["selection.action.move"]
    XCTAssertFalse(bulkMove.isEnabled)
    let selectAll = app.buttons["selection.toggle-all"]
    XCTAssertTrue(
      waitUntilHittable(selectAll, timeout: 5),
      "select-all action is not hittable: \(selectAll.debugDescription)"
    )
    selectAll.tap()
    XCTAssertEqual(bulkRetryFolder.value as? String, "Selected")
    XCTAssertEqual(bulkSuccessFolder.value as? String, "Selected")
    XCTAssertTrue(bulkMove.isEnabled)
    XCTAssertTrue(waitUntilHittable(edit, timeout: 5))
    edit.tap()
    XCTAssertTrue(bulkMove.disappears(within: 5))
    openBrowseMenu()
    XCTAssertTrue(waitUntilHittable(select, timeout: 5))
    select.tap()
    XCTAssertTrue(bulkMove.appears(within: 5))
    XCTAssertEqual(bulkRetryFolder.value as? String, "Not selected")
    XCTAssertEqual(bulkSuccessFolder.value as? String, "Not selected")
    XCTAssertFalse(bulkMove.isEnabled)

    bulkRetryFolder.tap()
    XCTAssertEqual(bulkRetryFolder.value as? String, "Selected")
    bulkRetryFolder.tap()
    XCTAssertEqual(bulkRetryFolder.value as? String, "Not selected")
    bulkRetryFolder.tap()
    XCTAssertTrue(waitUntilHittable(edit, timeout: 5))
    edit.tap()
    XCTAssertTrue(bulkMove.disappears(within: 5))
    openBrowseMenu()
    XCTAssertTrue(waitUntilHittable(select, timeout: 5))
    select.tap()
    XCTAssertTrue(bulkMove.appears(within: 5))
    XCTAssertEqual(
      bulkRetryFolder.value as? String, "Not selected",
      "ending selection retained the previous selection")
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
    let bulkMoveHere = app.buttons["Move to Harness Folder"]
    XCTAssertTrue(waitUntilHittable(bulkMoveHere, timeout: 5), "bulk Move is disabled")
    bulkMoveHere.tap()
    XCTAssertTrue(
      app.staticTexts["1 item is still in Files."].appears(within: 10),
      "partial bulk-move failure was not surfaced"
    )
    XCTAssertTrue(bulkSuccessFolder.disappears(within: 5), "the moved item stayed in the list")
    XCTAssertEqual(
      bulkRetryFolder.value as? String, "Selected", "the failed item left the selection")
    XCTAssertTrue(app.staticTexts["1 selected"].exists, "the selection kept the moved item")
    let retryBulkMove = app.buttons["Try again"]
    XCTAssertTrue(waitUntilHittable(retryBulkMove, timeout: 5), "bulk move retry is unavailable")
    retryBulkMove.tap()
    XCTAssertTrue(
      app.staticTexts["1 item is in the selected folder."].appears(within: 10),
      "bulk move retry resent more than the failed item"
    )

    let harnessFolderAfterBulkMove = element(identifier: "files.item.410")
    XCTAssertTrue(waitUntilHittable(harnessFolderAfterBulkMove, timeout: 5))
    XCTAssertTrue(
      waitUntilSettled(harnessFolderAfterBulkMove, timeout: 5),
      "root rows kept moving after selection ended")
    harnessFolderAfterBulkMove.tap()
    XCTAssertTrue(
      element(identifier: "files.screen.410").appears(within: 5),
      "Harness Folder did not open for bulk removal"
    )
    let movedBulkRetryFolder = element(identifier: "files.item.416")
    let movedBulkSuccessFolder = element(identifier: "files.item.417")
    XCTAssertTrue(waitUntilHittable(movedBulkRetryFolder, timeout: 5))
    XCTAssertTrue(waitUntilHittable(movedBulkSuccessFolder, timeout: 5))

    openBrowseMenu()
    let nestedEdit = app.buttons["Select"]
    XCTAssertTrue(waitUntilHittable(nestedEdit, timeout: 5))
    nestedEdit.tap()
    XCTAssertTrue(
      app.buttons["selection.action.trash"].appears(within: 5),
      "the nested selection bar did not appear"
    )
    movedBulkRetryFolder.tap()
    movedBulkSuccessFolder.tap()
    XCTAssertEqual(movedBulkRetryFolder.value as? String, "Selected")
    XCTAssertEqual(movedBulkSuccessFolder.value as? String, "Selected")
    let bulkRemove = app.buttons["selection.action.trash"]
    XCTAssertTrue(
      waitUntilHittable(bulkRemove, timeout: 5),
      "bulk Trash is not hittable: \(bulkRemove.debugDescription)"
    )
    XCTAssertEqual(bulkRemove.label, "Trash")
    bulkRemove.tap()
    XCTAssertFalse(
      app.buttons["confirm-alert.confirm"].exists, "a recoverable bulk Trash asked to confirm")
    let bulkProgress = element(identifier: "files.bulk.progress")
    XCTAssertTrue(bulkProgress.appears(within: 5))
    XCTAssertFalse(app.buttons["BackButton"].isHittable, "back remained active during bulk work")
    XCTAssertFalse(app.buttons["Account"].isHittable, "tab remained active during bulk work")
    assertCurrentBulkProgress(bulkProgress, itemNames: ["Bulk Retry"])
    let survivingRow = element(identifier: "files.item.411")
    XCTAssertEqual(survivingRow.value as? String, "Not selected")
    survivingRow.tap()
    XCTAssertEqual(survivingRow.value as? String, "Not selected")
    XCTAssertFalse(app.buttons["selection.toggle-all"].isEnabled)
    app.swipeRight()
    XCTAssertTrue(
      element(identifier: "files.screen.410").exists,
      "edge swipe replaced the route during bulk work"
    )

    XCTAssertTrue(
      app.staticTexts["2 items are still in Files."].appears(within: 10),
      "failed bulk-Trash batch was not surfaced"
    )
    addScreenshot(named: "runtime-file-actions")
    XCTAssertTrue(movedBulkRetryFolder.exists, "failed bulk item was not restored")
    XCTAssertTrue(movedBulkSuccessFolder.exists, "failed bulk item was not restored")
    XCTAssertEqual(movedBulkRetryFolder.value as? String, "Selected")
    XCTAssertEqual(movedBulkSuccessFolder.value as? String, "Selected")
    let retryBulkRemove = app.buttons["Try again"]
    XCTAssertTrue(waitUntilHittable(retryBulkRemove, timeout: 5), "bulk retry is unavailable")
    retryBulkRemove.tap()
    XCTAssertTrue(
      app.staticTexts["Moved 2 items to trash"].appears(within: 10),
      "failed bulk batch did not succeed on retry"
    )
    XCTAssertTrue(
      movedBulkRetryFolder.disappears(within: 5),
      "retried bulk item remained visible"
    )
    XCTAssertTrue(
      movedBulkSuccessFolder.disappears(within: 5),
      "retried bulk item remained visible"
    )

    let ambiguousMoveFolder = createFolder(named: "Ambiguous Move", expectedID: 418)
    openBrowseMenu()
    let ambiguousEdit = app.buttons["Select"]
    XCTAssertTrue(waitUntilHittable(ambiguousEdit, timeout: 5))
    ambiguousEdit.tap()
    ambiguousMoveFolder.tap()
    XCTAssertEqual(ambiguousMoveFolder.value as? String, "Selected")
    let ambiguousBulkMove = app.buttons["selection.action.move"]
    XCTAssertTrue(waitUntilHittable(ambiguousBulkMove, timeout: 5))
    ambiguousBulkMove.tap()
    let moveAmbiguousToRoot = app.buttons["Move to Files"]
    XCTAssertTrue(waitUntilHittable(moveAmbiguousToRoot, timeout: 5))
    moveAmbiguousToRoot.tap()

    XCTAssertTrue(
      app.staticTexts["1 item is still in Files."].appears(within: 10),
      "ambiguous bulk-move failure was not surfaced"
    )
    XCTAssertTrue(
      ambiguousMoveFolder.disappears(within: 5),
      "authoritative source refresh did not remove the applied move"
    )
    let ambiguousDone = app.buttons["selection.close"]
    XCTAssertTrue(waitUntilHittable(ambiguousDone, timeout: 5))
    ambiguousDone.tap()

    let backToRefreshedRoot = app.navigationBars["Harness Folder"].buttons["Files"]
    XCTAssertTrue(waitUntilHittable(backToRefreshedRoot, timeout: 5))
    backToRefreshedRoot.tap()
    XCTAssertTrue(element(identifier: "files.screen.0").appears(within: 5))
    let appliedMoveAtRoot = element(identifier: "files.item.418")
    XCTAssertTrue(
      waitUntilHittable(appliedMoveAtRoot, timeout: 5),
      "already-loaded destination did not refresh after the ambiguous move"
    )
    XCTAssertEqual(appliedMoveAtRoot.label.components(separatedBy: ", ").first, "Ambiguous Move")
    assertMovePickerCreatesAFolder(for: appliedMoveAtRoot)

    app.buttons["Account"].tap()
    let signOut = app.revealed("auth.sign-out")
    XCTAssertTrue(signOut.appears(within: 5), "sign-out action never appeared")
    signOut.tap()
    app.confirmSignOut()
    XCTAssertTrue(signIn.appears(within: 10), "sign-out did not return to sign-in")
  }

  private func openSortMenu() {
    let sort = app.buttons["files.sort"]
    let ready = XCTNSPredicateExpectation(
      predicate: NSPredicate(
        format: "hittable == true AND enabled == true AND NOT (value == %@)", "Updating file order"),
      object: sort)
    XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 10), .completed, "sort is unavailable")
    sort.tap()
    XCTAssertTrue(app.staticTexts["Sort by"].appears(within: 5), "the sort menu did not open")
  }

  private func isChecked(_ choice: XCUIElement) -> Bool {
    choice.images["selected"].exists
  }

  private func imageColumn(of title: String) -> CGRect {
    let row = app.sortChoice(title).frame
    return CGRect(x: row.minX, y: row.minY, width: min(row.width, 56), height: row.height)
  }

  private func assertChecked(
    _ checked: [String], unchecked: [String], file: StaticString = #filePath, line: UInt = #line
  ) {
    for title in checked {
      let choice = app.sortChoice(title)
      XCTAssertTrue(choice.appears(within: 5), "no \(title) row", file: file, line: line)
      XCTAssertTrue(
        isChecked(choice), "\(title) is not checked: \(choice.debugDescription)", file: file,
        line: line)
    }
    for title in unchecked {
      let choice = app.sortChoice(title)
      guard choice.exists else { continue }
      XCTAssertFalse(isChecked(choice), "\(title) is checked", file: file, line: line)
    }
  }

  private func firstItem() -> XCUIElement {
    app.descendants(matching: .any).matching(
      NSPredicate(format: "identifier BEGINSWITH %@", "files.item.")
    ).firstMatch
  }

  private func waitForFirstItem(_ identifier: String) -> Bool {
    let ordered = XCTNSPredicateExpectation(
      predicate: NSPredicate(format: "identifier == %@", identifier), object: firstItem())
    return XCTWaiter.wait(for: [ordered], timeout: 10) == .completed
  }

  private func assertSortUpdated(
    firstItem id: Int, file: StaticString = #filePath, line: UInt = #line
  ) {
    let updating = element(identifier: "files.sorting.440")
    XCTAssertTrue(
      updating.shows(within: 3), "no Updating file order row", file: file, line: line)
    XCTAssertTrue(
      updating.disappears(within: 10), "the order update never settled", file: file, line: line)
    XCTAssertTrue(
      waitForFirstItem("files.item.\(id)"), "files.item.\(id) is not first", file: file,
      line: line)
  }

  private func openBrowseMenu() {
    let menu = app.buttons["files.menu"]
    XCTAssertTrue(waitUntilHittable(menu, timeout: 5), "browser menu is unavailable")
    menu.tap()
  }

  private func dismissMenu() {
    app.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.7)).tap()
  }

  private func assertMovePickerCreatesAFolder(for row: XCUIElement) {
    openContextMenu(for: row, actionLabel: "Move").tap()
    XCTAssertTrue(element(identifier: "files.move-screen.0").appears(within: 5))
    XCTAssertTrue(app.navigationBars["Move 1 item"].exists, "the sheet does not count its items")

    let newFolder = app.buttons["files.move-new-folder"]
    XCTAssertTrue(waitUntilHittable(newFolder, timeout: 5))
    newFolder.tap()
    let alert = nameAlert("New folder")
    XCTAssertTrue(alert.staticTexts["In Files"].exists, "New folder does not name its level")
    submitName("Move Destination", in: alert, as: "Create")
    let destination = element(identifier: "files.move-folder.419")
    XCTAssertTrue(destination.appears(within: 5), "new move destination did not appear")
    XCTAssertTrue(destination.label.contains("Move Destination"))
    destination.tap()
    XCTAssertTrue(element(identifier: "files.move-screen.419").appears(within: 5))
    XCTAssertTrue(
      element(identifier: "files.move-empty.419").appears(within: 5),
      "an empty level does not say it has no folders")
    tapSheetBack()
    let cancel = app.buttons["sheet.dismiss"]
    XCTAssertTrue(waitUntilHittable(cancel, timeout: 5), "the sheet lost Cancel at Files")
    cancel.tap()
    XCTAssertTrue(element(identifier: "files.move-picker").disappears(within: 5))
    XCTAssertTrue(element(identifier: "files.screen.0").appears(within: 5))
    XCTAssertTrue(
      element(identifier: "files.item.419").appears(within: 5),
      "folder created in the move picker did not reach the browser"
    )
    XCTAssertTrue(row.exists, "cancelling the move removed its source")
  }

  private func reportedPlaybackSeconds(from value: String?) -> Int? {
    reportedSeconds(of: 411, from: value)
  }

  private func reportedSeconds(of fileID: Int, from value: String?) -> Int? {
    let prefix = "id=\(fileID);seconds="
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

  private func waitUntilSettled(_ element: XCUIElement, timeout: TimeInterval) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    var previous = element.frame
    while Date() < deadline {
      RunLoop.current.run(until: Date().addingTimeInterval(0.3))
      let current = element.frame
      if current == previous { return true }
      previous = current
    }
    return false
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

  /// Mirrors the app's spoken resume position, such as "9 minutes, 49 seconds".
  private func resumeText(seconds: Int) -> String {
    Duration.seconds(seconds).formatted(
      .units(allowed: [.hours, .minutes, .seconds], width: .wide))
  }

  private func openContextMenu(
    for row: XCUIElement,
    actionLabel: String
  ) -> XCUIElement {
    XCTAssertTrue(row.isHittable, "file row is not available for its context menu")
    row.press(forDuration: 1)
    let action = app.buttons[actionLabel]
    XCTAssertTrue(action.appears(within: 5), "file context-menu action never appeared")
    return action
  }

  /// The document row opens a preview outside Edit mode; the preview journey
  /// proves that. Here it only needs to exist so edit mode can select it.
  @discardableResult
  private func documentRowBeforeEditing() -> XCUIElement {
    let documentRow = element(identifier: "files.item.413")
    XCTAssertTrue(documentRow.appears(within: 5))
    return documentRow
  }

  private func createFolder(named name: String, expectedID: Int) -> XCUIElement {
    openBrowseMenu()
    let newFolder = app.buttons["New folder"]
    XCTAssertTrue(waitUntilHittable(newFolder, timeout: 5), "new-folder action is unavailable")
    newFolder.tap()
    submitName(name, in: nameAlert("New folder"), as: "Create")
    let folder = element(identifier: "files.item.\(expectedID)")
    XCTAssertTrue(
      folder.appears(within: 5), "created folder \(expectedID) did not appear")
    XCTAssertEqual(folder.label.components(separatedBy: ", ").first, name)
    return folder
  }

  private func pullToRefresh() {
    app.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.25)).press(
      forDuration: 0.1,
      thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.85)),
      withVelocity: .slow,
      thenHoldForDuration: 1
    )
  }

  private func scrollUntilShown(_ target: XCUIElement, swipes: Int) -> Bool {
    for _ in 0..<swipes {
      if target.exists { return true }
      app.swipeUp(velocity: .fast)
    }
    return target.appears(within: 5)
  }

  private func nameAlert(_ title: String) -> XCUIElement {
    let alert = app.putioAlert(title)
    XCTAssertTrue(alert.appears(within: 5), "\(title) alert never appeared")
    return alert
  }

  private func submitName(_ name: String, in alert: XCUIElement, as submitTitle: String) {
    XCTAssertTrue(app.keyboards.firstMatch.appears(within: 5), "the name field never took focus")
    app.typeText(name)
    XCTAssertEqual(alert.textFields.firstMatch.value as? String, name)
    let submit = alert.buttons[submitTitle].firstMatch
    XCTAssertTrue(waitUntilHittable(submit, timeout: 5), "\(submitTitle) is not tappable")
    submit.tap()
    XCTAssertTrue(alert.disappears(within: 5), "the alert stayed open after \(submitTitle)")
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
