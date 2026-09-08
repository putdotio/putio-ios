import XCTest

final class HistoryJourneyTests: XCTestCase {
  private var app: XCUIApplication!

  override func setUpWithError() throws {
    try super.setUpWithError()
    continueAfterFailure = false
    app = XCUIApplication()
    app.launchArguments = ["--putio-harness-scenario", "files-browser"]
    app.launchEnvironment["PUTIO_HARNESS_MEDIA_BASE_URL"] = try XCTUnwrap(
      ProcessInfo.processInfo.environment["PUTIO_HARNESS_MEDIA_BASE_URL"]
    )
  }

  func testHistoryPagingNavigationMutationsAndSettingGate() {
    app.launch()
    signIn()
    let history = app.buttons["History"]
    XCTAssertTrue(history.waitForExistence(timeout: 5))
    history.tap()
    let folderEvent = element("history.item.810")
    let missingEvent = element("history.item.808")
    XCTAssertTrue(folderEvent.waitForExistence(timeout: 10))
    XCTAssertTrue(app.staticTexts["Today"].exists)
    XCTAssertFalse(element("history.item.807").exists, "unknown event was rendered")
    let moreRetry = app.buttons["history.more-retry"]
    reveal(moreRetry)
    XCTAssertTrue(folderEvent.exists, "failed continuation removed the first page")
    moreRetry.tap()
    reveal(element("history.item.806"))
    XCTAssertTrue(app.staticTexts["Yesterday"].exists)
    for id in [805, 804, 803, 802, 801] {
      reveal(element("history.item.\(id)"))
      if id == 803 { XCTAssertTrue(app.staticTexts["Earlier"].exists) }
    }
    XCTAssertFalse(moreRetry.exists)
    scrollToTop()
    addScreenshot(named: "runtime-history-loaded")

    pullToRefresh()
    let refreshRetry = app.buttons["history.retry"]
    XCTAssertTrue(refreshRetry.waitForExistence(timeout: 10))
    XCTAssertTrue(folderEvent.exists, "failed refresh discarded loaded history")
    addScreenshot(named: "runtime-history-error")
    refreshRetry.tap()
    XCTAssertTrue(refreshRetry.waitForNonExistence(timeout: 10))
    XCTAssertTrue(folderEvent.waitForExistence(timeout: 5))

    reveal(missingEvent)
    missingEvent.tap()
    let openRetry = app.buttons["history.open-retry"]
    XCTAssertTrue(openRetry.waitForExistence(timeout: 10))
    XCTAssertTrue(app.staticTexts["This item is no longer available."].exists)
    XCTAssertTrue(missingEvent.exists, "missing file removed its history event")
    openRetry.tap()
    XCTAssertTrue(waitUntilHittable(openRetry))
    XCTAssertTrue(missingEvent.exists)

    reveal(folderEvent)
    folderEvent.tap()
    XCTAssertTrue(element("files.screen.410").waitForExistence(timeout: 10))
    XCTAssertTrue(element("files.item.411").exists)
    app.navigationBars.buttons["BackButton"].tap()
    XCTAssertTrue(folderEvent.waitForExistence(timeout: 5))
    XCTAssertFalse(openRetry.exists)
    let videoEvent = element("history.item.809")
    reveal(videoEvent)
    videoEvent.tap()
    XCTAssertTrue(element("video.error").waitForExistence(timeout: 10))
    app.buttons["Try again"].tap()
    XCTAssertTrue(element("video.ready").waitForExistence(timeout: 15))
    element("video.done").tap()
    XCTAssertTrue(folderEvent.waitForExistence(timeout: 5))

    reveal(missingEvent)
    missingEvent.swipeLeft()
    let delete = app.buttons["Delete"]
    XCTAssertTrue(waitUntilHittable(delete))
    delete.tap()
    let mutationRetry = app.buttons["history.mutation-retry"]
    XCTAssertTrue(mutationRetry.waitForExistence(timeout: 10))
    XCTAssertTrue(missingEvent.exists, "failed deletion removed its event")
    mutationRetry.tap()
    XCTAssertTrue(missingEvent.waitForNonExistence(timeout: 10))
    XCTAssertTrue(mutationRetry.waitForNonExistence(timeout: 5))

    let clear = app.buttons["history.clear"]
    XCTAssertTrue(waitUntilHittable(clear))
    clear.tap()
    XCTAssertTrue(app.staticTexts["Clear all history?"].waitForExistence(timeout: 5))
    let cancel = app.buttons["Cancel"].firstMatch
    if cancel.exists {
      cancel.tap()
    } else {
      // Native popovers cancel by tapping outside their content.
      app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.6)).tap()
    }
    XCTAssertTrue(app.staticTexts["Clear all history?"].waitForNonExistence(timeout: 5))
    XCTAssertTrue(folderEvent.exists, "cancel cleared history")
    clear.tap()
    let confirm = app.buttons["history.clear-confirm"].firstMatch
    XCTAssertTrue(waitUntilHittable(confirm))
    confirm.tap()
    XCTAssertTrue(mutationRetry.waitForExistence(timeout: 10))
    XCTAssertTrue(folderEvent.exists, "failed clear discarded history")
    mutationRetry.tap()
    XCTAssertTrue(app.staticTexts["No history"].waitForExistence(timeout: 10))
    XCTAssertFalse(clear.exists)
    addScreenshot(named: "runtime-history-empty")
    pullToRefresh()
    XCTAssertTrue(app.staticTexts["No history"].waitForExistence(timeout: 5))

    app.buttons["Files"].tap()
    XCTAssertTrue(element("files.item.410").waitForExistence(timeout: 5))
    XCTAssertTrue(element("files.item.412").exists, "clearing history deleted files")
    signOut()
    app.terminate()
    app.launchArguments.append("--putio-harness-history-disabled")
    app.launch()
    signIn()
    XCTAssertFalse(app.buttons["History"].exists, "disabled history remained in the tab bar")
    signOut()
  }

  private func signIn() {
    let signIn = element("auth.sign-in")
    XCTAssertTrue(signIn.waitForExistence(timeout: 10))
    signIn.tap()
    XCTAssertTrue(element("files.screen.0").waitForExistence(timeout: 10))
  }

  private func signOut() {
    app.buttons["Account"].tap()
    let signOut = element("auth.sign-out")
    XCTAssertTrue(signOut.waitForExistence(timeout: 5))
    signOut.tap()
    XCTAssertTrue(element("auth.sign-in").waitForExistence(timeout: 10))
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

  private func reveal(_ element: XCUIElement) {
    for _ in 0..<4 {
      if element.exists && element.isHittable { return }
      app.swipeUp()
    }
    XCTAssertTrue(waitUntilHittable(element), "history element unavailable: \(element)")
  }

  private func scrollToTop() {
    for _ in 0..<4 {
      if element("history.item.810").isHittable { return }
      app.swipeDown()
    }
    XCTAssertTrue(waitUntilHittable(element("history.item.810")))
  }

  private func pullToRefresh() {
    let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.28))
    let end = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.8))
    start.press(forDuration: 0.1, thenDragTo: end, withVelocity: .slow, thenHoldForDuration: 1)
  }

  private func addScreenshot(named name: String) {
    let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
    attachment.name = name
    attachment.lifetime = .keepAlways
    add(attachment)
  }
}
