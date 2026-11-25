import XCTest

/// Drives Home, History, Account, and Trash against the seeded API with the
/// Siri Remote, recording each loaded, modal, empty, and recovery state.
final class AccountHistoryTrashJourneyTests: XCTestCase {
  private var app: XCUIApplication!
  private let remote = XCUIRemote.shared

  override func setUp() {
    continueAfterFailure = false
    app = XCUIApplication()
  }

  /// History recovers its continuation and a failed clear, and reports a
  /// missing file; clearing it turns History off on the fixture account, and
  /// Home drops it on the next account load. Trash recovers a failed listing and a failed
  /// delete, then restores everything left across both pages.
  func testHistoryAndTrashModalsEmptyStatesAndRecovery() {
    app.launchArguments = [
      "--putio-harness-scenario", "signed-in", "--putio-harness-history-disabled-after-clear",
    ]
    app.launch()

    let tabs = TVTabBar(app)
    let historyTab = tabs.item("History")
    XCTAssertTrue(historyTab.waitForExistence(timeout: 15))
    XCTAssertTrue(tabs.item("Account").exists)
    attach("runtime-tv-home")

    XCTAssertTrue(tabs.open("History"))
    remote.press(.down)
    let moreRetry = element("history.more-retry")
    XCTAssertTrue(moreRetry.waitForExistence(timeout: 15))
    XCTAssertTrue(element("history.item.809").exists)
    XCTAssertTrue(element("history.item.808").exists)
    XCTAssertTrue(element("history.item.810").exists, "TV lists every event, as iOS does")
    attach("runtime-tv-history-recovery")
    XCTAssertTrue(focus("history.more-retry"))
    remote.press(.select)
    let loadMore = element("history.load-more")
    XCTAssertTrue(
      element("history.item.806").waitForExistence(timeout: 10), "the last page never arrived")
    XCTAssertTrue(waitUntil(timeout: 10) { !moreRetry.exists && !loadMore.exists })
    XCTAssertTrue(
      focus("history.item.801", moving: .down, limit: 12),
      "every event row, file or not, takes focus down to the oldest")

    // A shared file that no longer exists says so once and offers no retry.
    XCTAssertTrue(focus("history.item.808"))
    remote.press(.select)
    XCTAssertTrue(label(containing: "File not found").waitForExistence(timeout: 10))
    attach("runtime-tv-history-open-failure")
    XCTAssertFalse(element("history.open-retry").exists, "a missing file can't be retried")

    // A failed transfer's panel shows no actions.
    XCTAssertTrue(focus("history.item.806"))
    XCTAssertTrue(waitUntil(timeout: 5) { !self.element("history.panel.play").exists })

    // The panel follows the focused event and opens its folder.
    XCTAssertTrue(focus("history.item.809"))
    XCTAssertTrue(label(containing: "1.07 GB").waitForExistence(timeout: 5))
    remote.press(.right)
    XCTAssertTrue(focus("history.panel.folder", moving: .down, limit: 3))
    remote.press(.select)
    XCTAssertTrue(element("files.item.411").waitForExistence(timeout: 10), "no folder opened")
    remote.press(.menu)
    XCTAssertTrue(element("history.panel.folder").waitForExistence(timeout: 5))
    remote.press(.left)
    XCTAssertTrue(focus("history.item.809"))
    remote.press(.select)
    // A video event opens that file's player; this one waits on its
    // conversion, whose first request fails.
    XCTAssertTrue(element("video.screen.411").waitForExistence(timeout: 10))
    XCTAssertTrue(element("video.retry").waitForExistence(timeout: 15))
    remote.press(.menu)
    XCTAssertTrue(element("history.item.809").waitForExistence(timeout: 5))

    // The fixture's first clear fails with a toast; clearing again empties
    // History. Delete confirmations open on Cancel.
    XCTAssertTrue(focus("history.clear", moving: .up))
    remote.press(.select)
    XCTAssertTrue(element("history.clear-confirm").waitForExistence(timeout: 5))
    pause(1)
    XCTAssertTrue(
      modalFocusIs("history.clear-cancel"), "the clear confirmation must open on Cancel")
    attach("runtime-tv-history-clear-modal")
    XCTAssertTrue(selectModalButton("history.clear-confirm"))
    XCTAssertTrue(label(containing: "Couldn’t clear history").waitForExistence(timeout: 10))
    XCTAssertTrue(focus("history.clear", moving: .up))
    remote.press(.select)
    XCTAssertTrue(selectModalButton("history.clear-confirm"))
    XCTAssertTrue(element("history.empty").waitForExistence(timeout: 10))
    XCTAssertTrue(isCentered(element("history.empty")), "History's empty state is off-center")
    attach("runtime-tv-history-empty")

    // Home reloads the account, which now has History off.
    XCTAssertTrue(tabs.open("Home"))
    XCTAssertTrue(waitUntil(timeout: 10) { !historyTab.exists })
    attach("runtime-tv-home-history-off")

    XCTAssertTrue(tabs.open("Account"))
    remote.press(.down)
    XCTAssertTrue(element("account.username").waitForExistence(timeout: 10))
    attach("runtime-tv-account-settings")

    // Trash walks both fixture pages.
    XCTAssertTrue(focus("account.manage-trash"))
    remote.press(.select)
    XCTAssertTrue(element("trash.item.419").waitForExistence(timeout: 10))
    XCTAssertTrue(element("trash.item.421").waitForExistence(timeout: 10))
    attach("runtime-tv-trash")

    // Reopening Trash meets the fixture's failing second listing.
    remote.press(.menu)
    XCTAssertTrue(focus("account.manage-trash"))
    remote.press(.select)
    let listRetry = element("trash.retry")
    XCTAssertTrue(listRetry.waitForExistence(timeout: 10))
    attach("runtime-tv-trash-recovery")
    XCTAssertTrue(focus("trash.retry"))
    remote.press(.select)
    XCTAssertTrue(element("trash.item.421").waitForExistence(timeout: 10))

    // Selecting a row moves to its panel. Delete confirms with Cancel
    // focused; the first permanent delete fails, the second commits and
    // hands focus to the next row.
    XCTAssertTrue(focus("trash.item.420"))
    XCTAssertTrue(element("trash.panel").exists, "Trash shows the focused item's panel")
    remote.press(.select)
    XCTAssertTrue(waitUntil(timeout: 5) { self.hasFocus("trash.panel.restore") })
    attach("runtime-tv-trash-panel")
    XCTAssertTrue(focus("trash.panel.delete", moving: .down, limit: 3))
    remote.press(.select)
    XCTAssertTrue(element("trash.delete-confirm").waitForExistence(timeout: 5))
    XCTAssertTrue(modalFocusIs("trash.delete-cancel"), "Delete must open on Cancel")
    attach("runtime-tv-trash-modal")
    XCTAssertTrue(selectModalButton("trash.delete-confirm"))
    XCTAssertTrue(
      label(containing: "The request could not start").waitForExistence(timeout: 5),
      "a failed delete must say so")
    XCTAssertTrue(waitUntil(timeout: 10) { !self.element("trash.progress").exists })
    XCTAssertTrue(element("trash.item.420").exists, "a failed delete keeps the row")
    XCTAssertTrue(focus("trash.panel.delete", moving: .down, limit: 3))
    remote.press(.select)
    XCTAssertTrue(element("trash.delete-confirm").waitForExistence(timeout: 5))
    XCTAssertTrue(selectModalButton("trash.delete-confirm"))
    XCTAssertTrue(waitUntil(timeout: 10) { !self.element("trash.item.420").exists })
    XCTAssertTrue(element("trash.item.419").exists, "the panel deleted, not restored")
    XCTAssertTrue(
      waitUntil(timeout: 5) { self.hasFocus("trash.item.421") },
      "a deleted row hands focus to the next row")

    // Restoring the last row starts, then hands focus to Restore all.
    remote.press(.select)
    XCTAssertTrue(waitUntil(timeout: 5) { self.hasFocus("trash.panel.restore") })
    remote.press(.select)
    XCTAssertTrue(label(containing: "Restore started").waitForExistence(timeout: 5))
    XCTAssertTrue(waitUntil(timeout: 10) { !self.element("trash.item.421").exists })
    XCTAssertTrue(
      waitUntil(timeout: 5) { self.hasFocus("trash.restore-all") },
      "the last restored row hands focus to Restore all")
    remote.press(.select)
    XCTAssertTrue(element("trash.empty-state").waitForExistence(timeout: 15))
    XCTAssertTrue(isCentered(element("trash.empty-state")), "Trash's empty state is off-center")
    attach("runtime-tv-trash-empty")
    remote.press(.menu)
    XCTAssertTrue(
      element("account.manage-trash").waitForExistence(timeout: 5),
      "Menu left the empty trash's app")
  }

