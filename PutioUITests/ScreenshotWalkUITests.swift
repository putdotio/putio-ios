import XCTest

// Captures labeled screenshots of every main screen into the result bundle,
// in both appearance modes. The grids extracted from
// build/e2e-simulator.xcresult are the review aids for theme work.
final class ScreenshotWalkUITests: XCTestCase {
    private func launchFixtureApp(appearance: String) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["PUTIO_E2E_MOCK_API"] = "1"
        app.launchEnvironment["PUTIO_E2E_ACCESS_TOKEN"] = "e2e-token"
        app.launchEnvironment["PUTIO_E2E_RESET_STATE"] = "1"
        app.launchEnvironment["PUTIO_E2E_APPEARANCE"] = appearance
        app.launch()
        return app
    }

    private func capture(_ app: XCUIApplication, named name: String) {
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = name
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }

    private func walkMainScreens(appearance: String) {
        let app = launchFixtureApp(appearance: appearance)

        XCTAssertTrue(app.tables["putio-files-table"].cells["putio-file-42"].waitForExistence(timeout: 10))
        capture(app, named: "walk-\(appearance)-files")

        for tab in ["Downloads", "History", "Account"] {
            let button = app.tabBars.buttons[tab]
            XCTAssertTrue(button.waitForExistence(timeout: 5), "\(tab) tab should exist")
            button.tap()
            // Let the screen settle before capturing.
            _ = app.navigationBars.firstMatch.waitForExistence(timeout: 5)
            capture(app, named: "walk-\(appearance)-\(tab.lowercased())")
        }

        let trashRow = app.tables.staticTexts["Manage your trash"]
        XCTAssertTrue(trashRow.waitForExistence(timeout: 5))
        trashRow.tap()
        XCTAssertTrue(app.staticTexts["E2E Trashed Movie.mp4"].waitForExistence(timeout: 5))
        capture(app, named: "walk-\(appearance)-trash")
        app.navigationBars.buttons.firstMatch.tap()

        let themeRow = app.tables.staticTexts["Theme"]
        XCTAssertTrue(themeRow.waitForExistence(timeout: 5))
        themeRow.tap()
        let themeAlert = app.alerts["Theme"]
        XCTAssertTrue(themeAlert.waitForExistence(timeout: 5))
        capture(app, named: "walk-\(appearance)-theme-picker")
        themeAlert.buttons["Cancel"].tap()
    }

    func testMainScreensScreenshotWalkDark() {
        walkMainScreens(appearance: "dark")
    }

    func testMainScreensScreenshotWalkLight() {
        walkMainScreens(appearance: "light")
    }
}
