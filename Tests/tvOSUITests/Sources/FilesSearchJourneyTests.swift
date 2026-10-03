import XCTest

/// Drives Your Files and Search against the seeded API with the Siri Remote,
/// recording the browser, sort and long-press menus, system search, and the
/// empty, error, and recovery states.
final class FilesSearchJourneyTests: XCTestCase {
  private var app: XCUIApplication!
  private let remote = XCUIRemote.shared

  override func setUp() {
    continueAfterFailure = false
    app = XCUIApplication()
  }

  /// The root pages through a failed continuation, sorts on the server, and
  /// round-trips watch status and a Trash move whose first attempt fails.
  /// Folders open, refetch on return, and show their empty and error states;
  /// a non-video file explains the app plays video only.
  func testBrowseSortMenuAndRecovery() {
    app.launchArguments = ["--putio-harness-scenario", "signed-in", "--putio-harness-tv-browse"]
    app.launch()

    XCTAssertTrue(element("home.files").waitForExistence(timeout: 15))
    XCTAssertTrue(
      waitUntil(timeout: 5) { self.hasFocus("home.files") }, "Home opens on Your Files")
    attach("runtime-tv-home-files")
    remote.press(.select)
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
    XCTAssertTrue(focus("files.sort", moving: .right, limit: 2))
    remote.press(.select)
    XCTAssertTrue(element("files.sort.NAME_DESC").waitForExistence(timeout: 5))
    attach("runtime-tv-files-sort")
    XCTAssertTrue(selectModalButton("files.sort.NAME_DESC"))
    XCTAssertTrue(
      waitUntil(timeout: 10) { self.element("files.sort").label.contains("descending") })
    // The fixture reverses the first page, so the last folders now lead.
    XCTAssertTrue(waitUntil(timeout: 10) { self.isAbove("files.item.424", "files.item.413") })

    // Long press opens the centered menu without opening the row, however
    // long Select is held.
    XCTAssertTrue(focus("files.item.412"))
    remote.press(.select, forDuration: 6.5)
    XCTAssertTrue(element("files.menu.unwatched").waitForExistence(timeout: 5))
    XCTAssertFalse(
      element("file.playback-placeholder.412").exists, "the long press opened the video")
    XCTAssertTrue(element("files.menu.delete").exists)
    attach("runtime-tv-files-menu")
    XCTAssertTrue(selectModalButton("files.menu.unwatched"))
    XCTAssertTrue(label(containing: "Marked as unwatched").waitForExistence(timeout: 10))
    XCTAssertTrue(waitUntil(timeout: 10) { !movie.label.contains("Watched") })
    XCTAssertTrue(element("files.item.412").exists, "the long press must not open the video")

    XCTAssertTrue(focus("files.item.412"))
    longPress()
    XCTAssertTrue(selectModalButton("files.menu.watched"))
    XCTAssertTrue(waitUntil(timeout: 10) { movie.label.contains("Watched") })

    // The fixture's first Trash move fails and keeps the row; the second
    // removes it and focus stays on a visible row.
    XCTAssertTrue(focus("files.item.412"))
    longPress()
    XCTAssertTrue(selectModalButton("files.menu.delete"))
    XCTAssertTrue(label(containing: "Could not move item to Trash").waitForExistence(timeout: 10))
    XCTAssertTrue(waitUntil(timeout: 10) { movie.exists })
    attach("runtime-tv-files-action-failure")
    XCTAssertTrue(focus("files.item.412"))
    longPress()
    XCTAssertTrue(selectModalButton("files.menu.delete"))
    XCTAssertTrue(label(containing: "Moved to Trash").waitForExistence(timeout: 10))
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
    longPress()
    XCTAssertTrue(selectModalButton("files.menu.delete"))
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
    XCTAssertTrue(waitUntil(timeout: 5) { self.hasFocus("files.refresh") })
    attach("runtime-tv-files-empty")
    remote.press(.menu)

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
  }