  /// Settings cycle in place, the proxy menu recovers a failed listing, a
  /// failed save, and a failed confirmation refresh, turning Trash off is
  /// confirmed in an alert, and the focused row's panel explains it.
  func testSettingsCycleProxyChooserAndTrashToggle() {
    app.launchArguments = [
      "--putio-harness-scenario", "signed-in", "--putio-harness-playback-preferences",
      "--putio-harness-reset-file-preferences",
    ]
    app.launch()

    XCTAssertTrue(TVTabBar(app).open("Account"))
    remote.press(.down)
    XCTAssertTrue(element("account.username").waitForExistence(timeout: 10))

    XCTAssertTrue(focus("account.proxy"))
    remote.press(.select)
    let proxyRetry = menuItem("Try again")
    XCTAssertTrue(proxyRetry.waitForExistence(timeout: 10))
    attach("runtime-tv-proxy-failure")
    XCTAssertTrue(focusMenuItem(proxyRetry))
    remote.press(.select)
    XCTAssertTrue(waitUntil(timeout: 5) { !proxyRetry.exists })

    // A menu keeps the items it opened with, so it reopens until the
    // retried listing has loaded.
    let edge = menuItem("edge")
    for _ in 0..<4 {
      XCTAssertTrue(focus("account.proxy"))
      remote.press(.select)
      if edge.waitForExistence(timeout: 3) { break }
      remote.press(.menu)
      pause(1)
    }
    XCTAssertTrue(edge.exists, "the retried proxy listing never loaded")
    attach("runtime-tv-proxy-chooser")
    XCTAssertTrue(focusMenuItem(edge))
    remote.press(.select)

    // The first save fails, then the committed save's account reload fails
    // once; each offers a retry until the account confirms the new route.
    let settingsRetry = element("account.settings-retry")
    var retries = 0
    while retries < 3, waitUntil(timeout: 8, { settingsRetry.exists && settingsRetry.isEnabled }) {
      XCTAssertTrue(focus("account.settings-retry", moving: .up, limit: 16))
      remote.press(.select)
      retries += 1
      _ = waitUntil(timeout: 5) { !(settingsRetry.exists && settingsRetry.isEnabled) }
    }
    XCTAssertEqual(retries, 2)
    XCTAssertTrue(focus("account.proxy"))
    let proxy = element("account.proxy")
    XCTAssertTrue(
      waitUntil(timeout: 10) { proxy.exists && (proxy.value as? String) == "edge" },
      "the account never confirmed the new route")

    let subtitles = element("account.show-subtitles")
    XCTAssertTrue(focus("account.show-subtitles"))
    XCTAssertEqual(subtitles.value as? String, "On")
    XCTAssertTrue(element("account.subtitle-selection").exists)
    remote.press(.select)
    XCTAssertTrue(waitUntil(timeout: 10) { subtitles.value as? String == "Off" })
    XCTAssertTrue(waitUntil(timeout: 5) { !self.element("account.subtitle-selection").exists })
    attach("runtime-tv-account-subtitles-off")
    remote.press(.select)
    XCTAssertTrue(waitUntil(timeout: 10) { subtitles.value as? String == "On" })
    XCTAssertTrue(element("account.subtitle-selection").waitForExistence(timeout: 5))

    let trash = element("account.trash")
    XCTAssertTrue(focus("account.trash"))
    XCTAssertEqual(trash.value as? String, "On")
    remote.press(.select)
    XCTAssertTrue(element("account.trash-disable-confirm").waitForExistence(timeout: 5))
    attach("runtime-tv-trash-off-modal")
    XCTAssertTrue(selectModalButton("account.trash-disable-confirm"))
    XCTAssertTrue(waitUntil(timeout: 10) { trash.value as? String == "Off" })
    XCTAssertFalse(element("account.manage-trash").exists)

    // App info sits near the end of the list; its panel lists the details
    // support asks for.
    XCTAssertTrue(focus("account.app-info", moving: .down, limit: 16))
    let player = element("account.app-info.player")
    XCTAssertTrue(player.waitForExistence(timeout: 5))
    XCTAssertTrue(isOnScreen(player), "the app info panel is off screen")
    attach("runtime-tv-account-about")
    XCTAssertTrue(focus("account.trash", moving: .up, limit: 16))
    remote.press(.select)
    XCTAssertTrue(waitUntil(timeout: 10) { trash.value as? String == "On" })
    XCTAssertTrue(element("account.manage-trash").waitForExistence(timeout: 5))
  }

