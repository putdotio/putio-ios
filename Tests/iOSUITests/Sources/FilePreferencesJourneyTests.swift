import XCTest

final class FilePreferencesJourneyTests: XCTestCase {
  private var app: XCUIApplication!

  override func setUpWithError() throws {
    try super.setUpWithError()
    continueAfterFailure = false
    app = XCUIApplication()
    app.launchArguments = [
      "--putio-harness-scenario", "files-browser", "--putio-harness-file-preferences",
      "--putio-harness-reset-file-preferences",
    ]
    app.launchEnvironment["PUTIO_HARNESS_MEDIA_BASE_URL"] = try XCTUnwrap(
      ProcessInfo.processInfo.environment["PUTIO_HARNESS_MEDIA_BASE_URL"]
    )
  }

  func testFilePreferencesFailureRecoveryResetAndPersistence() {
    app.launch()
    let signIn = element("auth.sign-in")
    XCTAssertTrue(signIn.appears(within: 10))
    signIn.tap()
    XCTAssertTrue(element("files.screen.0").appears(within: 10))
    assertFirstFile("Harness Folder")
    openPreferences()
    let sort = element("settings.default-sort")
    let initialSort = sort.label
    XCTAssertEqual(initialSort, "Default sort order, Name, A to Z")
    let descending = app.buttons["Name, Z to A"].firstMatch
    sort.tap()
    XCTAssertTrue(waitUntilHittable(descending))
    descending.tap()
    XCTAssertTrue(app.staticTexts["Couldn’t save this setting"].appears(within: 10))
    XCTAssertTrue(
      waitFor(NSPredicate(format: "label == %@ AND enabled == true", initialSort), sort),
      "failed save changed the account preference")
    sort.tap()
    XCTAssertTrue(waitUntilHittable(descending))
    descending.tap()
    let retry = app.revealed("account.settings-retry")
    XCTAssertTrue(retry.appears(within: 10))
    XCTAssertTrue(element("account.settings-failed").exists)
    XCTAssertFalse(sort.exists, "unconfirmed account preferences stayed editable")
    addScreenshot(named: "runtime-file-preferences-refresh")
    retry.tap()
    XCTAssertTrue(retry.disappears(within: 10))
    XCTAssertTrue(waitUntilHittable(app.revealed("settings.default-sort")))
    XCTAssertEqual(sort.label, "Default sort order, Name, Z to A")

    app.showTabBar()
    app.buttons["Files"].tap()
    assertFirstFile("Harness Folder")
    openPreferences()
    let reset = app.revealed("settings.reset-sort")
    XCTAssertTrue(waitUntilHittable(reset))
    reset.tap()
    let resetAlert = app.putioAlert("Reset all folder sorts?")
    let resetConfirm = resetAlert.buttons["Reset folder sorts"].firstMatch
    XCTAssertTrue(resetConfirm.appears(within: 5))
    XCTAssertTrue(
      resetAlert.staticTexts["Every folder will use your account’s default sort."].exists)
    cancelConfirmation(resetConfirm)
    app.showTabBar()
    app.buttons["Files"].tap()
    assertFirstFile("Harness Folder")
    openPreferences()
    reset.tap()
    XCTAssertTrue(resetConfirm.appears(within: 5))
    resetConfirm.tap()
    XCTAssertTrue(resetConfirm.disappears(within: 5))
    XCTAssertTrue(waitUntilHittable(reset))
    app.showTabBar()
    app.buttons["Files"].tap()
    assertFirstFile("Document.pdf")
    openPreferences()
    sort.tap()
    let smallestFirst = app.buttons["Size, smallest first"].firstMatch
    XCTAssertTrue(waitUntilHittable(smallestFirst))
    smallestFirst.tap()
    XCTAssertTrue(
      waitFor(
        NSPredicate(
          format: "label == %@ AND enabled == true", "Default sort order, Size, smallest first"),
        sort))
    let savedSort = sort.label
    app.showTabBar()
    app.buttons["Files"].tap()
    assertFirstFile("Harness Poster.png")
    openPreferences()

    let trash = app.switches["settings.trash"]
    let history = app.switches["settings.history"]
    let trashAlert = app.putioAlert("Turn off trash?")
    let trashConfirm = trashAlert.buttons["Turn off"].firstMatch
    let historyAlert = app.putioAlert("Turn off history?")
    let historyConfirm = historyAlert.buttons["Turn off"].firstMatch
    XCTAssertTrue(waitUntilHittable(trash))
    tapToggle(trash)
    XCTAssertTrue(trashConfirm.appears(within: 5))
    XCTAssertTrue(
      trashAlert.staticTexts[
        "Deleted files will no longer be recoverable. Files already in trash stay for their 14 days."
      ].exists)
    cancelConfirmation(trashConfirm)
    assertToggle(trash, enabled: true)
    assertTrashRow(shown: true)
    XCTAssertTrue(waitUntilHittable(app.revealed("settings.history")))
    tapToggle(history)
    XCTAssertTrue(historyConfirm.appears(within: 5))
    XCTAssertTrue(
      historyAlert.staticTexts[
        "Existing history will be cleared and new account events will no longer be saved."
      ].exists)
    cancelConfirmation(historyConfirm)
    assertToggle(history, enabled: true)
    app.showTabBar()
    XCTAssertTrue(app.buttons["History"].exists)

    tapToggle(trash)
    trashConfirm.tap()
    assertToggle(trash, enabled: false)
    assertTrashRow(shown: false)
    tapToggle(history)
    historyConfirm.tap()
    assertToggle(history, enabled: false)
    app.showTabBar()
    XCTAssertTrue(app.buttons["Files"].exists)
    XCTAssertTrue(app.buttons["History"].disappears(within: 5))
    tapToggle(history)
    assertToggle(history, enabled: true)
    app.showTabBar()
    XCTAssertTrue(app.buttons["History"].appears(within: 5))

    app.scrollDown(toHit: trash)
    tapToggle(trash)
    assertToggle(trash, enabled: true)
    assertTrashRow(shown: true)
    tapToggle(trash)
    trashConfirm.tap()
    assertToggle(trash, enabled: false)
    assertTrashRow(shown: false)
    addScreenshot(named: "runtime-file-preferences")

    // Privacy choices are account settings too: diagnostics start on,
    // product analytics starts off, and both survive the relaunch below.
    let diagnostics = app.switches["privacy.diagnostics"]
    let analytics = app.switches["privacy.product-analytics"]
    assertPrivacySummary("Diagnostics on · Analytics off")
    openPrivacy()
    XCTAssertTrue(element("privacy.strictly-necessary").exists)
    XCTAssertTrue(element("privacy.policy").exists)
    XCTAssertTrue(element("privacy.services").exists)
    assertToggle(diagnostics, enabled: true)
    assertToggle(analytics, enabled: false)
    tapToggle(analytics)
    assertToggle(analytics, enabled: true)
    tapToggle(diagnostics)
    assertToggle(diagnostics, enabled: false)
    addScreenshot(named: "runtime-privacy-controls")
    app.navigationBars.buttons["BackButton"].tap()
    assertPrivacySummary("Diagnostics off · Analytics on")

    app.terminate()
    app.launchArguments.removeAll { $0 == "--putio-harness-reset-file-preferences" }
    app.launch()
    XCTAssertTrue(element("files.screen.0").appears(within: 15))
    assertFirstFile("Harness Poster.png")
    app.showTabBar()
    XCTAssertTrue(app.buttons["History"].exists)
    openPreferences()
    XCTAssertEqual(sort.label, savedSort)
    assertTrashRow(shown: false)
    assertToggle(trash, enabled: false)
    _ = app.revealed("settings.history")
    assertToggle(history, enabled: true)
    assertPrivacySummary("Diagnostics off · Analytics on")
    openPrivacy()
    assertToggle(diagnostics, enabled: false)
    assertToggle(analytics, enabled: true)
    app.navigationBars.buttons["BackButton"].tap()
    signOut()
    XCTAssertTrue(signIn.appears(within: 10))
  }

