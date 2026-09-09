import XCTest

final class AccountJourneyTests: XCTestCase {
  func testRatingLinkOpensReviewPageOnlyAfterExplicitTap() {
    continueAfterFailure = false
    let app = XCUIApplication()
    app.launchArguments = [
      "--putio-harness-scenario", "files-browser", "--putio-harness-rating-link",
    ]
    app.launch()
    let signIn = app.descendants(matching: .any)["auth.sign-in"]
    XCTAssertTrue(signIn.waitForExistence(timeout: 10))
    signIn.tap()
    let account = app.buttons["Account"]
    XCTAssertTrue(account.waitForExistence(timeout: 10))
    account.tap()
    let requests = app.descendants(matching: .any)["account.rating-link-requests"]
    XCTAssertTrue(requests.waitForExistence(timeout: 5))
    XCTAssertEqual(requests.value as? String, "0|")
    let rating = app.descendants(matching: .any)["account.rate-app"]
    XCTAssertTrue(rating.waitForExistence(timeout: 5))
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
    app.buttons["Files"].tap()
    account.tap()
    XCTAssertTrue(app.navigationBars["Account"].waitForExistence(timeout: 5))
    XCTAssertTrue(rating.waitForExistence(timeout: 5))
    XCTAssertEqual(requests.value as? String, expected)
    let signOut = app.descendants(matching: .any)["auth.sign-out"]
    XCTAssertTrue(signOut.waitForExistence(timeout: 5))
    if !signOut.isHittable { app.swipeUp() }
    signOut.tap()
    XCTAssertTrue(signIn.waitForExistence(timeout: 10))
  }
}
