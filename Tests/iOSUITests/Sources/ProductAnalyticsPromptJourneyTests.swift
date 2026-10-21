import XCTest

final class ProductAnalyticsPromptJourneyTests: XCTestCase {
  func testPromptRetriesAndSavesTheChoiceOnce() {
    continueAfterFailure = false
    let app = XCUIApplication()
    app.launchArguments = [
      "--putio-harness-scenario", "files-browser", "--putio-harness-analytics-prompt",
      "--putio-harness-file-preferences", "--putio-harness-reset-file-preferences",
    ]
    app.launch()
    let signIn = app.descendants(matching: .any)["auth.sign-in"]
    XCTAssertTrue(signIn.appears(within: 10))
    signIn.tap()
    let prompt = app.descendants(matching: .any)["analytics-prompt"]
    XCTAssertTrue(prompt.appears(within: 10))
    let allow = app.buttons["analytics-prompt.allow"]
    XCTAssertTrue(allow.appears(within: 5))
    XCTAssertTrue(app.buttons["analytics-prompt.deny"].exists)
    let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
    attachment.name = "runtime-analytics-prompt"
    attachment.lifetime = .keepAlways
    add(attachment)

    // The fixture fails the first settings save; the retry sends the setting
    // and then the answer.
    allow.tap()
    let failure = app.descendants(matching: .any)["analytics-prompt.failure"]
    XCTAssertTrue(failure.appears(within: 5))
    allow.tap()
    XCTAssertTrue(prompt.disappears(within: 10))

    let account = app.buttons["Account"]
    XCTAssertTrue(account.appears(within: 5))
    account.tap()
    let privacy = app.revealed("account.privacy")
    XCTAssertTrue(privacy.appears(within: 5))
    let summary = XCTNSPredicateExpectation(
      predicate: NSPredicate(format: "label CONTAINS %@", "Product analytics on"),
      object: privacy)
    XCTAssertEqual(XCTWaiter.wait(for: [summary], timeout: 5), .completed)
    let signOut = app.revealed("auth.sign-out", maximumSwipes: 12)
    XCTAssertTrue(signOut.appears(within: 5))
    if !signOut.isHittable { app.swipeUp() }
    signOut.tap()
    app.confirmSignOut()
    XCTAssertTrue(signIn.appears(within: 10))
  }
}
