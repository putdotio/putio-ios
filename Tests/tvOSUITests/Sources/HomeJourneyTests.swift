import XCTest

/// Home's Continue watching and Pinned rows with the Siri Remote: playback
/// feeds the cards, a card resumes its video, long-press menus remove and
/// unpin, and sign-out clears what the account watched.
final class HomeJourneyTests: XCTestCase {
  private var app: XCUIApplication!
  private let remote = XCUIRemote.shared

  override func setUp() {
    continueAfterFailure = false
    app = XCUIApplication()
    let environment = ProcessInfo.processInfo.environment
    guard let mediaBaseURL = environment["PUTIO_HARNESS_MEDIA_BASE_URL"] else {
      XCTFail("the harness did not name its media server")
      return
    }
    app.launchEnvironment["PUTIO_HARNESS_MEDIA_BASE_URL"] = mediaBaseURL
  }

  /// A video finished through to its successor gets no card, the started
  /// successor does, the card resumes its video and survives a relaunch,
  /// sign-out clears it, and Direct play feeds a card too.
  func testPlaybackFeedsContinueWatchingAndSignOutClearsIt() {
    launch(["--putio-harness-tv-browse"])
    XCTAssertTrue(element("home.empty").waitForExistence(timeout: 15))
    XCTAssertFalse(card(414).exists)
    attach("runtime-tv-home-empty")

    XCTAssertTrue(TVTabBar(app).open("Files"))
    remote.press(.down)
    openFile("files.item.412")
    XCTAssertTrue(element("video.resume.continue").waitForExistence(timeout: 30))
    remote.press(.select)
    XCTAssertTrue(element("video.ended").waitForExistence(timeout: 60))
    XCTAssertTrue(element("video.play-next").waitForExistence(timeout: 30))
    XCTAssertTrue(waitUntil(timeout: 5) { self.hasFocus("video.play-next") })
    remote.press(.select)
    XCTAssertTrue(element("video.screen.414").waitForExistence(timeout: 30))
    XCTAssertTrue(element("video.resume.continue").waitForExistence(timeout: 30))
    remote.press(.select)
    XCTAssertTrue(
      waitUntil(timeout: 30) { self.reportedSeconds(for: 414).map { $0 >= 40 } ?? false },
      "playback reports a position past the saved one")
    leavePlayer()

    XCTAssertTrue(TVTabBar(app).open("Home"))
    XCTAssertTrue(card(414).waitForExistence(timeout: 15), "playback feeds Continue watching")
    XCTAssertTrue(card(414).label.hasPrefix("Resume Root Movie 2.mkv, "), card(414).label)
    XCTAssertTrue(card(414).label.hasSuffix(" left"))
    XCTAssertFalse(card(412).exists, "a finished video gets no card")
    XCTAssertTrue(element("home.pinned.empty").exists)
    attach("runtime-tv-home-fed")

    XCTAssertTrue(steer(to: "home.continue-watching.item.414"))
    remote.press(.select)
    XCTAssertTrue(element("video.screen.414").waitForExistence(timeout: 30), "the card plays")
    XCTAssertTrue(element("video.resume.continue").waitForExistence(timeout: 30))
    remote.press(.menu)
    XCTAssertTrue(waitUntil(timeout: 10) { !self.element("video.screen.414").exists })

    relaunch(["--putio-harness-continue-watching", "keep"])
    XCTAssertTrue(card(414).waitForExistence(timeout: 15), "the card survives a relaunch")

    XCTAssertTrue(TVTabBar(app).open("Account"))
    let signOut = app.buttons["auth.sign-out"]
    XCTAssertTrue(focusButton(signOut))
    remote.press(.select)
    let confirm = app.buttons["auth.sign-out-confirm"]
    XCTAssertTrue(confirm.waitForExistence(timeout: 10))
    XCTAssertTrue(selectAlertButton(confirm))
    XCTAssertTrue(waitUntil(timeout: 15) { !self.app.tabBars.firstMatch.exists })

    relaunch(["--putio-harness-continue-watching", "keep"])
    XCTAssertTrue(element("home.empty").waitForExistence(timeout: 15), "sign-out clears the cards")
    XCTAssertFalse(card(414).exists)

    relaunch(["--putio-harness-tv-browse", "--putio-harness-direct-play"])
    XCTAssertTrue(TVTabBar(app).open("Files"))
    remote.press(.down)
    openFile("files.item.412")
    let resume = element("video.resume.continue")
    if resume.waitForExistence(timeout: 5) { remote.press(.select) }
    XCTAssertTrue(element("video.ready").waitForExistence(timeout: 30))
    XCTAssertEqual(element("video.source").value as? String, "original-engine")
    XCTAssertTrue(
      waitUntil(timeout: 20) {
        (Int(self.element("video.current-position").value as? String ?? "") ?? 0) >= 12
      }, "Direct play advances")
    leaveDirectPlayer()
    XCTAssertTrue(TVTabBar(app).open("Home"))
    XCTAssertTrue(card(412).waitForExistence(timeout: 15), "Direct play feeds Continue watching")
    XCTAssertTrue(card(412).label.hasPrefix("Resume Root Movie.mkv, "), card(412).label)
    attach("runtime-tv-home-direct-fed")
  }

