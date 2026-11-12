import XCTest

final class AccountJourneyTests: XCTestCase {
  func testRatingAndContactLinksOpenOnlyAfterExplicitTaps() {
    continueAfterFailure = false
    let app = XCUIApplication()
    app.launchArguments = [
      "--putio-harness-scenario", "files-browser", "--putio-harness-rating-link",
    ]
    app.launch()
    let signIn = app.descendants(matching: .any)["auth.sign-in"]
    XCTAssertTrue(signIn.appears(within: 10))
    signIn.tap()
    let account = app.buttons["Account"]
    XCTAssertTrue(account.appears(within: 10))
    account.tap()
    let requests = app.descendants(matching: .any)["account.rating-link-requests"]
    XCTAssertTrue(requests.appears(within: 5))
    XCTAssertEqual(requests.value as? String, "0|")
    let rating = app.revealed("account.rate-app")
    XCTAssertTrue(rating.appears(within: 5))
    if !rating.isHittable { app.swipeUp() }
    XCTAssertTrue(rating.isHittable)
    let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
    attachment.name = "runtime-account-rating"
    attachment.lifetime = .keepAlways
    add(attachment)
    rating.tap()
    let expected = "1|https://apps.apple.com/app/id1260479699?action=write-review"
    let opened = XCTNSPredicateExpectation(
      predicate: NSPredicate(format: "value == %@", expected), object: requests)
    XCTAssertEqual(XCTWaiter.wait(for: [opened], timeout: 5), .completed)
    // Seeded builds carry no Intercom keys, so Contact us falls back to email.
    let contact = app.revealed("account.contact-support")
    XCTAssertTrue(contact.appears(within: 5))
    if !contact.isHittable { app.swipeUp() }
    contact.tap()
    let mailed = "2|mailto:support@put.io"
    let contacted = XCTNSPredicateExpectation(
      predicate: NSPredicate(format: "value == %@", mailed), object: requests)
    XCTAssertEqual(XCTWaiter.wait(for: [contacted], timeout: 5), .completed)
    // Scrolling minimizes the tab bar; scroll back so the tabs are buttons again.
    let files = app.buttons["Files"]
    app.scrollDown(toHit: files)
    XCTAssertTrue(files.appears(within: 5))
    files.tap()
    account.tap()
    XCTAssertTrue(app.navigationBars["Account"].appears(within: 5))
    XCTAssertTrue(app.revealed("account.rate-app").appears(within: 5))
    XCTAssertEqual(requests.value as? String, mailed)
    let signOut = app.revealed("auth.sign-out")
    XCTAssertTrue(signOut.appears(within: 5))
    if !signOut.isHittable { app.swipeUp() }
    let signOutHittable = XCTNSPredicateExpectation(
      predicate: NSPredicate(format: "hittable == true"), object: signOut)
    XCTAssertEqual(XCTWaiter.wait(for: [signOutHittable], timeout: 5), .completed)
    signOut.tap()
    app.confirmSignOut()
    XCTAssertTrue(signIn.appears(within: 10))
  }

  func testEveryAccountRowOpensAndClosesFromTopToEnd() {
    continueAfterFailure = false
    let app = XCUIApplication()
    app.launchArguments = [
      "--putio-harness-scenario", "files-browser", "--putio-harness-rating-link",
    ]
    app.launch()
    let signIn = app.descendants(matching: .any)["auth.sign-in"]
    XCTAssertTrue(signIn.appears(within: 10))
    signIn.tap()
    let account = app.buttons["Account"]
    XCTAssertTrue(account.appears(within: 10))
    account.tap()
    XCTAssertTrue(app.navigationBars["Account"].appears(within: 5))
    let requests = app.descendants(matching: .any)["account.rating-link-requests"]
    XCTAssertTrue(requests.appears(within: 5))

    let rows: [(identifier: String, title: String)] = [
      ("account.trash", "Trash"),
      ("playback-settings.route", "Proxy"),
      ("account.chromecast", "Chromecast"),
      ("account.privacy", "Privacy controls"),
      ("security.apps", "Where you are logged in"),
      ("security.link-device", "Link your account"),
      ("account.two-factor", "Two-factor authentication"),
      ("account.about", "About"),
      ("account.privacy-policy", ""),
      ("account.licenses", "Open source licenses"),
      ("account.clear-data", "Clear your data"),
      ("account.destroy-account", "Destroy your account"),
    ]
    for row in rows {
      let element = app.revealed(row.identifier)
      app.bringIntoView(element)
      XCTAssertTrue(
        element.becomesHittable(within: 10), "\(row.identifier) never became tappable")
      element.tap()
      if row.title.isEmpty {
        let opened = XCTNSPredicateExpectation(
          predicate: NSPredicate(format: "value == %@", "1|https://put.io/privacy-policy/"),
          object: requests)
        XCTAssertEqual(XCTWaiter.wait(for: [opened], timeout: 5), .completed)
        continue
      }
      let destination = app.navigationBars[row.title]
      XCTAssertTrue(destination.appears(within: 10), "\(row.identifier) did not open \(row.title)")
      destination.buttons.element(boundBy: 0).tap()
      XCTAssertTrue(
        app.navigationBars["Account"].appears(within: 5), "\(row.title) did not close")
    }
    XCTAssertTrue(app.revealed("auth.sign-out").appears(within: 5))
  }