  // MARK: - Remote helpers

  /// A system menu's item: menus drop the identifiers of their buttons, so
  /// items are found by title.
  private func menuItem(_ title: String) -> XCUIElement {
    app.cells.containing(NSPredicate(format: "label == %@", title)).firstMatch
  }

  /// Menus open on their checked item; moving past an end closes them, so
  /// focus walks down only.
  private func focusMenuItem(_ item: XCUIElement) -> Bool {
    let isFocused = {
      item.hasFocus
        || item.descendants(matching: .any).matching(NSPredicate(format: "hasFocus == true"))
          .firstMatch.exists
    }
    for _ in 0..<6 {
      if waitUntil(timeout: 1, isFocused) { return true }
      guard item.exists else { return false }
      remote.press(.down)
    }
    return isFocused()
  }

  private func element(_ identifier: String) -> XCUIElement {
    app.descendants(matching: .any).matching(identifier: identifier).firstMatch
  }

  private func label(containing text: String) -> XCUIElement {
    app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", text))
      .firstMatch
  }

  private func isOnScreen(_ element: XCUIElement) -> Bool {
    guard element.exists, !element.frame.isEmpty else { return false }
    return app.windows.firstMatch.frame.contains(element.frame)
  }

  /// A full-screen empty or failure state sits in the middle of the screen
  /// below the header, as in the shipped app, not in its top-left corner.
  private func isCentered(_ element: XCUIElement) -> Bool {
    guard element.exists, !element.frame.isEmpty else { return false }
    let screen = app.windows.firstMatch.frame
    let frame = element.frame
    return abs(frame.midX - screen.midX) < screen.width * 0.05
      && frame.midY > screen.minY + screen.height * 0.3
      && frame.midY < screen.minY + screen.height * 0.75
  }

