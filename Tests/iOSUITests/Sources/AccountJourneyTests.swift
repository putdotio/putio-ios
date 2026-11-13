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
      ("account.public-links", "Exclusive links"),
      ("account.trash", "Trash"),
      ("playback-settings.route", "Choose your proxy"),
      ("account.chromecast", "Chromecast"),
      ("account.privacy", "Privacy controls"),
      ("security.apps", "Logged-in apps"),
      ("security.link-device", "Link a device"),
      ("account.two-factor", "https://app.put.io/account/security"),
      ("account.about", "App info"),
      ("account.privacy-policy", "https://put.io/privacy-policy/"),
      ("account.licenses", "Open source licenses"),
      ("account.clear-data", "Clear your data"),
      ("account.destroy-account", "Destroy your account"),
    ]
    var opened = 0
    for row in rows {
      let element = app.revealed(row.identifier)
      app.bringIntoView(element)
      XCTAssertTrue(
        element.becomesHittable(within: 10), "\(row.identifier) never became tappable")
      element.tap()
      if row.title.hasPrefix("https://") {
        opened += 1
        let request = XCTNSPredicateExpectation(
          predicate: NSPredicate(format: "value == %@", "\(opened)|\(row.title)"),
          object: requests)
        XCTAssertEqual(
          XCTWaiter.wait(for: [request], timeout: 5), .completed, "\(row.identifier) opened nothing"
        )
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

  func testSignOutKeepsOrRemovesDownloadsAndDismissChangesNothing() throws {
    continueAfterFailure = false
    let app = XCUIApplication()
    app.launchArguments = ["--putio-harness-scenario", "files-browser"]
    app.launchEnvironment["PUTIO_HARNESS_MEDIA_BASE_URL"] = try XCTUnwrap(
      ProcessInfo.processInfo.environment["PUTIO_HARNESS_MEDIA_BASE_URL"])
    app.launch()
    let signIn = app.descendants(matching: .any)["auth.sign-in"]
    XCTAssertTrue(signIn.appears(within: 10))
    signIn.tap()

    let track = app.descendants(matching: .any)["files.item.408"]
    XCTAssertTrue(track.appears(within: 10), "the harness track never appeared")
    track.press(forDuration: 1)
    let download = app.buttons["Download"].firstMatch
    XCTAssertTrue(download.appears(within: 5), "the track menu has no Download")
    download.tap()
    let downloaded = app.descendants(matching: .any)["downloads.item.408"]
    openDownloads(in: app)
    XCTAssertTrue(downloaded.appears(within: 10), "the track never queued")
    XCTAssertTrue(
      waitForValue(downloaded, "completed", timeout: 60), "the track never finished downloading")

    let keep = app.buttons["auth.sign-out-confirm"].firstMatch
    let remove = app.buttons["auth.sign-out-remove-downloads"].firstMatch
    tapSignOut(in: app)
    XCTAssertTrue(remove.appears(within: 5), "the dialog offers no download removal")
    XCTAssertTrue(keep.exists, "the dialog offers no plain Sign out")
    XCTAssertTrue(app.staticTexts["Sign out of put.io?"].exists, "the dialog has no title")
    let message = app.staticTexts.matching(
      NSPredicate(
        format: "label BEGINSWITH %@ AND label ENDSWITH %@", "Downloads use ",
        " and stay on this \(deviceNoun). They come back when you sign in again.")
    ).firstMatch
    XCTAssertTrue(message.exists, "the dialog does not say downloads stay")
    XCTAssertFalse(
      message.label.hasPrefix("Downloads use 0 B"), "the dialog does not show the downloads' size")
    XCTAssertEqual(remove.label, "Sign out and remove downloads")
    attach(app, "runtime-sign-out-downloads")
    dismissSignOutDialog(in: app)
    XCTAssertTrue(remove.disappears(within: 5), "the dialog stayed open")
    XCTAssertTrue(
      app.descendants(matching: .any)["auth.sign-out"].exists, "dismissing the dialog signed out")
    openDownloads(in: app)
    XCTAssertTrue(downloaded.appears(within: 5), "dismissing the dialog removed the download")

    tapSignOut(in: app)
    XCTAssertTrue(keep.appears(within: 5))
    keep.tap()
    XCTAssertTrue(signIn.appears(within: 15), "Sign out never reached Welcome")
    signIn.tap()
    openDownloads(in: app)
    XCTAssertTrue(downloaded.appears(within: 10), "signing back in lost the kept download")
    XCTAssertTrue(waitForValue(downloaded, "completed", timeout: 5))

    tapSignOut(in: app)
    XCTAssertTrue(remove.appears(within: 5))
    remove.tap()
    XCTAssertTrue(signIn.appears(within: 15), "Sign out and remove downloads never reached Welcome")
    signIn.tap()
    openDownloads(in: app)
    XCTAssertTrue(app.staticTexts["No downloads"].appears(within: 10), "the download survived")

    tapSignOut(in: app)
    let alert = app.putioAlert("Sign out of put.io?")
    XCTAssertTrue(alert.appears(within: 5), "sign-out with no downloads asked no question")
    XCTAssertFalse(remove.exists, "the alert offers download removal with no downloads")
    XCTAssertTrue(alert.buttons["Cancel"].exists, "the alert has no Cancel")
    attach(app, "runtime-sign-out-no-downloads")
    alert.buttons["Cancel"].tap()
    XCTAssertTrue(alert.disappears(within: 5))
    XCTAssertTrue(app.descendants(matching: .any)["auth.sign-out"].exists, "Cancel left Account")
    tapSignOut(in: app)
    app.confirmSignOut()
    XCTAssertTrue(signIn.appears(within: 15))
  }

  func testAppInfoCopiesFiveAnonymousFieldsAndLicensesListEveryBundledPackage() throws {
    continueAfterFailure = false
    let app = XCUIApplication()
    app.launchArguments = ["--putio-harness-scenario", "files-browser"]
    app.launch()
    let signIn = app.descendants(matching: .any)["auth.sign-in"]
    if signIn.appears(within: 10) { signIn.tap() }
    let account = app.buttons["Account"]
    XCTAssertTrue(account.appears(within: 10))
    account.tap()

    let about = app.revealed("account.about")
    XCTAssertTrue(about.appears(within: 10))
    app.bringIntoView(about)
    about.tap()
    let copy = app.buttons["app-info.copy"]
    XCTAssertTrue(copy.appears(within: 10), "App info never opened")
    copy.tap()
    XCTAssertTrue(app.staticTexts["Copied to clipboard"].appears(within: 5))
    let pasteboard = element(app, "harness.pasteboard")
    let copied = XCTNSPredicateExpectation(
      predicate: NSPredicate(format: "value BEGINSWITH %@", "Version: "), object: pasteboard)
    XCTAssertEqual(XCTWaiter.wait(for: [copied], timeout: 5), .completed)
    let text = try XCTUnwrap(pasteboard.value as? String)
    let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    let patterns = [
      #"^Version: \d+(\.\d+)* \(build \d+\)$"#,
      "^Channel: (App Store|TestFlight|Nightly)$",
      "^Device: \(deviceNoun)$",
      #"^iOS: \d+(\.\d+)*$"#,
      "^Player: AVPlayer$",
    ]
    XCTAssertEqual(lines.count, patterns.count, text)
    for (line, pattern) in zip(lines, patterns) {
      XCTAssertNotNil(line.range(of: pattern, options: .regularExpression), line)
    }
    for personal in ["moviebuff", "harness@example.com", "Harness"] {
      XCTAssertFalse(text.contains(personal), "the support text names \(personal)")
    }
    attach(app, "runtime-app-info-copied")
    app.navigationBars["App info"].buttons.element(boundBy: 0).tap()

    let expected = try bundledLicenseTitles()
    let licenses = app.revealed("account.licenses")
    XCTAssertTrue(licenses.appears(within: 5))
    app.bringIntoView(licenses)
    licenses.tap()
    XCTAssertTrue(app.navigationBars["Open source licenses"].appears(within: 10))
    let notices = app.descendants(matching: .any).matching(identifier: "licenses.notice")
    XCTAssertTrue(notices.firstMatch.appears(within: 5))
    var seen: [String] = []
    for _ in 0..<12 {
      for label in notices.allElementsBoundByIndex.map(\.label) where !seen.contains(label) {
        seen.append(label)
      }
      if expected.allSatisfy({ title in seen.contains { $0.hasPrefix(title) } }) { break }
      app.swipeUp()
    }
    attach(app, "runtime-open-source-licenses")
    XCTAssertEqual(seen.count, expected.count, "rendered \(seen), expected \(expected)")
    for title in expected {
      XCTAssertTrue(seen.contains { $0.hasPrefix(title) }, "\(title) is not listed")
    }
    app.navigationBars["Open source licenses"].buttons.element(boundBy: 0).tap()
    tapSignOut(in: app)
    app.confirmSignOut()
    XCTAssertTrue(signIn.appears(within: 15))
  }

  private func bundledLicenseTitles() throws -> [String] {
    struct Manifest: Decodable {
      struct Notice: Decodable {
        let name: String
        let version: String
      }
      let packages: [Notice]
    }
    let root = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
      .deletingLastPathComponent()
    let data = try Data(
      contentsOf: root.appending(path: "Apps/iOS/Generated/OpenSourceLicenses.json"))
    let manifest = try JSONDecoder().decode(Manifest.self, from: data)
    return ["put.io "] + manifest.packages.map { "\($0.name) \($0.version)" }
  }

  private var deviceNoun: String {
    UIDevice.current.userInterfaceIdiom == .pad ? "iPad" : "iPhone"
  }

  private func openDownloads(in app: XCUIApplication) {
    let downloads = app.buttons["Downloads"].firstMatch
    app.scrollDown(toHit: downloads)
    XCTAssertTrue(downloads.appears(within: 10), "the Downloads tab is missing")
    downloads.tap()
  }

  private func tapSignOut(in app: XCUIApplication) {
    let account = app.buttons["Account"].firstMatch
    app.scrollDown(toHit: account)
    XCTAssertTrue(account.appears(within: 10), "the Account tab is missing")
    account.tap()
    let signOut = app.revealed("auth.sign-out")
    XCTAssertTrue(signOut.appears(within: 5), "Account has no Sign out")
    app.bringIntoView(signOut)
    XCTAssertTrue(signOut.becomesHittable(within: 5), "Sign out never became tappable")
    signOut.tap()
  }

  private func dismissSignOutDialog(in app: XCUIApplication) {
    let cancel = app.buttons["Cancel"].firstMatch
    if cancel.exists, cancel.isHittable {
      cancel.tap()
    } else {
      app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.08)).tap()
    }
  }

  private func waitForValue(_ target: XCUIElement, _ value: String, timeout: TimeInterval)
    -> Bool
  {
    let matched = XCTNSPredicateExpectation(
      predicate: NSPredicate(format: "value == %@", value), object: target)
    return XCTWaiter.wait(for: [matched], timeout: timeout) == .completed
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
    XCTAssertTrue(app.revealed("auth.sign-out").appears(within: 5), "a failed load hid Sign out")
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
