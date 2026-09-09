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
    XCTAssertTrue(signIn.waitForExistence(timeout: 10))
    signIn.tap()
    XCTAssertTrue(element("files.screen.0").waitForExistence(timeout: 10))
    assertFirstFile("Harness Folder")
    openPreferences()
    let sort = element("settings.default-sort")
    let initialSort = sort.label
    XCTAssertEqual(initialSort, "Default sort, Name, ascending")
    sort.tap()
    let descending = element("settings.sort.NAME_DESC")
    XCTAssertTrue(waitUntilHittable(descending))
    descending.tap()
    let retrySave = app.buttons["settings.retry-save"]
    XCTAssertTrue(retrySave.waitForExistence(timeout: 10))
    XCTAssertEqual(sort.label, initialSort, "failed save changed the account preference")
    retrySave.tap()
    let refresh = app.buttons["settings.refresh"]
    XCTAssertTrue(refresh.waitForExistence(timeout: 10))
    XCTAssertFalse(retrySave.exists, "committed save offered another mutation")
    XCTAssertFalse(sort.isEnabled, "stale account preferences remained editable")
    addScreenshot(named: "runtime-file-preferences-refresh")
    refresh.tap()
    XCTAssertTrue(refresh.waitForNonExistence(timeout: 10))
    XCTAssertTrue(waitUntilHittable(sort))
    let savedSort = sort.label
    XCTAssertEqual(savedSort, "Default sort, Name, descending")

    app.buttons["Files"].tap()
    assertFirstFile("Harness Folder")
    openPreferences()
    let reset = app.buttons["settings.reset-sort"]
    XCTAssertTrue(waitUntilHittable(reset))
    reset.tap()
    let resetConfirm = app.buttons["settings.reset-sort-confirm"].firstMatch
    XCTAssertTrue(resetConfirm.waitForExistence(timeout: 5))
    cancelConfirmation(resetConfirm)
    app.buttons["Files"].tap()
    assertFirstFile("Harness Folder")
    openPreferences()
    reset.tap()
    XCTAssertTrue(waitUntilHittable(resetConfirm))
    resetConfirm.tap()
    XCTAssertTrue(resetConfirm.waitForNonExistence(timeout: 5))
    XCTAssertTrue(waitUntilHittable(reset))
    app.buttons["Files"].tap()
    assertFirstFile("Document.pdf")
    openPreferences()

    let trash = app.switches["settings.trash"]
    let history = app.switches["settings.history"]
    let trashConfirm = app.buttons["settings.trash-disable"].firstMatch
    let historyConfirm = app.buttons["settings.history-disable"].firstMatch
    XCTAssertTrue(waitUntilHittable(trash))
    tapToggle(trash)
    XCTAssertTrue(trashConfirm.waitForExistence(timeout: 5))
    cancelConfirmation(trashConfirm)
    assertToggle(trash, enabled: true)
    XCTAssertTrue(waitUntilHittable(history))
    tapToggle(history)
    XCTAssertTrue(historyConfirm.waitForExistence(timeout: 5))
    cancelConfirmation(historyConfirm)
    assertToggle(history, enabled: true)
    XCTAssertTrue(app.buttons["History"].exists)

    tapToggle(trash)
    trashConfirm.tap()
    assertToggle(trash, enabled: false)
    tapToggle(history)
    historyConfirm.tap()
    assertToggle(history, enabled: false)
    XCTAssertTrue(app.buttons["History"].waitForNonExistence(timeout: 5))
    tapToggle(history)
    assertToggle(history, enabled: true)
    XCTAssertTrue(app.buttons["History"].waitForExistence(timeout: 5))

    tapToggle(trash)
    assertToggle(trash, enabled: true)
    let trashEntry = element("settings.manage-trash")
    XCTAssertTrue(waitUntilHittable(trashEntry))
    trashEntry.tap()
    XCTAssertTrue(app.staticTexts["Trash is empty"].waitForExistence(timeout: 10))
    app.navigationBars.buttons["BackButton"].tap()
    XCTAssertTrue(waitUntilHittable(trash))
    tapToggle(trash)
    trashConfirm.tap()
    assertToggle(trash, enabled: false)
    addScreenshot(named: "runtime-file-preferences")

    app.terminate()
    app.launchArguments.removeAll { $0 == "--putio-harness-reset-file-preferences" }
    app.launch()
    XCTAssertTrue(element("files.screen.0").waitForExistence(timeout: 15))
    assertFirstFile("Document.pdf")
    XCTAssertTrue(app.buttons["History"].exists)
    openPreferences()
    XCTAssertEqual(sort.label, savedSort)
    assertToggle(trash, enabled: false)
    assertToggle(history, enabled: true)
    app.navigationBars.buttons["BackButton"].tap()
    let signOut = element("auth.sign-out")
    XCTAssertTrue(waitUntilHittable(signOut))
    signOut.tap()
    XCTAssertTrue(signIn.waitForExistence(timeout: 10))
  }

  private func cancelConfirmation(_ confirmation: XCUIElement) {
    let cancel = app.buttons["Cancel"].firstMatch
    if cancel.exists {
      cancel.tap()
    } else {
      // Native popovers cancel by tapping outside their content.
      app.coordinate(withNormalizedOffset: CGVector(dx: 0.02, dy: 0.5)).tap()
    }
    XCTAssertTrue(confirmation.waitForNonExistence(timeout: 5))
  }

  private func openPreferences() {
    app.buttons["Account"].tap()
    let sort = element("settings.default-sort")
    if sort.exists && sort.isHittable { return }
    let entry = element("account.file-preferences")
    XCTAssertTrue(waitUntilHittable(entry))
    entry.tap()
    XCTAssertTrue(waitUntilHittable(sort))
  }

  private func assertFirstFile(_ name: String) {
    let row = app.cells.firstMatch
    let expectation = XCTNSPredicateExpectation(
      predicate: NSPredicate { _, _ in row.staticTexts[name].exists }, object: row
    )
    XCTAssertEqual(XCTWaiter.wait(for: [expectation], timeout: 10), .completed)
  }

  private func tapToggle(_ toggle: XCUIElement) {
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
