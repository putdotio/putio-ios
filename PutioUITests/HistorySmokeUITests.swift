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

    // Events must appear on the initial load, without a pull-to-refresh.
    func testHistoryScreenShowsEventsOnFirstOpen() {
        let app = launchFixtureApp()

        guard app.waitForSignedInTabBar() else { return }
        app.tabItem("History").tap()

        let table = app.tables["putio-history-table"]
        XCTAssertTrue(table.waitForExistence(timeout: 5))

        let uploadCell = table.staticTexts["Tears of Steel.mp4"]
        XCTAssertTrue(
            uploadCell.waitForExistence(timeout: 5),
            "history events should render on first open without pull-to-refresh"
        )
        XCTAssertTrue(table.staticTexts["Cosmos Laundromat"].exists)
        XCTAssertTrue(table.staticTexts["Today"].exists)
        XCTAssertTrue(table.staticTexts["Yesterday"].exists)
        XCTAssertTrue(table.staticTexts["Ancient Times"].exists)

        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "History first open"
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }
}
