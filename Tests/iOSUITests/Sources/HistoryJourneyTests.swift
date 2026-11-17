import XCTest

final class HistoryJourneyTests: XCTestCase {
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

  func testHistoryPagingNavigationMutationsAndSettingGate() {
    app.launch()
    signIn()
    let history = app.buttons["History"]
    XCTAssertTrue(history.appears(within: 5))
    history.tap()
    let folderEvent = element("history.item.810")
    let missingEvent = element("history.item.808")
    XCTAssertTrue(folderEvent.appears(within: 10))
    XCTAssertTrue(app.staticTexts["Today"].exists)
    XCTAssertTrue(missingEvent.label.contains("Shared with you"), "a share does not say so")
    XCTAssertFalse(missingEvent.label.contains("Fixture Friend"), "a share still names its sender")
    XCTAssertFalse(
      app.staticTexts.matching(NSPredicate(format: "label ENDSWITH %@", " ago")).firstMatch.exists,
      "event times must read as times of day")
    XCTAssertFalse(element("history.item.807").exists, "unknown event was rendered")
    let moreRetry = app.buttons["history.more-retry"]
    reveal(moreRetry)
    XCTAssertTrue(folderEvent.exists, "failed continuation removed the first page")
    XCTAssertTrue(
      app.staticTexts["Couldn’t load more history."].exists, "the failed page has no message")
    XCTAssertFalse(
      app.staticTexts["Retry History continuation"].exists, "the footer shows the raw failure")
    moreRetry.tap()
    reveal(element("history.item.806"))
    XCTAssertTrue(app.staticTexts["Yesterday"].exists)
    for id in [805, 804, 803, 802, 801] {
      reveal(element("history.item.\(id)"))
      if id == 803 { XCTAssertTrue(app.staticTexts[dayTitle(daysAgo: 3)].exists) }
      if id == 801 { XCTAssertTrue(app.staticTexts[dayTitle(daysAgo: 10)].exists) }
    }
    XCTAssertFalse(app.buttons["history.item.801"].exists, "an event without a file is a button")
    XCTAssertFalse(element("history.more").exists, "the last page still loads more")
    XCTAssertFalse(element("history.more-error").exists, "the last page still shows a failure")
    let failedTransfer = element("history.item.806")
    reveal(failedTransfer)
    XCTAssertTrue(failedTransfer.label.contains("Transfer failed"))
    XCTAssertFalse(app.buttons["history.item.806"].exists, "a transfer event is a button")
    failedTransfer.tap()
    XCTAssertTrue(failedTransfer.exists, "tapping a transfer event left History")
    XCTAssertFalse(
      app.staticTexts[navigationBlocked].appears(within: 3), "a transfer event tried to open")
    XCTAssertFalse(moreRetry.exists)
    scrollToTop()
    addScreenshot(named: "runtime-history-loaded")

    pullToRefresh()
    let refreshRetry = app.buttons["history.retry"]
    XCTAssertTrue(refreshRetry.appears(within: 10))
    XCTAssertTrue(folderEvent.exists, "failed refresh discarded loaded history")
    addScreenshot(named: "runtime-history-error")
    refreshRetry.tap()
    XCTAssertTrue(refreshRetry.disappears(within: 10))
    XCTAssertTrue(folderEvent.appears(within: 5))

    reveal(missingEvent)
    missingEvent.tap()
    XCTAssertTrue(app.staticTexts[navigationBlocked].appears(within: 10), "no blocked toast")
    XCTAssertTrue(missingEvent.exists, "missing file removed its history event")
    XCTAssertFalse(app.buttons["history.open-retry"].exists, "a missing file offered a retry")
    addScreenshot(named: "runtime-history-navigation-blocked")
    XCTAssertTrue(
      app.staticTexts[navigationBlocked].disappears(within: 10), "the blocked toast never left")

    reveal(folderEvent)
    folderEvent.tap()
    XCTAssertTrue(element("files.screen.410").appears(within: 10))
    XCTAssertTrue(element("files.item.411").exists)
    app.navigationBars.buttons["BackButton"].tap()
    XCTAssertTrue(folderEvent.appears(within: 5))
    let videoEvent = element("history.item.809")
    reveal(videoEvent)
    videoEvent.tap()
    XCTAssertTrue(element("video.error").appears(within: 10))
    app.buttons["Try again"].tap()
    app.answerResumePrompt()
    XCTAssertTrue(element("video.ready").appears(within: 15))
    app.closeVideo()
    XCTAssertTrue(folderEvent.appears(within: 5))

    reveal(videoEvent)
    videoEvent.swipeLeft()
    let delete = app.buttons["history.swipe.delete"]
    XCTAssertTrue(waitUntilHittable(delete))
    delete.tap()
    XCTAssertTrue(app.staticTexts["Couldn’t delete"].appears(within: 10), "no delete failure toast")
    XCTAssertTrue(videoEvent.appears(within: 5), "failed deletion removed its event")
    addScreenshot(named: "runtime-history-delete-failed")
    let mutationRetry = app.buttons["history.mutation-retry"]
    XCTAssertFalse(mutationRetry.exists, "a failed deletion offered a retry row")
    XCTAssertTrue(
      app.staticTexts["Couldn’t delete"].disappears(within: 10), "the delete toast never left")
    reveal(videoEvent)
    let rowStart = videoEvent.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5))
    let rowEnd = videoEvent.coordinate(withNormalizedOffset: CGVector(dx: 0.05, dy: 0.5))
    rowStart.press(
      forDuration: 0.05, thenDragTo: rowEnd, withVelocity: .fast, thenHoldForDuration: 0)
    XCTAssertTrue(videoEvent.disappears(within: 5), "a full swipe did not delete the event")

    let earlierUpload = element("history.item.801")
    reveal(earlierUpload)
    let earlierDay = app.staticTexts[dayTitle(daysAgo: 10)]
    XCTAssertTrue(earlierDay.exists)
    earlierUpload.swipeLeft()
    XCTAssertTrue(waitUntilHittable(delete))
    delete.tap()
    XCTAssertTrue(earlierUpload.disappears(within: 5), "the swiped event stayed")
    XCTAssertTrue(earlierDay.disappears(within: 5), "an emptied day kept its header")

    scrollToTop()
    pullToRefresh()
    XCTAssertTrue(folderEvent.appears(within: 10))
    reveal(element("history.item.802"))
    XCTAssertFalse(videoEvent.exists, "refresh restored a deleted event")
    XCTAssertFalse(earlierUpload.exists, "refresh restored a deleted event")
    signOut()
    signIn()
    history.tap()
    XCTAssertTrue(folderEvent.appears(within: 10))
    reveal(element("history.item.802"))
    XCTAssertFalse(videoEvent.exists, "the server kept a deleted event")
    XCTAssertFalse(earlierUpload.exists, "the server kept a deleted event")
    scrollToTop()

    let menu = app.buttons["history.menu"]
    let clearAlert = app.putioAlert("Clear history?")
    let confirm = app.buttons["confirm-alert.confirm"].firstMatch
    chooseClearHistory()
    XCTAssertTrue(clearAlert.appears(within: 5), "Clear history never asked")
    app.buttons["putio-alert.cancel"].firstMatch.tap()
    XCTAssertTrue(clearAlert.disappears(within: 5), "Cancel left the clear alert open")
    XCTAssertTrue(folderEvent.exists, "cancel cleared history")
    chooseClearHistory()
    XCTAssertTrue(waitUntilHittable(confirm))
    confirm.tap()
    let clearFailed = app.putioAlert("Couldn’t clear history")
    XCTAssertTrue(
      clearFailed.appears(within: 10),
      "the first clear succeeded, so Cancel sent a clear or the seeded failure is gone")
    XCTAssertTrue(app.staticTexts["Check your connection and try again."].exists)
    XCTAssertTrue(folderEvent.exists, "failed clear discarded history")
    XCTAssertFalse(mutationRetry.exists, "a failed clear offered a retry row")
    app.buttons["history.clear-failed.ok"].tap()
    XCTAssertTrue(clearFailed.disappears(within: 5), "OK left the failure alert open")
    XCTAssertTrue(waitUntilHittable(menu), "More stayed disabled after a failed clear")
    chooseClearHistory()
    XCTAssertTrue(waitUntilHittable(confirm))
    confirm.tap()
    XCTAssertTrue(app.staticTexts["No history yet"].appears(within: 10))
    XCTAssertFalse(menu.exists, "the cleared History offers More")
    addScreenshot(named: "runtime-history-empty")
    pullToRefresh()
    XCTAssertTrue(app.staticTexts["No history yet"].appears(within: 5))

    app.buttons["Files"].tap()
    XCTAssertTrue(element("files.item.410").appears(within: 5))
    XCTAssertTrue(element("files.item.412").exists, "clearing history deleted files")
    element("files.item.410").tap()
    XCTAssertTrue(element("files.screen.410").appears(within: 10))
    XCTAssertTrue(element("files.item.411").exists, "deleting an event deleted its file")
    app.navigationBars.buttons["BackButton"].tap()
    XCTAssertTrue(element("files.screen.0").appears(within: 5))
    signOut()
    app.terminate()
    app.launchArguments.append("--putio-harness-history-disabled")
    app.launch()
    signIn()
    XCTAssertFalse(app.buttons["History"].exists, "disabled history remained in the tab bar")
    signOut()
  }

  func testHistoryFirstLoadStates() {
    let firstEvent = element("history.item.907")

    openHistory("slow")
    XCTAssertTrue(labeled("Loading history").appears(within: 5), "History shows no spinner")
    addScreenshot(named: "runtime-history-loading")
    app.buttons["Files"].tap()
    XCTAssertTrue(element("files.screen.0").appears(within: 5))
    app.buttons["History"].tap()
    XCTAssertTrue(
      firstEvent.appears(within: 10),
      "returning to History did not reload it, or leaving History kept the first list in flight")
    leaveHistory()

    openHistory("empty")
    XCTAssertTrue(app.staticTexts["No history yet"].appears(within: 10))
    XCTAssertTrue(
      app.staticTexts["Completed transfers and shared files will appear here."].exists)
    XCTAssertFalse(app.buttons["history.menu"].exists, "the empty History offers More")
    addScreenshot(named: "runtime-history-first-empty")
    pullToRefresh()
    XCTAssertTrue(firstEvent.appears(within: 10), "pull to refresh left History empty")
    leaveHistory()

    openHistory("failing")
    let retry = app.buttons["history.retry"]
    XCTAssertTrue(retry.appears(within: 10), "History never failed")
    XCTAssertTrue(app.staticTexts["Couldn’t load history"].exists)
    XCTAssertTrue(app.staticTexts["Check your connection and try again."].exists)
    XCTAssertFalse(app.buttons["history.menu"].exists, "failed History offers More")
    addScreenshot(named: "runtime-history-first-error")
    retry.tap()
    XCTAssertTrue(firstEvent.appears(within: 10), "Try again did not load History")
    leaveHistory()

    openHistory("offline")
    XCTAssertTrue(app.staticTexts["put.io is out of reach"].appears(within: 10))
    XCTAssertTrue(
      app.staticTexts["Your connection dropped, or we did. Retrying on its own."].exists)
    addScreenshot(named: "runtime-history-offline")
    XCTAssertTrue(firstEvent.appears(within: 20), "offline History never retried on its own")
    leaveHistory()
  }

  private func openHistory(_ mode: String) {
    app.launchArguments = [
      "--putio-harness-scenario", "files-browser", "--putio-harness-history", mode,
    ]
    app.launch()
    signIn()
    let history = app.buttons["History"]
    XCTAssertTrue(history.appears(within: 5))
    history.tap()
    XCTAssertTrue(app.navigationBars["History"].appears(within: 5), "History never opened")
  }

  private func leaveHistory() {
    signOut()
    app.terminate()
  }

  private func labeled(_ label: String) -> XCUIElement {
    app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", label)).firstMatch
  }

  private let navigationBlocked =
    "This item cannot be opened right now. Check Files, then try again."

  private func dayTitle(daysAgo: Int) -> String {
    let calendar = Calendar.current
    let today = calendar.startOfDay(for: .now)
    let day = calendar.date(byAdding: .day, value: -daysAgo, to: today) ?? today
    let style = Date.FormatStyle().month(.abbreviated).day()
    let sameYear = calendar.component(.year, from: day) == calendar.component(.year, from: today)
    return day.formatted(sameYear ? style : style.year())
  }

  private func signIn() {
    let signIn = element("auth.sign-in")
    XCTAssertTrue(signIn.appears(within: 10))
    signIn.tap()
    XCTAssertTrue(element("files.screen.0").appears(within: 10))
  }

  private func signOut() {
    app.buttons["Account"].tap()
    let signOut = app.revealed("auth.sign-out")
    XCTAssertTrue(signOut.appears(within: 5))
    signOut.tap()
    app.confirmSignOut()
    XCTAssertTrue(element("auth.sign-in").appears(within: 10))
  }

  private func element(_ identifier: String) -> XCUIElement {
    app.descendants(matching: .any)[identifier]
  }

  private func chooseClearHistory() {
    let menu = app.buttons["history.menu"]
    XCTAssertTrue(waitUntilHittable(menu), "History has no More menu")
    menu.tap()
    let clear = app.descendants(matching: .any)
      .matching(NSPredicate(format: "label == %@", "Clear history")).firstMatch
    XCTAssertTrue(waitUntilHittable(clear), "More has no Clear history")
    clear.tap()
  }

  private func waitUntilHittable(_ element: XCUIElement) -> Bool {
    let expectation = XCTNSPredicateExpectation(
      predicate: NSPredicate(format: "hittable == true AND enabled == true"), object: element
    )
    return XCTWaiter.wait(for: [expectation], timeout: 5) == .completed
  }

  private func reveal(_ element: XCUIElement) {
    for _ in 0..<4 {
      if element.exists && element.isHittable { return }
      app.swipeUp()
    }
    XCTAssertTrue(waitUntilHittable(element), "history element unavailable: \(element)")
  }

  private func scrollToTop() {
    for _ in 0..<4 {
      if element("history.item.810").isHittable { return }
      app.swipeDown()
    }
    XCTAssertTrue(waitUntilHittable(element("history.item.810")))
  }

  private func pullToRefresh() {
    let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.28))
    let end = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.8))
    start.press(forDuration: 0.1, thenDragTo: end, withVelocity: .slow, thenHoldForDuration: 1)
  }

  private func addScreenshot(named name: String) {
    let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
    attachment.name = name
    attachment.lifetime = .keepAlways
    add(attachment)
  }
}
