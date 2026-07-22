import XCTest

// Exercises the real theme-selection flow end to end: picking a theme in the
// picker, the row value updating, and the choice surviving a relaunch. The
// screenshot walk pins appearance via the PUTIO_E2E_APPEARANCE override, which
// short-circuits exactly the persistence path a user hits — so this test
// deliberately launches without it.
final class ThemeSelectionUITests: XCTestCase {
    private func launchFixtureApp(resetState: Bool) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["PUTIO_E2E_MOCK_API"] = "1"
        app.launchEnvironment["PUTIO_E2E_ACCESS_TOKEN"] = "e2e-token"
        if resetState {
            app.launchEnvironment["PUTIO_E2E_RESET_STATE"] = "1"
        }
        app.launch()
        return app
    }

    private func openAccountTab(_ app: XCUIApplication) {
        let accountTab = app.tabBars.buttons["Account"]
        XCTAssertTrue(accountTab.waitForExistence(timeout: 10))
        accountTab.tap()
    }

    func testSelectingDarkPersistsAcrossRelaunch() {
        var app = launchFixtureApp(resetState: true)
        openAccountTab(app)

        let themeRow = app.tables.staticTexts["Theme"]
        XCTAssertTrue(themeRow.waitForExistence(timeout: 5))
        themeRow.tap()

        let themeAlert = app.alerts["Theme"]
        XCTAssertTrue(themeAlert.waitForExistence(timeout: 5))
        themeAlert.buttons["Dark"].tap()

        XCTAssertTrue(
            app.tables.staticTexts["Dark"].waitForExistence(timeout: 5),
            "theme row should reflect the new selection immediately"
        )

        // Relaunch without resetting state: the persisted preference must
        // drive the row on a cold start.
        app.terminate()
        app = launchFixtureApp(resetState: false)
        openAccountTab(app)

        XCTAssertTrue(
            app.tables.staticTexts["Dark"].waitForExistence(timeout: 10),
            "theme selection should survive a relaunch"
        )
    }
}
