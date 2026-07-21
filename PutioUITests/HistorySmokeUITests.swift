import XCTest

final class HistorySmokeUITests: XCTestCase {
    private func launchFixtureApp() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["PUTIO_E2E_MOCK_API"] = "1"
        app.launchEnvironment["PUTIO_E2E_ACCESS_TOKEN"] = "e2e-token"
        app.launchEnvironment["PUTIO_E2E_RESET_STATE"] = "1"
        app.launch()
        return app
    }

    // Regression guard for the first-open render: history events must appear on the
    // initial load, without a pull-to-refresh.
    func testHistoryScreenShowsEventsOnFirstOpen() {
        let app = launchFixtureApp()

        let historyTab = app.tabBars.buttons["History"]
        XCTAssertTrue(historyTab.waitForExistence(timeout: 10))
        historyTab.tap()

        let table = app.tables["putio-history-table"]
        XCTAssertTrue(table.waitForExistence(timeout: 5))

        let uploadCell = table.staticTexts["E2E Upload.mp4"]
        XCTAssertTrue(
            uploadCell.waitForExistence(timeout: 5),
            "history events should render on first open without pull-to-refresh"
        )
        XCTAssertTrue(table.staticTexts["E2E Transfer"].exists)
        XCTAssertTrue(table.staticTexts["Today"].exists)
        XCTAssertTrue(table.staticTexts["Yesterday"].exists)
        XCTAssertTrue(table.staticTexts["Ancient Times"].exists)

        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "History first open"
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }
}
