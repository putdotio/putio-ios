import XCTest

final class HistoryErrorUITests: XCTestCase {
    private func launchFixtureApp(failRoutes: String) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["PUTIO_E2E_MOCK_API"] = "1"
        app.launchEnvironment["PUTIO_E2E_ACCESS_TOKEN"] = "e2e-token"
        app.launchEnvironment["PUTIO_E2E_RESET_STATE"] = "1"
        app.launchEnvironment["PUTIO_E2E_FAIL_ROUTES"] = failRoutes
        app.launch()
        return app
    }

    // Regression guard for the failure path: an API error on the history feed must
    // surface the error state view, not leave the screen blank or stuck on a loader.
    func testHistoryScreenShowsErrorStateWhenEventsFailToLoad() {
        let app = launchFixtureApp(failRoutes: "GET /v2/events/list")

        guard app.waitForSignedInTabBar() else { return }
        app.tabBars.buttons["History"].tap()

        let errorHeading = app.staticTexts["Oops"]
        XCTAssertTrue(
            errorHeading.waitForExistence(timeout: 10),
            "a failed history load should show the error state view"
        )
        XCTAssertTrue(app.staticTexts["An error occurred, please try again :("].exists)
        XCTAssertFalse(app.tables["putio-history-table"].staticTexts["Tears of Steel.mp4"].exists)

        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "History load failure"
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }
}
