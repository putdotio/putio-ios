import XCTest

final class PlaybackSmokeUITests: XCTestCase {
    private func launchFixtureApp() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["PUTIO_E2E_MOCK_API"] = "1"
        app.launchEnvironment["PUTIO_E2E_ACCESS_TOKEN"] = "e2e-token"
        app.launchEnvironment["PUTIO_E2E_RESET_STATE"] = "1"
        app.launch()
        return app
    }

    func testMockedPlaybackResumeFlow() {
        let app = launchFixtureApp()

        guard app.waitForSignedInTabBar() else { return }
        let movie = app.tables["putio-files-table"].cells["putio-file-42"]
        XCTAssertTrue(movie.waitForExistence(timeout: 10))

        movie.tap()

        let resumeDialog = app.alerts["Where would you like to start?"]
        XCTAssertTrue(resumeDialog.waitForExistence(timeout: 5))
        XCTAssertTrue(resumeDialog.staticTexts["Last saved timestamp for this video is 00:02:05"].exists)

        resumeDialog.buttons["Continue watching"].tap()

        let player = app.otherElements["putio-video-player"]
        XCTAssertTrue(player.waitForExistence(timeout: 5))

        let playerReady = NSPredicate(format: "value == %@", "ready")
        expectation(for: playerReady, evaluatedWith: player)
        waitForExpectations(timeout: 10)
    }

    func testFilesScreenLoadsWithFixtureData() {
        let app = launchFixtureApp()
        guard app.waitForSignedInTabBar() else { return }
        let movie = app.tables["putio-files-table"].cells["putio-file-42"]
        XCTAssertTrue(movie.waitForExistence(timeout: 10))

        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "Files Phosphor icons"
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }

    func testAccountScreenLoadsWithFixtureData() {
        let app = launchFixtureApp()
        guard app.waitForSignedInTabBar() else { return }

        app.tabBars.buttons["Account"].tap()

        XCTAssertTrue(app.navigationBars["Account"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Default sort option for files"].exists)
        XCTAssertTrue(app.staticTexts["Choose your proxy"].exists)
        XCTAssertTrue(app.staticTexts["Two-factor authentication"].exists)

        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "Account Phosphor icons"
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }
}
