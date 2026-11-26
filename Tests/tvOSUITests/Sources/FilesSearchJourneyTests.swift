import XCTest

/// Drives Your Files and Search against the seeded API with the Siri Remote,
/// recording the browser and its panel, the sort menu, system search, the
/// search long-press menu, and the empty, error, and recovery states.
final class FilesSearchJourneyTests: XCTestCase {
  private var app: XCUIApplication!
  private let remote = XCUIRemote.shared

  override func setUp() {
    continueAfterFailure = false
    app = XCUIApplication()
  }

  /// The root pages through a failed continuation, sorts on the server, and
  /// round-trips watch status, a pin, and a Trash move whose first attempt
  /// fails from the panel.
  /// Folders open, refetch on return, and show their empty and error states;
  /// a non-video file explains the app plays video only.
  func testBrowseSortMenuAndRecovery() {
    app.launchArguments = ["--putio-harness-scenario", "signed-in", "--putio-harness-tv-browse"]
    app.launch()

    XCTAssertTrue(TVTabBar(app).open("Files"))
    attach("runtime-tv-home-files")
    remote.press(.down)
    let movie = element("files.item.412")
    XCTAssertTrue(movie.waitForExistence(timeout: 15))
    XCTAssertTrue(element("files.item.410").exists)
    XCTAssertTrue(movie.label.contains("Watched"), "the watched video shows its eye")
    attach("runtime-tv-files")

    // The second page's first request fails; its retry completes the root.
    let moreRetry = element("files.more-retry")
    XCTAssertTrue(focus("files.more-retry", moving: .down, limit: 16))
    attach("runtime-tv-files-more-recovery")
    remote.press(.select)
    XCTAssertTrue(waitUntil(timeout: 10) { !moreRetry.exists })
    XCTAssertTrue(
      waitUntil(timeout: 5) { self.hasFocus("files.item.424") },
      "focus stays at the end of the list, not back at the top")
    XCTAssertTrue(focus("files.item.422", moving: .down, limit: 3), "the second page loaded")

    // Sorting persists on the server and the list reloads in its order.
    // Up from the list lands on Refresh; Sort sits to its right.
    XCTAssertTrue(focus("files.refresh", moving: .up, limit: 20))
    remote.press(.right)
    pause(1)
    remote.press(.select)
    let descending = menuItem("Z to A")
    XCTAssertTrue(descending.waitForExistence(timeout: 5))
    attach("runtime-tv-files-sort")
    XCTAssertTrue(focusMenuItem(descending))
    remote.press(.select)
    XCTAssertTrue(
      waitUntil(timeout: 10) { self.element("files.sort").label.contains("Z to A") })
    // The fixture reverses the first page, so the last folders now lead.
    XCTAssertTrue(waitUntil(timeout: 10) { self.isAbove("files.item.424", "files.item.413") })

    XCTAssertTrue(focus("files.item.412"))
    XCTAssertTrue(element("files.panel").waitForExistence(timeout: 5))
    XCTAssertTrue(element("files.panel.move").exists, "the panel offers no Move")
    attach("runtime-tv-files-panel")

    XCTAssertTrue(panelAction("files.panel.startOver", on: "files.item.412"))
    XCTAssertTrue(element("video.screen.412").waitForExistence(timeout: 10))
    XCTAssertTrue(element("video.retry").waitForExistence(timeout: 20))
    XCTAssertTrue(
      waitUntil(timeout: 5) { self.hasFocus("video.retry") },
      "the failure screen opened without focus, so Menu would quit the app")
    remote.press(.menu)
    XCTAssertTrue(movie.waitForExistence(timeout: 10))

    XCTAssertTrue(panelAction("files.panel.markUnwatched", on: "files.item.412"))
    XCTAssertTrue(label(containing: "Marked as unwatched").waitForExistence(timeout: 10))
    XCTAssertTrue(waitUntil(timeout: 10) { !movie.label.contains("Watched") })
    XCTAssertFalse(element("video.screen.412").exists, "the panel action opened the video")
    XCTAssertTrue(
      waitUntil(timeout: 5) { self.hasFocus("files.item.412") }, "focus left the row")

    XCTAssertTrue(panelAction("files.panel.markWatched", on: "files.item.412"))
    XCTAssertTrue(waitUntil(timeout: 10) { movie.label.contains("Watched") })

    XCTAssertTrue(panelAction("files.panel.pin", on: "files.item.412"))
    XCTAssertTrue(element("files.panel.unpin").waitForExistence(timeout: 10))
    XCTAssertTrue(
      waitUntil(timeout: 3) { self.hasFocus("files.panel.unpin") }, "focus left the panel action")
    XCTAssertTrue(panelAction("files.panel.unpin", on: "files.item.412"))
    XCTAssertTrue(element("files.panel.pin").waitForExistence(timeout: 10))

    XCTAssertTrue(panelAction("files.panel.openInVLC", on: "files.item.412"))
    XCTAssertTrue(
      label(containing: "Install VLC from the App Store on Apple TV").waitForExistence(timeout: 10),
      "a missing VLC raised no alert")
    attach("runtime-tv-files-vlc-missing")
    XCTAssertTrue(selectModalButton("vlc.ok"))
    XCTAssertTrue(
      waitUntil(timeout: 5) { self.hasFocus("files.item.412") },
      "focus left the file after the VLC alert")

    // The fixture's first Trash move fails and keeps the row; the second
    // removes it and focus stays on a visible row.
    XCTAssertTrue(panelAction("files.panel.trash", on: "files.item.412"))
    XCTAssertTrue(label(containing: "Could not move item to Trash").waitForExistence(timeout: 10))
    XCTAssertTrue(waitUntil(timeout: 10) { movie.exists })
    attach("runtime-tv-files-action-failure")
    XCTAssertTrue(panelAction("files.panel.trash", on: "files.item.412"))
    XCTAssertTrue(label(containing: "Moved to trash").waitForExistence(timeout: 10))
    XCTAssertTrue(waitUntil(timeout: 10) { !movie.exists })
    // Under the reversed sort the row after the movie is Harness Folder.
    XCTAssertTrue(
      waitUntil(timeout: 5) { self.hasFocus("files.item.410") },
      "focus moves to the next row, not back to the top")
    XCTAssertTrue(focusedRowIsOnScreen())
    attach("runtime-tv-files-trashed")

    // A later-page row: the Trash move reloads only the first page, so focus
    // goes to that page's last row instead of a neighbour the reload drops.
    XCTAssertTrue(focus("files.item.422", moving: .down, limit: 4))
    XCTAssertTrue(panelAction("files.panel.trash", on: "files.item.422"))
    XCTAssertTrue(waitUntil(timeout: 10) { !self.element("files.item.422").exists })
    XCTAssertTrue(element("files.item.426").waitForExistence(timeout: 10))
    XCTAssertTrue(
      waitUntil(timeout: 5) { self.hasFocus("files.item.410") },
      "focus stays next to the removed row, not back at the top")
    XCTAssertTrue(focusedRowIsOnScreen())

    // A folder opens; returning refetches the root.
    XCTAssertTrue(focus("files.item.410"))
    remote.press(.select)
    XCTAssertTrue(element("files.item.411").waitForExistence(timeout: 10))
    attach("runtime-tv-folder")
    remote.press(.menu)
    XCTAssertTrue(element("files.item.410").waitForExistence(timeout: 10))
    // The fixture adds a root row while Harness Folder is open.
    XCTAssertTrue(
      focus("files.item.427", moving: .up, limit: 14), "returning did not refetch the root")

    // Apple TV plays video only.
    XCTAssertTrue(focus("files.item.407"))
    remote.press(.select)
    XCTAssertTrue(label(containing: "Unsupported file type").waitForExistence(timeout: 10))
    XCTAssertTrue(label(containing: "only support video files").exists)
    XCTAssertTrue(
      waitUntil(timeout: 5) { self.focusedButtonLabel() == "Go back" },
      "Go back is the screen's one focus target")
    attach("runtime-tv-file-unsupported")
    remote.press(.select)
    XCTAssertTrue(element("files.item.407").waitForExistence(timeout: 10))

    XCTAssertTrue(focus("files.item.423"))
    remote.press(.select)
    XCTAssertTrue(element("files.empty").waitForExistence(timeout: 10))
    XCTAssertFalse(element("files.refresh").exists, "an empty folder shows no actions")
    attach("runtime-tv-files-empty")
    remote.press(.menu)
    XCTAssertTrue(
      element("files.item.423").waitForExistence(timeout: 5), "Menu left the empty folder's app")

    // The flaky folder's first listing fails; its retry loads it.
    XCTAssertTrue(focus("files.item.424"))
    remote.press(.select)
    XCTAssertTrue(element("files.retry").waitForExistence(timeout: 10))
    attach("runtime-tv-files-error")
    XCTAssertTrue(focus("files.retry"))
    remote.press(.select)
    XCTAssertTrue(element("files.item.425").waitForExistence(timeout: 10))
    XCTAssertTrue(waitUntil(timeout: 5) { self.focusedRowIsOnScreen() })
    attach("runtime-tv-files-recovered")

    // Move opens the folder picker over the list, marking the item's folder.
    // Back closes it at Your files and goes up from a folder it opened.
    XCTAssertTrue(panelAction("files.panel.move", on: "files.item.425"))
    let sheet = element("files.move-sheet")
    XCTAssertTrue(element("files.move-current.424").waitForExistence(timeout: 10))
    XCTAssertFalse(element("files.move-folder.424").exists, "the item's folder is unmarked")
    // The item's folder opens so its subfolders stay reachable; moving into
    // it stays off.
    XCTAssertTrue(focus("files.move-current.424"))
    remote.press(.select)
    XCTAssertTrue(element("files.move-empty").waitForExistence(timeout: 10))
    XCTAssertFalse(element("files.move-here").isEnabled, "Move here is on in the item's folder")
    remote.press(.menu)
    XCTAssertTrue(
      waitUntil(timeout: 10) { self.hasFocus("files.move-current.424") },
      "Back did not return to the item's folder")
    remote.press(.menu)
    XCTAssertTrue(waitUntil(timeout: 10) { !sheet.exists }, "Back at Your files kept the sheet")
    XCTAssertTrue(
      waitUntil(timeout: 5) { self.hasFocus("files.item.425") },
      "closing the sheet did not return focus to the row")

    XCTAssertTrue(panelAction("files.panel.move", on: "files.item.425"))
    XCTAssertTrue(sheet.waitForExistence(timeout: 10))
    XCTAssertTrue(focus("files.move-folder.423"))
    remote.press(.select)
    XCTAssertTrue(element("files.move-empty").waitForExistence(timeout: 10))
    XCTAssertTrue(
      waitUntil(timeout: 5) { self.hasFocus("files.move-here") },
      "an empty folder does not focus Move here")
    remote.press(.menu)
    XCTAssertTrue(
      waitUntil(timeout: 10) { self.hasFocus("files.move-folder.423") },
      "Back did not return to the folder it left")
    XCTAssertTrue(sheet.exists, "Back inside a folder closed the sheet")

    XCTAssertTrue(focus("files.move-here", moving: .down, limit: 12))
    remote.press(.select)
    XCTAssertTrue(label(containing: "Moved to Your files").waitForExistence(timeout: 10))
    XCTAssertTrue(waitUntil(timeout: 10) { !sheet.exists })
    XCTAssertTrue(waitUntil(timeout: 10) { !self.element("files.item.425").exists })
    attach("runtime-tv-files-moved")
  }