  func testFailedPrivacySaveRevertsWithToast() {
    app.launch()
    let signIn = element("auth.sign-in")
    XCTAssertTrue(signIn.appears(within: 10))
    signIn.tap()
    XCTAssertTrue(element("files.screen.0").appears(within: 10))
    openPreferences()
    openPrivacy()
    let diagnostics = app.switches["privacy.diagnostics"]
    assertToggle(diagnostics, enabled: true)
    tapToggle(diagnostics)
    let toast = app.staticTexts["Couldn’t save this setting"]
    XCTAssertTrue(toast.appears(within: 10))
    addScreenshot(named: "runtime-privacy-save-failed")
    assertToggle(diagnostics, enabled: true)
    XCTAssertTrue(toast.disappears(within: 10))
    tapToggle(diagnostics)
    assertToggle(diagnostics, enabled: false)
    XCTAssertFalse(toast.exists)
    app.navigationBars.buttons["BackButton"].tap()
    assertPrivacySummary("Diagnostics off · Analytics off")
    signOut()
    XCTAssertTrue(signIn.appears(within: 10))
  }

  private func signOut() {
    let signOut = app.revealed("auth.sign-out")
    XCTAssertTrue(signOut.appears(within: 5))
    if !signOut.isHittable { app.swipeUp() }
    XCTAssertTrue(waitUntilHittable(signOut))
    signOut.tap()
    app.confirmSignOut()
  }