  /// Search types on the system keyboard. An empty result uses the system
  /// empty state; a failed search and a failed second page each retry; the
  /// results take the browser's long-press menu. Trash is off, so Delete
  /// asks first: Cancel keeps the file and confirming deletes it once.
  func testSystemSearchEmptyErrorResultsAndMenu() {
    app.launchArguments = [
      "--putio-harness-scenario", "signed-in", "--putio-harness-trash-disabled",
    ]
    app.launch()

    XCTAssertTrue(element("home.search").waitForExistence(timeout: 15))
    XCTAssertTrue(focus("home.search"))
    remote.press(.select)
    let field = app.searchFields.firstMatch
    XCTAssertTrue(field.waitForExistence(timeout: 10))
    pause(1)
    attach("runtime-tv-search-keyboard")

    field.typeText("no-matching-file")
    XCTAssertTrue(element("search.empty").waitForExistence(timeout: 10))
    attach("runtime-tv-search-empty")

    field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 16) + "retry")
    let retry = element("search.retry")
    XCTAssertTrue(retry.waitForExistence(timeout: 10))
    attach("runtime-tv-search-error")
    XCTAssertTrue(focus("search.retry", moving: .down, limit: 6))
    remote.press(.select)
    XCTAssertTrue(element("search.item.410").waitForExistence(timeout: 10))
    XCTAssertTrue(element("search.count").label.contains("2 results"))

    XCTAssertTrue(element("search.more-retry").waitForExistence(timeout: 10))
    XCTAssertTrue(focus("search.more-retry", moving: .down, limit: 6))
    remote.press(.select)
    XCTAssertTrue(waitUntil(timeout: 5) { self.hasFocus("search.item.410") })
    XCTAssertTrue(element("search.item.411").waitForExistence(timeout: 10))
    attach("runtime-tv-search-results")

    XCTAssertTrue(focus("search.item.411", moving: .down, limit: 6))
    longPress()
    XCTAssertTrue(element("files.menu.unwatched").waitForExistence(timeout: 5))
    attach("runtime-tv-search-menu")
    XCTAssertTrue(selectModalButton("files.menu.unwatched"))
    XCTAssertTrue(label(containing: "Marked as unwatched").waitForExistence(timeout: 10))
    // The action re-runs the search, whose rows now show the new state.
    let result = element("search.item.411")
    XCTAssertTrue(
      waitUntil(timeout: 10) {
        result.exists && result.label.contains("Nested Movie.mkv")
          && !result.label.contains("Watched")
      })

    XCTAssertTrue(focus("search.item.410", moving: .up, limit: 6))
    remote.press(.select)
    XCTAssertTrue(element("files.item.411").waitForExistence(timeout: 10))
    remote.press(.menu)

    // A permanent delete asks first; Cancel keeps the folder.
    let folder = element("search.item.410")
    // The alert can hand focus back to the keyboard above the results.
    XCTAssertTrue(focus("search.item.410"))
    longPress()
    XCTAssertTrue(element("files.menu.delete").waitForExistence(timeout: 5))
    XCTAssertEqual(element("files.menu.delete").label, "Delete")
    XCTAssertTrue(selectModalButton("files.menu.delete"))
    XCTAssertTrue(element("files.delete-confirm").waitForExistence(timeout: 5))
    attach("runtime-tv-search-delete-confirm")
    XCTAssertTrue(selectModalButton("files.delete-cancel"))
    pause(2)
    XCTAssertTrue(folder.exists, "Cancel deleted the folder")
    XCTAssertFalse(label(containing: "Item deleted").exists)

    // Confirming deletes it once: the fixture fails a repeated delete.
    // The alert can hand focus back to the keyboard above the results.
    XCTAssertTrue(focus("search.item.410"))
    longPress()
    XCTAssertTrue(selectModalButton("files.menu.delete"))
    XCTAssertTrue(selectModalButton("files.delete-confirm"))
    XCTAssertTrue(label(containing: "Item deleted").waitForExistence(timeout: 10))
    // A second request would fail and replace that toast; watching for the
    // whole three-second life of a toast means it cannot expire unseen.
    let failed = label(containing: "Could not delete item")
    XCTAssertFalse(
      waitUntil(timeout: 6) { failed.exists }, "the delete was sent more than once")
    XCTAssertFalse(folder.exists)
  }

  // MARK: - Remote helpers

  private func element(_ identifier: String) -> XCUIElement {
    app.descendants(matching: .any).matching(identifier: identifier).firstMatch
  }

  private func label(containing text: String) -> XCUIElement {
    app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", text))
      .firstMatch
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
      remote.press(direction)
    }
    return waitUntil(timeout: 1.5) { self.hasFocus(identifier) }
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
