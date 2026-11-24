import XCTest

/// Captures each rd-tvos-acc board's state on the Apple TV simulator against
/// the seeded API, named after its board.
final class AccountBoardCaptureTests: XCTestCase {
  private var app: XCUIApplication!
  private let remote = XCUIRemote.shared

  override func setUp() {
    continueAfterFailure = false
    app = XCUIApplication()
  }

  func testAccountBoards() {
    openAccount()

    XCTAssertTrue(focus("account.manage-trash"))
    attach("rd-tvos-acc-01-account")
    XCTAssertTrue(focus("account.trash"))
    attach("rd-tvos-acc-02-trash-toggle")

    XCTAssertTrue(focus("account.default-sort"))
    remote.press(.select)
    pause(2)
    attach("rd-tvos-acc-03-default-sort")
    remote.press(.menu)
    pause(1)

    XCTAssertTrue(focus("account.resume"))
    attach("rd-tvos-acc-04-playback")
    remote.press(.select)
    XCTAssertTrue(element("account.resume-disable-confirm").waitForExistence(timeout: 5))
    pause(1)
    attach("rd-tvos-acc-05-resume-off")
    remote.press(.menu)
    XCTAssertTrue(waitUntil(timeout: 5) { !self.element("account.resume-disable-confirm").exists })

    XCTAssertTrue(focus("account.proxy"))
    remote.press(.select)
    if element("proxy.retry").waitForExistence(timeout: 5) {
      XCTAssertTrue(focus("proxy.retry"))
      remote.press(.select)
      pause(2)
      XCTAssertTrue(focus("account.proxy"))
      remote.press(.select)
    }
    XCTAssertTrue(element("proxy.route.edge").waitForExistence(timeout: 10))
    pause(1)
    attach("rd-tvos-acc-06-proxy")
    remote.press(.menu)
    pause(1)

    XCTAssertTrue(focus("account.subtitle-selection"))
    attach("rd-tvos-acc-07-subtitles")

    XCTAssertTrue(focus("account.privacy"))
    remote.press(.select)
    XCTAssertTrue(element("privacy.diagnostics").waitForExistence(timeout: 10))
    pause(1)
    attach("rd-tvos-acc-08-privacy")
    remote.press(.menu)
    XCTAssertTrue(element("account.privacy").waitForExistence(timeout: 10))

    XCTAssertTrue(focus("account.app-info", moving: .down, limit: 16))
    attach("rd-tvos-acc-09-app-info")
    XCTAssertTrue(focus("account.manage-account", moving: .down, limit: 8))
    attach("rd-tvos-acc-10-manage")

    XCTAssertTrue(focus("auth.sign-out", moving: .down, limit: 8))
    remote.press(.select)
    XCTAssertTrue(element("auth.sign-out-confirm").waitForExistence(timeout: 5))
    pause(1)
    attach("rd-tvos-acc-11-sign-out")
    remote.press(.menu)
    XCTAssertTrue(waitUntil(timeout: 5) { !self.element("auth.sign-out-confirm").exists })

    XCTAssertTrue(focus("account.show-home", moving: .up, limit: 24))
    remote.press(.select)
    XCTAssertTrue(waitUntil(timeout: 5) { !TVTabBar(self.app).item("Home").exists })
    attach("rd-tvos-acc-14-show-home-off")
    remote.press(.select)
    XCTAssertTrue(TVTabBar(app).item("Home").waitForExistence(timeout: 5))
  }

  func testAlmostFullStorage() {
    openAccount(arguments: ["--putio-harness-account-storage-almost-full"])
    XCTAssertTrue(element("account.storage-warning").waitForExistence(timeout: 10))
    XCTAssertTrue(focus("account.manage-trash"))
    attach("rd-tvos-acc-13-storage-full")
  }

  /// The fixture fails the first autoplay save.
  func testSaveFailure() {
    openAccount(arguments: ["--putio-harness-account-settings", "fail-load"])
    XCTAssertTrue(focus("account.autoplay"))
    remote.press(.select)
    XCTAssertTrue(
      app.staticTexts["Couldn’t save this setting"].waitForExistence(timeout: 10),
      "a failed save must say so")
    attach("rd-tvos-acc-12-save-failed")
  }

  private func openAccount(arguments: [String] = []) {
    app.launchArguments = ["--putio-harness-scenario", "signed-in"] + arguments
    app.launch()
    XCTAssertTrue(TVTabBar(app).open("Account"))
    remote.press(.down)
    XCTAssertTrue(element("account.username").waitForExistence(timeout: 15))
  }

  private func element(_ identifier: String) -> XCUIElement {
    app.descendants(matching: .any).matching(identifier: identifier).firstMatch
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

  private func focus(_ identifier: String) -> Bool {
    focus(identifier, moving: .down, limit: 12) || focus(identifier, moving: .up, limit: 24)
  }

  private func focus(
    _ identifier: String, moving direction: XCUIRemote.Button, limit: Int
  ) -> Bool {
    for _ in 0..<limit {
      if waitUntil(timeout: 0.75, { self.hasFocus(identifier) }) { return true }
      remote.press(direction)
    }
    return waitUntil(timeout: 1.5) { self.hasFocus(identifier) }
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
