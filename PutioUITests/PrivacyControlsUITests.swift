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
        let header = table.staticTexts["Privacy controls"]
        for _ in 0..<10 where !(header.exists && header.isHittable) {
            table.swipeUp(velocity: .slow)
        }
        // Header to the top, so the whole group is on screen.
        header.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            .press(forDuration: 0.3, thenDragTo: table.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.1)))
        let analytics = table.cells.containing(.staticText, identifier: "Product analytics").firstMatch
        XCTAssertTrue(analytics.waitForExistence(timeout: 5) && analytics.isHittable, "the Product analytics row should be reachable")
        XCTAssertTrue(table.staticTexts["Always on"].exists)

        let diagnosticsSwitch = table.cells.containing(.staticText, identifier: "Diagnostics").switches.firstMatch
        let analyticsSwitch = analytics.switches.firstMatch
        XCTAssertEqual(diagnosticsSwitch.value as? String, "1")
        XCTAssertEqual(analyticsSwitch.value as? String, "0")

        diagnosticsSwitch.tap()
        XCTAssertTrue(waitForValue("0", of: diagnosticsSwitch), "Diagnostics should turn off once put.io saves it")

        analyticsSwitch.tap()
        XCTAssertTrue(waitForValue("1", of: analyticsSwitch), "Product analytics should turn on once put.io saves it")

        Thread.sleep(forTimeInterval: 0.8)
        attachScreenshot(of: app, named: "Privacy controls")
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