  private func leaveDirectPlayer() {
    for _ in 0..<6 {
      remote.press(.menu)
      if waitUntil(timeout: 2, { !self.element("video.screen.412").exists }) {
        pause(1)
        return
      }
    }
    XCTFail("Menu never left Direct play")
  }

  /// Cards keep their order, the Continue watching menu only removes, the
  /// pinned menu opens or unpins, Home reloads pins when it comes back, and
  /// both rows empty into the add-files state.
  func testCardsMenusPinsAndEmptyStates() {
    launch(["--putio-harness-continue-watching", "home", "--putio-harness-pins", "home"])
    for id in [411, 412, 414] {
      XCTAssertTrue(card(id).waitForExistence(timeout: 15), "card \(id)")
    }
    XCTAssertTrue(app.staticTexts["Continue watching"].exists)
    XCTAssertTrue(app.staticTexts["Pinned"].exists)
    XCTAssertLessThan(card(411).frame.minX, card(412).frame.minX)
    XCTAssertLessThan(card(412).frame.minX, card(414).frame.minX)
    XCTAssertEqual(
      card(411).label, "Resume Nested Movie.mkv, 1 hour, 21 minutes, 50 seconds left")
    XCTAssertTrue(pinned(410).waitForExistence(timeout: 15))
    XCTAssertTrue(pinned(410).label.contains("1 item"), pinned(410).label)
    XCTAssertTrue(pinned(412).exists)
    XCTAssertFalse(pinned(412).label.contains("item"), pinned(412).label)
    attach("runtime-tv-home-cards")

    XCTAssertTrue(steer(to: "home.continue-watching.item.411"))
    remote.press(.select, forDuration: 1.2)
    let remove = menuItem("Remove from Continue watching")
    XCTAssertTrue(remove.waitForExistence(timeout: 5))
    XCTAssertFalse(menuItem("Open").exists, "the card menu only removes")
    attach("runtime-tv-home-card-menu")
    remote.press(.select)
    XCTAssertTrue(waitUntil(timeout: 10) { !self.card(411).exists }, "Remove drops the card")
    XCTAssertTrue(
      waitUntil(timeout: 5) { self.hasFocus("home.continue-watching.item.412") },
      "focus moves to the next card")

    XCTAssertTrue(steer(to: "home.pinned.item.410"))
    remote.press(.select, forDuration: 1.2)
    let open = menuItem("Open")
    let unpin = menuItem("Unpin from Home")
    XCTAssertTrue(open.waitForExistence(timeout: 5))
    XCTAssertTrue(unpin.exists)
    XCTAssertLessThan(open.frame.minY, unpin.frame.minY, "Open sits above Unpin")
    attach("runtime-tv-home-pinned-menu")
    remote.press(.select)
    XCTAssertTrue(element("files.item.411").waitForExistence(timeout: 15), "Open opens 410")
    remote.press(.menu)
    XCTAssertTrue(pinned(410).waitForExistence(timeout: 10))

    XCTAssertTrue(steer(to: "home.pinned.item.410"))
    unpinFocused()
    XCTAssertTrue(waitUntil(timeout: 10) { !self.pinned(410).exists }, "Unpin drops 410")
    XCTAssertTrue(steer(to: "home.pinned.item.412"))
    unpinFocused()
    XCTAssertTrue(element("home.pinned.empty").waitForExistence(timeout: 10))
    XCTAssertTrue(steer(to: "home.continue-watching.item.412"))
    remote.press(.down)
    pause(1)
    XCTAssertTrue(
      hasFocus("home.continue-watching.item.412"), "the empty pinned row takes no focus")

    XCTAssertTrue(TVTabBar(app).open("Files"))
    remote.press(.down)
    XCTAssertTrue(focus("files.item.410", moving: .down, limit: 10))
    remote.press(.right)
    XCTAssertTrue(focus("files.panel.pin", moving: .down, limit: 10))
    remote.press(.select)
    pause(1)
    XCTAssertTrue(TVTabBar(app).open("Home"))
    XCTAssertTrue(pinned(410).waitForExistence(timeout: 15), "Home reloads its pins")

    for id in [412, 414] {
      XCTAssertTrue(steer(to: "home.continue-watching.item.\(id)"))
      remote.press(.select, forDuration: 1.2)
      XCTAssertTrue(menuItem("Remove from Continue watching").waitForExistence(timeout: 5))
      remote.press(.select)
      XCTAssertTrue(waitUntil(timeout: 10) { !self.card(id).exists })
      pause(1)
    }
    XCTAssertTrue(steer(to: "home.pinned.item.410"))
    unpinFocused()
    XCTAssertTrue(element("home.empty").waitForExistence(timeout: 10))
    XCTAssertTrue(label(containing: "QR code that opens put.io").exists)
    attach("runtime-tv-home-emptied")

    relaunch(["--putio-harness-continue-watching", "home", "--putio-harness-pins", "fail"])
    XCTAssertTrue(card(411).waitForExistence(timeout: 15))
    pause(2)
    XCTAssertFalse(app.staticTexts["Pinned"].exists, "failed pins hide the row")
    XCTAssertFalse(element("home.pinned.empty").exists)
  }

