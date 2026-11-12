import XCTest

final class ProductAnalyticsPromptJourneyTests: XCTestCase {
  private static let launchArguments = [
    "--putio-harness-scenario", "files-browser", "--putio-harness-analytics-prompt",
    "--putio-harness-file-preferences", "--putio-harness-reset-file-preferences",
  ]

  func testPromptRetriesAndSavesTheChoiceOnce() {
    continueAfterFailure = false
    let app = XCUIApplication()
    app.launchArguments = Self.launchArguments
    app.launch()
    let signIn = app.descendants(matching: .any)["auth.sign-in"]
    XCTAssertTrue(signIn.appears(within: 10))
    signIn.tap()
    let prompt = app.descendants(matching: .any)["analytics-prompt"]
    XCTAssertTrue(prompt.appears(within: 10))
    let allow = app.buttons["analytics-prompt.allow"]
    let deny = app.buttons["analytics-prompt.deny"]
    XCTAssertTrue(allow.appears(within: 5))
    XCTAssertTrue(deny.exists)
    XCTAssertEqual(deny.label, "Don’t allow")
    XCTAssertTrue(app.descendants(matching: .any)["analytics-prompt.privacy-policy"].exists)
    attachScreenshot(named: "runtime-analytics-prompt")

    allow.tap()
    let saving = XCTNSPredicateExpectation(
      predicate: NSPredicate(format: "isEnabled == false"), object: allow)
    XCTAssertEqual(XCTWaiter.wait(for: [saving], timeout: 2), .completed, "Allow stays enabled")
    XCTAssertFalse(deny.isEnabled, "Don’t allow stays enabled while saving")
    attachScreenshot(named: "runtime-analytics-prompt-saving")

    let failure = app.descendants(matching: .any)["analytics-prompt.failure"]
    XCTAssertTrue(failure.appears(within: 10))
    XCTAssertTrue(failure.label.contains("Couldn’t save this setting"), failure.label)
    XCTAssertTrue(failure.label.contains("Check your connection and try again."), failure.label)
    XCTAssertTrue(prompt.exists, "a failed save closed the sheet")
    XCTAssertTrue(allow.isEnabled)
    XCTAssertTrue(deny.isEnabled)
    attachScreenshot(named: "runtime-analytics-prompt-failed")

    allow.tap()
    XCTAssertTrue(prompt.disappears(within: 15))

    let account = app.buttons["Account"]
    XCTAssertTrue(account.appears(within: 5))
    account.tap()
    let privacy = app.revealed("account.privacy")
    XCTAssertTrue(privacy.appears(within: 5))
    let summary = XCTNSPredicateExpectation(
      predicate: NSPredicate(format: "label CONTAINS %@", "Analytics on"),
      object: privacy)
    XCTAssertEqual(XCTWaiter.wait(for: [summary], timeout: 5), .completed)
    let signOut = app.revealed("auth.sign-out", maximumSwipes: 12)
    XCTAssertTrue(signOut.appears(within: 5))
    if !signOut.isHittable { app.swipeUp() }
    signOut.tap()
    app.confirmSignOut()
    XCTAssertTrue(signIn.appears(within: 10))
  }

  func testSwipingThePromptAwayStoresNoAnswer() {
    continueAfterFailure = false
    let app = XCUIApplication()
    app.launchArguments = Self.launchArguments
    app.launch()
    let prompt = app.descendants(matching: .any)["analytics-prompt"]
    reachPrompt(app, prompt)
    prompt.swipeDown(velocity: .fast)
    XCTAssertTrue(prompt.disappears(within: 5), "swiping down left the prompt open")

    let account = app.buttons["Account"]
    XCTAssertTrue(account.appears(within: 5))
    account.tap()
    let signOut = app.revealed("auth.sign-out", maximumSwipes: 12)
    XCTAssertTrue(signOut.appears(within: 5))
    if !signOut.isHittable { app.swipeUp() }
    signOut.tap()
    app.confirmSignOut()
    reachPrompt(app, prompt)
    XCTAssertTrue(app.buttons["analytics-prompt.allow"].isEnabled)
  }

  private func reachPrompt(_ app: XCUIApplication, _ prompt: XCUIElement) {
    let signIn = app.descendants(matching: .any)["auth.sign-in"]
    let deadline = Date.now.addingTimeInterval(15)
    while !prompt.exists, !signIn.exists, Date.now < deadline {
      _ = prompt.appears(within: 0.5)
    }
    if signIn.exists { signIn.tap() }
    XCTAssertTrue(prompt.appears(within: 10), "the prompt never appeared")
  }

  private func attachScreenshot(named name: String) {
    let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
    attachment.name = name
    attachment.lifetime = .keepAlways
    add(attachment)
  }
}
