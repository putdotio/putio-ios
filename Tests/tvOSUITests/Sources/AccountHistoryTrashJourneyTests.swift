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

  /// History recovers its continuation, a missing file, and a failed clear;
  /// clearing it turns History off on the fixture account, and Home drops it
  /// on the next account load. Trash recovers a failed listing and a failed
  /// delete, then restores everything left across both pages.
  func testHistoryAndTrashModalsEmptyStatesAndRecovery() {
    app.launchArguments = [
      "--putio-harness-scenario", "signed-in", "--putio-harness-history-disabled-after-clear",
    ]
    app.launch()

    let homeHistory = element("home.history")
    let homeAccount = element("home.account")
    XCTAssertTrue(homeHistory.waitForExistence(timeout: 15))
    XCTAssertTrue(homeAccount.exists)
    attach("runtime-tv-home")

    XCTAssertTrue(focus("home.history"))
    remote.press(.select)
    let moreRetry = element("history.more-retry")
    XCTAssertTrue(moreRetry.waitForExistence(timeout: 15))
    XCTAssertTrue(element("history.item.809").exists)
    XCTAssertTrue(element("history.item.808").exists)
    XCTAssertFalse(element("history.item.810").exists, "uploads are not TV events")
    attach("runtime-tv-history-recovery")
    XCTAssertTrue(focus("history.more-retry"))
    remote.press(.select)
    // The retried page holds only events TV hides, so the end of the list
    // shows as neither a retry nor a loading row, and the first page stays.
    let loadMore = element("history.load-more")
    XCTAssertTrue(waitUntil(timeout: 10) { !moreRetry.exists && !loadMore.exists })
    pause(1)
    XCTAssertFalse(moreRetry.exists, "the retried page failed again")
    XCTAssertFalse(loadMore.exists, "the list never reached its end")
    XCTAssertTrue(element("history.item.809").exists)

    // A shared file that no longer exists offers a retry and a dismissal.
    XCTAssertTrue(focus("history.item.808"))
    remote.press(.select)
    let openRetry = element("history.open-retry")
    XCTAssertTrue(openRetry.waitForExistence(timeout: 10))
    attach("runtime-tv-history-open-failure")
    XCTAssertTrue(focus("history.open-retry.dismiss"))
    remote.press(.select)
    XCTAssertTrue(waitUntil(timeout: 5) { !openRetry.exists })

    XCTAssertTrue(focus("history.item.809"))
    remote.press(.select)
    // A video event opens the playback hand-off point for that file.
    XCTAssertTrue(element("file.playback-placeholder.411").waitForExistence(timeout: 10))
    XCTAssertTrue(label(containing: "Nested Movie.mkv").exists)
    remote.press(.menu)
    XCTAssertTrue(element("history.item.809").waitForExistence(timeout: 5))

    // The fixture's first clear fails; its retry empties History.
    XCTAssertTrue(focus("history.clear", moving: .up))
    remote.press(.select)
    XCTAssertTrue(element("history.clear-confirm").waitForExistence(timeout: 5))
    attach("runtime-tv-history-clear-modal")
    XCTAssertTrue(selectModalButton("history.clear-confirm"))
    let mutationRetry = element("history.mutation-retry")
    XCTAssertTrue(mutationRetry.waitForExistence(timeout: 10))
    XCTAssertTrue(focus("history.mutation-retry"))
    remote.press(.select)
    XCTAssertTrue(element("history.empty").waitForExistence(timeout: 10))
    attach("runtime-tv-history-empty")

    // Home reloads the account, which now has History off.
    remote.press(.menu)
    XCTAssertTrue(homeAccount.waitForExistence(timeout: 5))
    XCTAssertTrue(waitUntil(timeout: 10) { !homeHistory.exists })
    attach("runtime-tv-home-history-off")

    XCTAssertTrue(focus("home.account"))
    remote.press(.select)
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

    // The item modal's first permanent delete fails; the second commits.
    XCTAssertTrue(focus("trash.item.420"))
    remote.press(.select)
    XCTAssertTrue(element("trash.item-delete").waitForExistence(timeout: 5))
    attach("runtime-tv-trash-modal")
    XCTAssertTrue(selectModalButton("trash.item-delete"))
    XCTAssertTrue(
      label(containing: "Could not permanently delete item").waitForExistence(timeout: 5),
      "a failed delete must say so")
    XCTAssertTrue(waitUntil(timeout: 10) { !self.element("trash.progress").exists })
    XCTAssertTrue(element("trash.item.420").exists, "a failed delete keeps the row")
    XCTAssertTrue(element("trash.item.419").exists, "the modal deleted, not restored")
    XCTAssertTrue(focus("trash.item.420"))
    remote.press(.select)
    XCTAssertTrue(element("trash.item-delete").waitForExistence(timeout: 5))
    XCTAssertTrue(selectModalButton("trash.item-delete"))
    XCTAssertTrue(waitUntil(timeout: 10) { !self.element("trash.item.420").exists })

    XCTAssertTrue(focus("trash.restore-all", moving: .up))
    remote.press(.select)
    XCTAssertTrue(element("trash.empty-state").waitForExistence(timeout: 15))
    attach("runtime-tv-trash-empty")
  }

  /// Settings cycle in place, the proxy chooser recovers a failed listing, a
  /// failed save, and a failed confirmation refresh, and turning Trash off
  /// is confirmed in a centered modal.
  func testSettingsCycleProxyChooserAndTrashToggle() {
    app.launchArguments = [
      "--putio-harness-scenario", "signed-in", "--putio-harness-playback-preferences",
      "--putio-harness-reset-file-preferences",
    ]
    app.launch()

    XCTAssertTrue(element("home.account").waitForExistence(timeout: 15))
    XCTAssertTrue(focus("home.account"))
    remote.press(.select)
    XCTAssertTrue(element("account.username").waitForExistence(timeout: 10))

    XCTAssertTrue(focus("account.proxy"))
    remote.press(.select)
    let proxyRetry = element("proxy.retry")
    XCTAssertTrue(proxyRetry.waitForExistence(timeout: 10))
    attach("runtime-tv-proxy-failure")
    XCTAssertTrue(focus("proxy.retry"))
    remote.press(.select)
    XCTAssertTrue(element("proxy.route.edge").waitForExistence(timeout: 10))
    attach("runtime-tv-proxy-chooser")
    XCTAssertTrue(focus("proxy.route.edge"))
    remote.press(.select)

    // The first save fails, then the committed save's account reload fails
    // once; each offers a retry until the chooser closes on the new route.
    var retries = 0
    while retries < 3, waitUntil(timeout: 8, { proxyRetry.exists && proxyRetry.isEnabled }) {
      XCTAssertTrue(focus("proxy.retry", moving: .up))
      remote.press(.select)
      retries += 1
      _ = waitUntil(timeout: 5) { !(proxyRetry.exists && proxyRetry.isEnabled) }
    }
    XCTAssertEqual(retries, 2)
    XCTAssertTrue(element("account.proxy").waitForExistence(timeout: 10))
    XCTAssertTrue(element("account.proxy").label.contains("edge"))

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

    // With Trash off its row is the last setting; the app, device, and OS
    // rows below it must still come on screen with the remote.
    let system = element("account.system")
    XCTAssertTrue(focus("account.trash"))
    for _ in 0..<6 where !isOnScreen(system) {
      remote.press(.down)
      pause(0.5)
    }
    XCTAssertTrue(isOnScreen(system), "the operating system row never scrolled into view")
    attach("runtime-tv-account-about")
    XCTAssertTrue(focus("account.trash"))
    remote.press(.select)
    XCTAssertTrue(waitUntil(timeout: 10) { trash.value as? String == "On" })
    XCTAssertTrue(element("account.manage-trash").waitForExistence(timeout: 5))
  }

  // MARK: - Remote helpers

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

  private func hasFocus(_ identifier: String) -> Bool {
    app.descendants(matching: .any)
      .matching(NSPredicate(format: "identifier == %@ AND hasFocus == true", identifier))
      .firstMatch.exists
  }

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