  func testSettingsLoadSlowly() {
    continueAfterFailure = false
    let app = launchSignedIn(settings: "slow-load")
    XCTAssertTrue(element(app, "account.settings-loading").appears(within: 5))
    XCTAssertTrue(app.staticTexts["Loading account settings"].exists)
    XCTAssertTrue(element(app, "account.storage-used").exists)
    XCTAssertTrue(element(app, "account.trash").exists)
    XCTAssertFalse(element(app, "settings.default-sort").exists)
    attach(app, "runtime-account-settings-loading")
    XCTAssertTrue(element(app, "settings.default-sort").appears(within: 15))
    XCTAssertFalse(element(app, "account.settings-loading").exists)
    signOut(app)
  }

  func testSettingsLoadFailureRetriesAndFailedSavesRevertOnlineAndOffline() {
    continueAfterFailure = false
    let app = launchSignedIn(settings: "fail-load")
    let failed = element(app, "account.settings-failed")
    XCTAssertTrue(failed.appears(within: 10))
    XCTAssertTrue(app.staticTexts["Couldn’t load account settings"].exists)
    XCTAssertTrue(app.staticTexts["Check your connection and try again."].exists)
    XCTAssertFalse(element(app, "settings.default-sort").exists)
    attach(app, "runtime-account-settings-failed")
    app.buttons["account.settings-retry"].tap()
    XCTAssertTrue(element(app, "settings.default-sort").appears(within: 10))
    XCTAssertFalse(failed.exists)

    let autoplay = app.switches["playback-settings.autoplay"]
    XCTAssertTrue(app.revealed("playback-settings.autoplay").appears(within: 5))
    app.bringIntoView(autoplay)
    let original = autoplay.value as? String ?? ""
    for attempt in ["unavailable", "offline"] {
      tapSwitch(app, autoplay)
      let toast = app.staticTexts["Couldn’t save this setting"]
      XCTAssertTrue(toast.appears(within: 10), "no toast after the \(attempt) save")
      attach(app, "runtime-account-save-failed-\(attempt)")
      let toastFrame = toast.frame
      XCTAssertTrue(
        settles(autoplay, NSPredicate(format: "value == %@ AND enabled == true", original)),
        "autoplay did not revert after the \(attempt) save")
      XCTAssertTrue(autoplay.isHittable, "the toast covers autoplay after the \(attempt) save")
      XCTAssertFalse(
        toastFrame.intersects(autoplay.frame),
        "the toast covers autoplay after the \(attempt) save")
      XCTAssertTrue(toast.disappears(within: 10))
    }
    tapSwitch(app, autoplay)
    XCTAssertTrue(
      settles(autoplay, NSPredicate(format: "value != %@ AND enabled == true", original)),
      "autoplay did not save once put.io was reachable")
    XCTAssertFalse(app.staticTexts["Couldn’t save this setting"].exists)
    signOut(app)
  }

  private func launchSignedIn(settings mode: String) -> XCUIApplication {
    let app = XCUIApplication()
    app.launchArguments = [
      "--putio-harness-scenario", "files-browser", "--putio-harness-account-settings", mode,
    ]
    app.launch()
    let signIn = element(app, "auth.sign-in")
    let account = app.buttons["Account"]
    let deadline = Date.now.addingTimeInterval(15)
    while !signIn.exists, !account.exists, Date.now < deadline {
      _ = account.appears(within: 0.5)
    }
    if signIn.exists { signIn.tap() }
    XCTAssertTrue(account.appears(within: 10))
    account.tap()
    XCTAssertTrue(element(app, "account.profile").appears(within: 10))
    return app
  }

  private func signOut(_ app: XCUIApplication) {
    let signOut = app.revealed("auth.sign-out")
    XCTAssertTrue(signOut.appears(within: 5))
    app.bringIntoView(signOut)
    XCTAssertTrue(signOut.becomesHittable(within: 5))
    signOut.tap()
    app.confirmSignOut()
    XCTAssertTrue(element(app, "auth.sign-in").appears(within: 10))
  }

  private func tapSwitch(_ app: XCUIApplication, _ toggle: XCUIElement) {
    app.bringIntoView(toggle)
    XCTAssertTrue(settles(toggle, NSPredicate(format: "hittable == true AND enabled == true")))
    toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
  }

  private func settles(_ element: XCUIElement, _ predicate: NSPredicate) -> Bool {
    let expectation = XCTNSPredicateExpectation(predicate: predicate, object: element)
    return XCTWaiter.wait(for: [expectation], timeout: 10) == .completed
  }

  private func element(_ app: XCUIApplication, _ identifier: String) -> XCUIElement {
    app.descendants(matching: .any)[identifier]
  }

  private func attach(_ app: XCUIApplication, _ name: String) {
    let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
    attachment.name = name
    attachment.lifetime = .keepAlways
    add(attachment)
  }
}
