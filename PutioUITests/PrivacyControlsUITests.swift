import XCTest

final class PrivacyControlsUITests: XCTestCase {
    private func launchFixtureApp(promptUnanswered: Bool = false) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["PUTIO_E2E_MOCK_API"] = "1"
        app.launchEnvironment["PUTIO_E2E_ACCESS_TOKEN"] = "e2e-token"
        app.launchEnvironment["PUTIO_E2E_RESET_STATE"] = "1"
        if promptUnanswered {
            app.launchEnvironment["PUTIO_E2E_PRODUCT_ANALYTICS_UNANSWERED"] = "1"
        }
        app.launch()
        return app
    }

    func testUnansweredAccountIsAskedAndDontAllowClosesThePrompt() {
        let app = launchFixtureApp(promptUnanswered: true)

        guard app.waitForSignedInTabBar() else { return }
        let title = app.staticTexts["Turn on product analytics?"]
        XCTAssertTrue(title.waitForExistence(timeout: 10), "an account with no answer should be asked")
        XCTAssertTrue(app.staticTexts["What we never send"].exists)
        XCTAssertTrue(app.staticTexts["What we'd send"].exists)
        // Presentation animations race capture; let them settle.
        Thread.sleep(forTimeInterval: 0.8)
        attachScreenshot(of: app, named: "Product analytics prompt")

        app.buttons["Don't allow"].tap()

        XCTAssertTrue(title.waitForNonExistence(timeout: 10), "an answer should close the prompt")
        app.tabItem("History").tap()
        XCTAssertTrue(app.tables["putio-history-table"].waitForExistence(timeout: 5))
    }

    func testPrivacySwitchesSaveAndFollowTheAnswer() {
        let app = launchFixtureApp()

        guard app.waitForSignedInTabBar() else { return }
        app.tabItem("Account").tap()

        let table = app.tables.firstMatch
        XCTAssertTrue(table.staticTexts["Manage your trash"].waitForExistence(timeout: 10))
        let row = table.cells.containing(.staticText, identifier: "Privacy controls").firstMatch
        for _ in 0..<10 where !(row.exists && row.isHittable) {
            table.swipeUp(velocity: .slow)
        }
        XCTAssertTrue(row.isHittable, "Account should have one Privacy controls row")
        XCTAssertTrue(row.staticTexts["Diagnostics on · Product analytics off"].exists, "the row should show the current state")
        XCTAssertFalse(table.staticTexts["Strictly necessary"].exists, "the controls live on their own page")
        attachScreenshot(of: app, named: "Account privacy row")
        row.tap()

        XCTAssertTrue(app.navigationBars["Privacy controls"].waitForExistence(timeout: 5))
        let page = app.tables.firstMatch
        let analytics = page.cells.containing(.staticText, identifier: "Product analytics").firstMatch
        XCTAssertTrue(analytics.waitForExistence(timeout: 5) && analytics.isHittable, "the Product analytics row should be reachable")
        XCTAssertTrue(page.staticTexts["Always on"].exists)
        XCTAssertTrue(page.staticTexts["Needed for sign-in, security, transfers, downloads, playback, billing, and saving your choices."].exists)
        XCTAssertTrue(page.staticTexts["Diagnostics and product analytics never send filenames, media titles, URLs, search text, or tokens."].exists)
        XCTAssertTrue(page.staticTexts["Privacy policy"].exists)
        XCTAssertTrue(page.staticTexts["Services we use"].exists)

        let diagnosticsSwitch = page.cells.containing(.staticText, identifier: "Diagnostics").switches.firstMatch
        let analyticsSwitch = analytics.switches.firstMatch
        XCTAssertEqual(diagnosticsSwitch.value as? String, "1")
        XCTAssertEqual(analyticsSwitch.value as? String, "0")

        diagnosticsSwitch.tap()
        XCTAssertTrue(waitForValue("0", of: diagnosticsSwitch), "Diagnostics should turn off once put.io saves it")

        analyticsSwitch.tap()
        XCTAssertTrue(waitForValue("1", of: analyticsSwitch), "Product analytics should turn on once put.io saves it")

        Thread.sleep(forTimeInterval: 0.8)
        attachScreenshot(of: app, named: "Privacy controls")

        app.navigationBars["Privacy controls"].buttons["Account"].tap()
        XCTAssertTrue(
            table.staticTexts["Diagnostics off · Product analytics on"].waitForExistence(timeout: 5),
            "the Account row should follow the saved answers"
        )
    }

    private func waitForValue(_ value: String, of element: XCUIElement) -> Bool {
        let matches = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", value), object: element)
        return XCTWaiter.wait(for: [matches], timeout: 10) == .completed
    }

    private func attachScreenshot(of app: XCUIApplication, named name: String) {
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = name
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }
}