  /// Account's menus never report `hasFocus`; the panel names the row they
  /// focus instead.
  private func hasFocus(_ identifier: String) -> Bool {
    if Self.menuRows.contains(identifier) {
      return app.descendants(matching: .any)["account.panel.\(identifier)"].exists
        && !app.descendants(matching: .any)
          .matching(NSPredicate(format: "identifier BEGINSWITH 'account.' AND hasFocus == true"))
          .firstMatch.exists
    }
    return app.descendants(matching: .any)
      .matching(NSPredicate(format: "identifier == %@ AND hasFocus == true", identifier))
      .firstMatch.exists
  }

  private static let menuRows: Set<String> = ["account.default-sort", "account.proxy"]

  /// Moves focus onto the element with the remote: down first, then up,
  /// bounded so a screen that never offers it still fails.
  private func focus(_ identifier: String) -> Bool {
    focus(identifier, moving: .down, limit: 8) || focus(identifier, moving: .up, limit: 16)
  }

  private func focus(
    _ identifier: String, moving direction: XCUIRemote.Button, limit: Int = 10
  ) -> Bool {
    for _ in 0..<limit {
      if waitUntil(timeout: 0.75, { self.hasFocus(identifier) }) { return true }
      remote.press(direction)
    }
    return waitUntil(timeout: 1.5) { self.hasFocus(identifier) }
  }

  /// Steers the remote to an alert button and selects it. Each alert button
  /// appears twice in the tree, with only the outer copy reporting focus, so
  /// the focused copy is matched to the target by frame.
  private func selectModalButton(_ identifier: String) -> Bool {
    let target = app.buttons[identifier]
    guard target.waitForExistence(timeout: 5) else { return false }
    // Presses during the presentation animation are dropped.
    pause(1)
    let goal = target.frame
    for _ in 0..<8 {
      let focused = app.buttons.matching(NSPredicate(format: "hasFocus == true")).firstMatch
      guard focused.exists else { return false }
      let current = focused.frame
      if abs(current.midX - goal.midX) < 4, abs(current.midY - goal.midY) < 4 {
        remote.press(.select)
        return waitUntil(timeout: 5) { !target.exists }
      }
      if abs(current.midY - goal.midY) >= 4 {
        remote.press(goal.midY > current.midY ? .down : .up)
      } else {
        remote.press(goal.midX > current.midX ? .right : .left)
      }
      pause(0.5)
    }
    return false
  }

  private func modalFocusIs(_ identifier: String) -> Bool {
    let target = app.buttons[identifier]
    let focused = app.buttons.matching(NSPredicate(format: "hasFocus == true")).firstMatch
    guard target.exists, focused.exists else { return false }
    return abs(focused.frame.midX - target.frame.midX) < 4
      && abs(focused.frame.midY - target.frame.midY) < 4
  }

  private func pause(_ seconds: TimeInterval) {
    RunLoop.current.run(until: Date().addingTimeInterval(seconds))
  }

  private func waitUntil(timeout: TimeInterval, _ condition: () -> Bool) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
      if condition() { return true }
      RunLoop.current.run(until: Date().addingTimeInterval(0.25))
    }
    return condition()
  }

  private func attach(_ name: String) {
    let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
    attachment.name = name
    attachment.lifetime = .keepAlways
    add(attachment)
  }
}