  /// Search types on the system keyboard under its recent searches. A
  /// failed search and a failed second page each retry; results open a panel
  /// without Rename or Trash. Offline, recents stay and a search fails.
  func testSystemSearchEmptyErrorResultsAndMenu() {
    app.launchArguments = [
      "--putio-harness-scenario", "signed-in", "--putio-harness-search-history", "seeded",
    ]
    app.launch()

    XCTAssertTrue(TVTabBar(app).open("Search"))
    let field = app.searchFields.firstMatch
    XCTAssertTrue(field.waitForExistence(timeout: 10))
    showSearchKeyboard()
    XCTAssertTrue(element("search.recent.tree rings").waitForExistence(timeout: 10))
    XCTAssertTrue(label(containing: "Recent searches").exists)
    pause(1)
    attach("runtime-tv-search-keyboard")

    XCTAssertTrue(focus("search.recent.mp3", moving: .down, limit: 8))
    longPress()
    let remove = menuItem("Remove from recent searches")
    XCTAssertTrue(remove.waitForExistence(timeout: 5))
    attach("runtime-tv-search-recent-menu")
    XCTAssertTrue(focusMenuItem(remove))
    remote.press(.select)
    XCTAssertTrue(waitUntil(timeout: 10) { !self.element("search.recent.mp3").exists })
    XCTAssertTrue(element("search.recent.sintel").exists)
    XCTAssertTrue(
      waitUntil(timeout: 5) { self.hasFocus("search.recent.tree rings") },
      "focus left the recent searches")

    XCTAssertTrue(focusKeyboard())
    field.typeText("no-matching-file")
    XCTAssertTrue(element("search.empty").waitForExistence(timeout: 10))
    XCTAssertTrue(label(containing: "Nothing matches").exists)
    attach("runtime-tv-search-empty")

    field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 16) + "retry")
    let retry = element("search.retry")
    XCTAssertTrue(retry.waitForExistence(timeout: 10))
    attach("runtime-tv-search-error")
    XCTAssertTrue(focus("search.retry", moving: .down, limit: 6))
    remote.press(.select)
    XCTAssertTrue(element("search.item.410").waitForExistence(timeout: 10))
    XCTAssertTrue(element("search.count").label.contains("2 results"))
    XCTAssertTrue(
      waitUntil(timeout: 5) { self.hasFocus("search.item.410") },
      "focus did not move to the results after Try again")
    XCTAssertTrue(element("search.panel").waitForExistence(timeout: 5))

    XCTAssertTrue(element("search.more-retry").waitForExistence(timeout: 10))
    XCTAssertTrue(focus("search.more-retry", moving: .down, limit: 6))
    remote.press(.select)
    XCTAssertTrue(waitUntil(timeout: 5) { self.hasFocus("search.item.410") })
    XCTAssertTrue(element("search.item.411").waitForExistence(timeout: 10))
    XCTAssertTrue(element("search.panel").waitForExistence(timeout: 5))
    attach("runtime-tv-search-results")

    XCTAssertTrue(focus("search.item.411", moving: .down, limit: 6))
    XCTAssertTrue(element("search.panel.markUnwatched").waitForExistence(timeout: 5))
    XCTAssertFalse(element("search.panel.rename").exists, "search results offer Rename")
    XCTAssertFalse(element("search.panel.trash").exists, "search results offer Trash")
    // Move opens the folder picker at Your files; Back there closes it.
    XCTAssertTrue(panelAction("search.panel.move", on: "search.item.411"))
    XCTAssertTrue(
      element("files.move-current.410").waitForExistence(timeout: 10),
      "the result's folder is not marked")
    remote.press(.menu)
    XCTAssertTrue(
      waitUntil(timeout: 10) { !self.element("files.move-sheet").exists },
      "Back at Your files kept the sheet open")
    XCTAssertTrue(
      waitUntil(timeout: 5) { self.hasFocus("search.item.411") },
      "closing the sheet did not return focus to the result")
    XCTAssertTrue(panelAction("search.panel.markUnwatched", on: "search.item.411"))
    attach("runtime-tv-search-menu")
    XCTAssertTrue(label(containing: "Marked as unwatched").waitForExistence(timeout: 10))
    // The action re-runs the search, whose rows now show the new state.
    let result = element("search.item.411")
    XCTAssertTrue(
      waitUntil(timeout: 10) {
        result.exists && result.label.contains("Nested Movie.mkv")
          && !result.label.contains("Watched")
      })

    XCTAssertTrue(panelAction("search.panel.openInVLC", on: "search.item.411"))
    XCTAssertTrue(
      label(containing: "Install VLC from the App Store on Apple TV").waitForExistence(timeout: 10))
    XCTAssertTrue(selectModalButton("vlc.ok"))
    XCTAssertTrue(
      waitUntil(timeout: 5) { self.hasFocus("search.item.411") },
      "focus left the result after the VLC alert")

    XCTAssertTrue(focus("search.item.410"))
    remote.press(.select)
    XCTAssertTrue(element("files.item.411").waitForExistence(timeout: 10))
    remote.press(.menu)
    XCTAssertTrue(element("search.item.410").waitForExistence(timeout: 10))

    XCTAssertTrue(focusKeyboard())
    field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 5))
    let recorded = element("search.recent.retry")
    XCTAssertTrue(recorded.waitForExistence(timeout: 10), "the search was not recorded")
    XCTAssertTrue(isAbove("search.recent.retry", "search.recent.sintel"))
    attach("runtime-tv-search-recent")
    XCTAssertTrue(focus("search.recent-clear", moving: .down, limit: 4))
    remote.press(.select)
    XCTAssertTrue(element("search.start").waitForExistence(timeout: 10))
    XCTAssertFalse(recorded.exists)
    attach("runtime-tv-search-start")

    app.terminate()
    app.launchArguments = [
      "--putio-harness-scenario", "signed-in", "--putio-harness-search-history", "seeded",
      "--putio-harness-search-offline",
    ]
    app.launch()
    XCTAssertTrue(TVTabBar(app).open("Search"))
    XCTAssertTrue(field.waitForExistence(timeout: 10))
    showSearchKeyboard()
    XCTAssertTrue(element("search.recent.sintel").waitForExistence(timeout: 10))
    field.typeText("sintel")
    XCTAssertTrue(label(containing: "Can't connect to put.io").waitForExistence(timeout: 10))
    XCTAssertTrue(element("search.retry").exists)
    attach("runtime-tv-search-offline")
  }

  // MARK: - Remote helpers

  private func element(_ identifier: String) -> XCUIElement {
    app.descendants(matching: .any).matching(identifier: identifier).firstMatch
  }

  private func label(containing text: String) -> XCUIElement {
    app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", text))
      .firstMatch
  }

  /// A press before the search screen settles stays on the tab bar, and
  /// typing then finds no keyboard focus; press until the keyboard shows.
  private func showSearchKeyboard() {
    _ = waitUntil(timeout: 3) { self.focusIsSettled() }
    for _ in 0..<3 {
      remote.press(.down)
      if app.keyboards.firstMatch.waitForExistence(timeout: 3) { return }
    }
  }

  private func focusKeyboard() -> Bool {
    let keyboard = app.keyboards.firstMatch
    for _ in 0..<8 {
      if waitUntil(timeout: 2, { keyboard.exists && keyboard.hasFocus }) { return true }
      remote.press(.up)
    }
    return keyboard.exists && keyboard.hasFocus
  }

  private func focusIsSettled() -> Bool {
    app.descendants(matching: .any).matching(NSPredicate(format: "hasFocus == true"))
      .firstMatch.exists
  }

  private func panelHasFocus() -> Bool {
    app.descendants(matching: .any)
      .matching(NSPredicate(format: "identifier CONTAINS '.panel.' AND hasFocus == true"))
      .firstMatch.exists
  }

  private func hasFocus(_ identifier: String) -> Bool {
    app.descendants(matching: .any)
      .matching(NSPredicate(format: "identifier == %@ AND hasFocus == true", identifier))
      .firstMatch.exists
  }

  private func focusedButtonLabel() -> String? {
    let focused = app.buttons.matching(NSPredicate(format: "hasFocus == true")).firstMatch
    return focused.exists ? focused.label : nil
  }

  private func isAbove(_ upper: String, _ lower: String) -> Bool {
    let a = element(upper)
    let b = element(lower)
    return a.exists && b.exists && a.frame.minY < b.frame.minY
  }

  /// Focus sits on a file row that is fully inside the window, never on a
  /// header button, a removed row, or a row off screen.
  private func focusedRowIsOnScreen() -> Bool {
    let focused = app.descendants(matching: .any)
      .matching(
        NSPredicate(
          format:
            "hasFocus == true AND (identifier BEGINSWITH 'files.item.' OR identifier BEGINSWITH 'search.item.')"
        )
      ).firstMatch
    guard focused.exists, !focused.frame.isEmpty else { return false }
    return app.windows.firstMatch.frame.contains(focused.frame)
  }

  /// Moves focus onto the element with the remote: down first, then up,
  /// bounded so a screen that never offers it still fails.
  private func focus(_ identifier: String) -> Bool {
    if focus(identifier, moving: .down, limit: 14) || focus(identifier, moving: .up, limit: 20) {
      return true
    }
    let tree = XCTAttachment(string: app.debugDescription)
    tree.name = "focus-miss-\(identifier)"
    tree.lifetime = .keepAlways
    add(tree)
    return false
  }

  private func focus(
    _ identifier: String, moving direction: XCUIRemote.Button, limit: Int = 10
  ) -> Bool {
    for _ in 0..<limit {
      if waitUntil(timeout: 0.75, { self.hasFocus(identifier) }) { return true }
      // A move that scrolls the list reports no focused element until the
      // focus engine settles; pressing again before then skips the row.
      if waitUntil(timeout: 3, { self.focusIsSettled() }), hasFocus(identifier) { return true }
      remote.press(direction)
    }
    return waitUntil(timeout: 1.5) { self.hasFocus(identifier) }
  }

  private func panelAction(_ action: String, on row: String) -> Bool {
    if panelHasFocus() { remote.press(.left) }
    guard focus(row) else { return false }
    remote.press(.right)
    guard focus(action, moving: .down, limit: 8) || focus(action, moving: .up, limit: 8) else {
      return false
    }
    let target = element(action)
    guard waitUntil(timeout: 10, { target.isEnabled }) else { return false }
    remote.press(.select)
    return true
  }

  private func menuItem(_ title: String) -> XCUIElement {
    app.cells.containing(NSPredicate(format: "label == %@", title)).firstMatch
  }

  private func focusMenuItem(_ item: XCUIElement) -> Bool {
    let isFocused = {
      item.hasFocus
        || item.descendants(matching: .any).matching(NSPredicate(format: "hasFocus == true"))
          .firstMatch.exists
    }
    for _ in 0..<12 {
      if waitUntil(timeout: 1, isFocused) { return true }
      guard item.exists else { return false }
      remote.press(.down)
    }
    return isFocused()
  }

  private func longPress() {
    remote.press(.select, forDuration: 1.2)
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
    for _ in 0..<10 {
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
