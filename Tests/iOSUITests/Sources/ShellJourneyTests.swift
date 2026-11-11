import UIKit
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
      let folder = element("files.screen.410")
      XCTAssertFalse(
        folder.exists && folder.isHittable, "\(tab) did not replace the Files content")
    }
    searchTab().tap()
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
    signOut()
  }

  func testIPadSidebarAndRotationKeepTheOpenFolder() throws {
    try XCTSkipUnless(
      UIDevice.current.userInterfaceIdiom == .pad, "the sidebar exists on iPad only")
    XCUIDevice.shared.orientation = .landscapeLeft
    app.launch()
    signIn()
    openFolder()
    addScreenshot(named: "shell-ipad-landscape")

    let showSidebar = sidebarToggle()
    XCTAssertTrue(showSidebar.appears(within: 5), "the top tabs have no sidebar button")
    showSidebar.tap()
    let storage = element("shell.storage")
    XCTAssertTrue(storage.appears(within: 5), "the sidebar has no storage meter")
    XCTAssertTrue(element("files.screen.410").exists, "opening the sidebar reset the Files path")
    addScreenshot(named: "shell-ipad-sidebar")

    sidebarToggle().tap()
    XCTAssertTrue(storage.disappears(within: 5), "the sidebar did not close")
    XCTAssertTrue(element("files.screen.410").exists, "closing the sidebar reset the Files path")

    XCUIDevice.shared.orientation = .portrait
    XCTAssertTrue(
      element("files.screen.410").appears(within: 5), "rotating reset the Files path")
    addScreenshot(named: "shell-ipad-portrait")
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

  private func sidebarToggle() -> XCUIElement {
    app.buttons.matching(NSPredicate(format: "label CONTAINS[c] %@", "sidebar")).firstMatch
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