  private func cancelConfirmation(_ confirmation: XCUIElement) {
    let cancel = app.buttons["Cancel"].firstMatch
    if cancel.exists {
      cancel.tap()
    } else {
      // Native popovers cancel by tapping outside their content.
      app.coordinate(withNormalizedOffset: CGVector(dx: 0.02, dy: 0.5)).tap()
    }
    XCTAssertTrue(confirmation.disappears(within: 5))
  }

  private func assertTrashRow(shown: Bool, line: UInt = #line) {
    let storage = element("account.storage-used")
    app.scrollDown(toHit: storage)
    XCTAssertTrue(waitUntilHittable(storage), line: line)
    let row = element("account.trash")
    XCTAssertTrue(
      shown ? row.appears(within: 5) : row.disappears(within: 5),
      "the Library Trash row is \(shown ? "missing" : "still shown")", line: line)
  }

  private func waitFor(_ predicate: NSPredicate, _ element: XCUIElement) -> Bool {
    let expectation = XCTNSPredicateExpectation(predicate: predicate, object: element)
    return XCTWaiter.wait(for: [expectation], timeout: 10) == .completed
  }

  private func openPreferences() {
    app.buttons["Account"].tap()
    XCTAssertTrue(waitUntilHittable(app.revealed("settings.default-sort")))
  }

  private func openPrivacy() {
    let entry = app.revealed("account.privacy")
    XCTAssertTrue(waitUntilHittable(entry))
    entry.tap()
    XCTAssertTrue(waitUntilHittable(app.switches["privacy.diagnostics"]))
  }

  private func assertPrivacySummary(_ summary: String) {
    let entry = app.revealed("account.privacy")
    XCTAssertTrue(waitUntilHittable(entry))
    XCTAssertTrue(
      waitFor(NSPredicate(format: "label CONTAINS %@", summary), entry),
      "Account row read \(entry.label)")
  }

  private func assertFirstFile(_ name: String) {
    let row = app.buttons.matching(
      NSPredicate(format: "identifier BEGINSWITH %@", "files.item.")
    ).firstMatch
    let expectation = XCTNSPredicateExpectation(
      predicate: NSPredicate { _, _ in row.staticTexts[name].exists }, object: row
    )
    XCTAssertEqual(XCTWaiter.wait(for: [expectation], timeout: 10), .completed)
  }

  private func tapToggle(_ toggle: XCUIElement) {
    app.bringIntoView(toggle)
    XCTAssertTrue(waitUntilHittable(toggle))
    // Form exposes the full row as the switch accessibility frame.
    toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
  }

  private func assertToggle(_ toggle: XCUIElement, enabled: Bool) {
    let expectation = XCTNSPredicateExpectation(
      predicate: NSPredicate(format: "value == %@ AND enabled == true", enabled ? "1" : "0"),
      object: toggle
    )
    XCTAssertEqual(XCTWaiter.wait(for: [expectation], timeout: 10), .completed)
  }

  private func element(_ identifier: String) -> XCUIElement {
    app.descendants(matching: .any)[identifier]
  }

  private func waitUntilHittable(_ element: XCUIElement) -> Bool {
    let expectation = XCTNSPredicateExpectation(
      predicate: NSPredicate(format: "hittable == true AND enabled == true"), object: element
    )
    return XCTWaiter.wait(for: [expectation], timeout: 5) == .completed
  }

  private func addScreenshot(named name: String) {
    let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
    attachment.name = name
    attachment.lifetime = .keepAlways
    add(attachment)
  }
}
