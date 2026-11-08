import XCTest

final class PrivacyControlsUITests: XCTestCase {
    private func launchFixtureApp() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["PUTIO_E2E_MOCK_API"] = "1"
        app.launchEnvironment["PUTIO_E2E_ACCESS_TOKEN"] = "e2e-token"
        app.launchEnvironment["PUTIO_E2E_RESET_STATE"] = "1"
        app.launchEnvironment["PUTIO_E2E_PRODUCT_ANALYTICS_UNANSWERED"] = "1"
        app.launch()
        return app
    }

    func testUnansweredAccountIsAskedAndDontAllowClosesThePrompt() {
        let app = launchFixtureApp()

        guard app.waitForSignedInTabBar() else { return }
        let title = app.staticTexts["Turn on product analytics?"]
        XCTAssertTrue(title.appears(within: 10), "an account with no answer should be asked")
        XCTAssertTrue(app.staticTexts["What we never send"].exists)
        XCTAssertTrue(app.staticTexts["What we'd send"].exists)
        attachScreenshot(of: app, named: "Product analytics prompt")

        app.buttons["Don't allow"].tap()

        XCTAssertTrue(title.disappears(within: 10), "an answer should close the prompt")
        app.tabItem("History").tap()
        XCTAssertTrue(app.tables["putio-history-table"].appears(within: 5))
    }

    private func attachScreenshot(of app: XCUIApplication, named name: String) {
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = name
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }
}