  private func launch(_ arguments: [String]) {
    app.launchArguments = ["--putio-harness-scenario", "signed-in"] + arguments
    app.launch()
    XCTAssertTrue(TVTabBar(app).item("Home").waitForExistence(timeout: 20))
  }

  private func relaunch(_ arguments: [String]) {
    app.terminate()
    launch(arguments)
  }

  private func card(_ id: Int) -> XCUIElement {
    element("home.continue-watching.item.\(id)")
  }

  private func pinned(_ id: Int) -> XCUIElement {
    element("home.pinned.item.\(id)")
  }

  private func unpinFocused() {
    remote.press(.select, forDuration: 1.2)
    let unpin = menuItem("Unpin from Home")
    XCTAssertTrue(unpin.waitForExistence(timeout: 5))
    remote.press(.down)
    pause(0.5)
    remote.press(.select)
    pause(1)
  }

  /// Account's sign-out is the last row of the settings list.
  private func focusButton(_ button: XCUIElement) -> Bool {
    for _ in 0..<24 {
      if waitUntil(timeout: 1, { button.exists && button.hasFocus }) { return true }
      remote.press(.down)
    }
    return waitUntil(timeout: 2) { button.exists && button.hasFocus }
  }

  /// Each alert button appears twice in the tree and only the outer copy
  /// reports focus, so the focused copy is matched to the target by frame.
  private func selectAlertButton(_ target: XCUIElement) -> Bool {
    pause(1)
    let goal = target.frame
    for _ in 0..<6 {
      let focused = app.buttons.matching(NSPredicate(format: "hasFocus == true")).firstMatch
      guard focused.exists else { return false }
      let current = focused.frame
      if abs(current.midX - goal.midX) < 4, abs(current.midY - goal.midY) < 4 {
        remote.press(.select)
        return true
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

  private func openFile(_ identifier: String) {
    XCTAssertTrue(element(identifier).waitForExistence(timeout: 15))
    XCTAssertTrue(focus(identifier, moving: .down, limit: 14))
    remote.press(.select)
  }

  private func leavePlayer() {
    for _ in 0..<6 {
      remote.press(.menu)
      if waitUntil(timeout: 2, { !self.element("video.system-player").exists }) {
        pause(1)
        return
      }
    }
    XCTFail("Menu never left the player")
  }

  private func reportedSeconds(for id: Int) -> Int? {
    let probe = element("video.position-reported")
    guard probe.exists, let value = probe.value as? String, value.hasPrefix("id=\(id);seconds=")
    else { return nil }
    return Int(value.dropFirst("id=\(id);seconds=".count))
  }

  private func menuItem(_ title: String) -> XCUIElement {
    app.cells.containing(NSPredicate(format: "label == %@", title)).firstMatch
  }

  /// Moves focus to `identifier` by comparing the focused frame with the
  /// target's, entering the content from the tab bar first.
  private func steer(to identifier: String) -> Bool {
    let target = element(identifier)
    guard target.waitForExistence(timeout: 10) else { return false }
    for _ in 0..<12 {
      if waitUntil(timeout: 1, { self.hasFocus(identifier) }) { return true }
      let focused = app.descendants(matching: .any)
        .matching(NSPredicate(format: "hasFocus == true")).firstMatch
      guard focused.exists,
        !app.tabBars.buttons.matching(
          NSPredicate(format: "hasFocus == true")
        ).firstMatch.exists
      else {
        remote.press(.down)
        continue
      }
      let current = focused.frame
      let goal = target.frame
      if abs(current.midY - goal.midY) >= 40 {
        remote.press(goal.midY > current.midY ? .down : .up)
      } else {
        remote.press(goal.midX > current.midX ? .right : .left)
      }
    }
    if waitUntil(timeout: 1.5, { self.hasFocus(identifier) }) { return true }
    let tree = XCTAttachment(string: app.debugDescription)
    tree.name = "steer-miss-\(identifier)"
    tree.lifetime = .keepAlways
    add(tree)
    return false
  }

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

  private func focusIsSettled() -> Bool {
    app.descendants(matching: .any).matching(NSPredicate(format: "hasFocus == true"))
      .firstMatch.exists
  }

  private func focus(
    _ identifier: String, moving direction: XCUIRemote.Button, limit: Int
  ) -> Bool {
    for _ in 0..<limit {
      if waitUntil(timeout: 0.75, { self.hasFocus(identifier) }) { return true }
      if waitUntil(timeout: 3, { self.focusIsSettled() }), hasFocus(identifier) { return true }
      remote.press(direction)
    }
    if waitUntil(timeout: 1.5, { self.hasFocus(identifier) }) { return true }
    let tree = XCTAttachment(string: app.debugDescription)
    tree.name = "focus-miss-\(identifier)"
    tree.lifetime = .keepAlways
    add(tree)
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
