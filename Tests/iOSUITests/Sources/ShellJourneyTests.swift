import XCTest

final class ShellJourneyTests: XCTestCase {
  private var app: XCUIApplication!

  override func setUpWithError() throws {
    try super.setUpWithError()
    continueAfterFailure = false
    XCUIDevice.shared.orientation = .portrait
    app = XCUIApplication()
    app.launchArguments = ["--putio-harness-scenario", "files-browser"]
    app.launchEnvironment["PUTIO_HARNESS_MEDIA_BASE_URL"] = try XCTUnwrap(
      ProcessInfo.processInfo.environment["PUTIO_HARNESS_MEDIA_BASE_URL"]
    )
  }

  override func tearDown() {
    XCUIDevice.shared.orientation = .portrait
    super.tearDown()
  }

  func testEveryTabKeepsTheOpenFolder() {
    app.launch()
    signIn()
    openFolder()
    addScreenshot(named: "shell-folder-open")

    for tab in ["Downloads", "History", "Account"] {
      let button = tabButton(tab)
      XCTAssertTrue(button.appears(within: 5), "\(tab) tab is missing")
      button.tap()
      XCTAssertTrue(
        element("files.screen.410").disappears(within: 5),
        "\(tab) did not replace the Files content")
    }
    let search = searchTab()
    XCTAssertGreaterThan(
      search.frame.minX, tabButton("Account").frame.maxX + 8,
      "Search sits inside the tab bar instead of beside it")
    search.tap()
    XCTAssertTrue(app.searchFields.firstMatch.appears(within: 5), "Search opened no field")
    app.buttons["Close"].tap()
    tabButton("Files").tap()
    XCTAssertTrue(
      element("files.screen.410").appears(within: 5), "switching tabs reset the Files path")
    signOut()
  }

  func testHistoryOffHidesTheHistoryTab() {
    app.launchArguments.append("--putio-harness-history-disabled")
    app.launch()
    signIn()
    XCTAssertTrue(tabButton("Downloads").appears(within: 5))
    XCTAssertTrue(tabButton("Account").exists)
    XCTAssertFalse(tabButton("History").exists, "disabled history remained in the tab bar")
    addScreenshot(named: "shell-history-off")
    for tab in ["Downloads", "Account", "Files"] {
      tabButton(tab).tap()
    }
    XCTAssertTrue(element("files.screen.0").appears(within: 5))
    searchTab().tap()
    XCTAssertTrue(app.searchFields.firstMatch.appears(within: 5), "Search opened no field")
    app.buttons["Close"].tap()
    signOut()
  }

  func testHistorySettingTogglesTheTabWithoutRequests() {
    app.launchArguments += [
      "--putio-harness-file-preferences", "--putio-harness-reset-file-preferences",
    ]
    app.launch()
    signIn()
    XCTAssertTrue(tabButton("History").appears(within: 5))
    XCTAssertTrue(historyRequests.hasValue("0", within: 2), "History loaded before it was opened")

    tabButton("Account").tap()
    let setting = app.switches["settings.history"]
    let alert = app.putioAlert("Turn off history?")
    tapToggle(setting)
    let confirm = alert.buttons["Turn off"].firstMatch
    XCTAssertTrue(confirm.appears(within: 5), "turning history off asked for no confirmation")
    confirm.tap()
    app.showTabBar()
    XCTAssertTrue(
      tabButton("History").disappears(within: 5), "History stayed in the tab bar after turning off")
    addScreenshot(named: "shell-history-toggle-off")

    tapToggle(setting)
    app.showTabBar()
    XCTAssertTrue(
      tabButton("History").appears(within: 5), "History did not return without a relaunch")
    addScreenshot(named: "shell-history-toggle-on")
    tabButton("History").tap()
    let requested = XCTNSPredicateExpectation(
      predicate: NSPredicate(format: "value != %@", "0"), object: historyRequests)
    XCTAssertEqual(
      XCTWaiter.wait(for: [requested], timeout: 10), .completed,
      "the History requests probe did not count an opened History")
    signOut()
  }

  func testHistoryTurnedOffWhileOpenLandsOnFiles() throws {
    app.launchArguments.append("--putio-harness-history-off-after-load")
    app.launch()
    signIn()
    let history = tabButton("History")
    XCTAssertTrue(history.appears(within: 5))
    history.tap()
    XCTAssertTrue(element("history.item.810").appears(within: 10), "History never loaded")
    let loadedRequests = try XCTUnwrap(historyRequests.value as? String)
    XCTAssertNotEqual(loadedRequests, "0", "the History requests probe did not count the load")

    XCUIDevice.shared.press(.home)
    app.activate()
    XCTAssertTrue(
      history.disappears(within: 10), "History stayed in the tab bar after it was turned off")
    XCTAssertTrue(
      element("files.screen.0").appears(within: 5), "turning History off did not land on Files")
    XCTAssertTrue(tabButton("Files").isSelected, "the Files tab is not selected")
    XCTAssertFalse(element("account.privacy").exists, "turning History off landed on Account")
    let requestedAgain = XCTNSPredicateExpectation(
      predicate: NSPredicate(format: "value != %@", loadedRequests), object: historyRequests)
    XCTAssertEqual(
      XCTWaiter.wait(for: [requestedAgain], timeout: 3), .timedOut,
      "History was requested after it was turned off")
    addScreenshot(named: "shell-history-off-while-open")
    signOut()
  }

  private func openFolder() {
    let folder = element("files.item.410")
    XCTAssertTrue(folder.appears(within: 10))
    folder.tap()
    XCTAssertTrue(element("files.screen.410").appears(within: 10))
  }

  private func signIn() {
    let signIn = element("auth.sign-in")
    XCTAssertTrue(signIn.appears(within: 10))
    signIn.tap()
    XCTAssertTrue(element("files.screen.0").appears(within: 10))
  }

  private func signOut() {
    tabButton("Account").tap()
    let signOut = app.revealed("auth.sign-out")
    XCTAssertTrue(signOut.appears(within: 5))
    signOut.tap()
    app.confirmSignOut()
    XCTAssertTrue(element("auth.sign-in").appears(within: 10))
  }

  private func tabButton(_ label: String) -> XCUIElement {
    app.buttons.matching(NSPredicate(format: "label == %@", label)).firstMatch
  }

  private func searchTab() -> XCUIElement {
    let search = tabButton("Search")
    XCTAssertTrue(search.appears(within: 5), "the Search tab is missing")
    return search
  }

  private var historyRequests: XCUIElement {
    element("history.requests")
  }

  private func tapToggle(_ toggle: XCUIElement) {
    app.bringIntoView(toggle)
    let ready = XCTNSPredicateExpectation(
      predicate: NSPredicate(format: "hittable == true AND enabled == true"), object: toggle)
    XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 10), .completed)
    toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
  }

  private func element(_ identifier: String) -> XCUIElement {
    app.descendants(matching: .any)[identifier]
  }

  private func addScreenshot(named name: String) {
    let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
    attachment.name = name
    attachment.lifetime = .keepAlways
    add(attachment)
  }
}
