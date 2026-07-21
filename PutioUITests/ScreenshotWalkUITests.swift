import XCTest

// Captures labeled screenshots of every main screen into the result bundle.
// The grids extracted from build/e2e-simulator.xcresult are the review aids
// for theme work; Phase 2 of the color migration runs this in both
// appearance modes.
final class ScreenshotWalkUITests: XCTestCase {
    private func launchFixtureApp() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["PUTIO_E2E_MOCK_API"] = "1"
        app.launchEnvironment["PUTIO_E2E_ACCESS_TOKEN"] = "e2e-token"
        app.launchEnvironment["PUTIO_E2E_RESET_STATE"] = "1"
        app.launch()
        return app
    }

    private func capture(_ app: XCUIApplication, named name: String) {
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = name
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }

    func testMainScreensScreenshotWalk() {
        let app = launchFixtureApp()

        XCTAssertTrue(app.tables["putio-files-table"].cells["putio-file-42"].waitForExistence(timeout: 10))
        capture(app, named: "walk-files")

        for tab in ["Downloads", "History", "Account"] {
            let button = app.tabBars.buttons[tab]
            XCTAssertTrue(button.waitForExistence(timeout: 5), "\(tab) tab should exist")
            button.tap()
            // Let the screen settle before capturing.
            _ = app.navigationBars.firstMatch.waitForExistence(timeout: 5)
            capture(app, named: "walk-\(tab.lowercased())")
        }
    }
}
