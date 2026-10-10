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
    XCTAssertTrue(signIn.waitForExistence(timeout: 10))
    signIn.tap()
    let account = app.buttons["Account"]
    XCTAssertTrue(account.waitForExistence(timeout: 10))
    account.tap()
    let requests = app.descendants(matching: .any)["account.rating-link-requests"]
    XCTAssertTrue(requests.waitForExistence(timeout: 5))
    XCTAssertEqual(requests.value as? String, "0|")
    let rating = app.revealed("account.rate-app")
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
    // Seeded builds carry no Intercom keys, so Contact us falls back to email.
    let contact = app.revealed("account.contact-support")
    XCTAssertTrue(contact.waitForExistence(timeout: 5))
    if !contact.isHittable { app.swipeUp() }
    contact.tap()
    let mailed = "2|mailto:support@put.io"
    let contacted = XCTNSPredicateExpectation(
      predicate: NSPredicate(format: "value == %@", mailed), object: requests)
    XCTAssertEqual(XCTWaiter.wait(for: [contacted], timeout: 5), .completed)
    // Scrolling minimizes the tab bar; scroll back so the tabs are buttons again.
    let files = app.buttons["Files"]
    if !files.exists { app.swipeDown() }
    XCTAssertTrue(files.waitForExistence(timeout: 5))
    files.tap()
    account.tap()
    XCTAssertTrue(app.navigationBars["Account"].waitForExistence(timeout: 5))
    XCTAssertTrue(app.revealed("account.rate-app").waitForExistence(timeout: 5))
    XCTAssertEqual(requests.value as? String, mailed)
    let signOut = app.revealed("auth.sign-out")
    XCTAssertTrue(signOut.waitForExistence(timeout: 5))
    if !signOut.isHittable { app.swipeUp() }
    let signOutHittable = XCTNSPredicateExpectation(
      predicate: NSPredicate(format: "hittable == true"), object: signOut)
    XCTAssertEqual(XCTWaiter.wait(for: [signOutHittable], timeout: 5), .completed)
    signOut.tap()
    app.confirmSignOut()
    XCTAssertTrue(signIn.waitForExistence(timeout: 10))
  }
}
