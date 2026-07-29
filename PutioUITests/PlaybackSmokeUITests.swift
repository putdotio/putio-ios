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

        app.tabItem("Account").tap()

        XCTAssertTrue(app.navigationBars["Account"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Default sort option for files"].exists)
        XCTAssertTrue(app.staticTexts["Choose your proxy"].exists)
        XCTAssertTrue(app.staticTexts["Two-factor authentication"].exists)

        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "Account Phosphor icons"
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }

    func testDownloadsMultiSelectDeletesCompletedItemsAndLeavesActiveDownload() {
        let app = launchFixtureApp()
        guard app.waitForSignedInTabBar() else { return }

        app.tabItem("Downloads").tap()
        let downloadsTable = app.tables["putio-downloads-table"]
        let firstDownload = downloadsTable.cells.containing(
            .staticText,
            identifier: "Big Buck Bunny.mp4"
        ).element
        let secondDownload = downloadsTable.cells.containing(
            .staticText,
            identifier: "Sintel.mp4"
        ).element
        let activeDownload = downloadsTable.cells.containing(
            .staticText,
            identifier: "Tears of Steel.mp4"
        ).element
        XCTAssertTrue(firstDownload.waitForExistence(timeout: 10))
        XCTAssertTrue(secondDownload.exists)
        XCTAssertTrue(activeDownload.exists)

        app.buttons["Select completed downloads"].tap()
        XCTAssertTrue(app.navigationBars["Select Items"].waitForExistence(timeout: 5))

        activeDownload.tap()
        XCTAssertTrue(app.navigationBars["Select Items"].exists, "active downloads must not become selected")

        firstDownload.tap()
        secondDownload.tap()
        XCTAssertTrue(app.navigationBars["2 Items"].waitForExistence(timeout: 5))

        firstDownload.tap()
        XCTAssertTrue(app.navigationBars["1 Item"].waitForExistence(timeout: 5))
        firstDownload.tap()
        XCTAssertTrue(app.navigationBars["2 Items"].waitForExistence(timeout: 5))

        app.buttons["Delete 2 selected downloads"].tap()
        let confirmation = app.sheets["Delete 2 Downloads?"]
        XCTAssertTrue(confirmation.waitForExistence(timeout: 5))
        confirmation.buttons["Delete"].tap()

        XCTAssertTrue(firstDownload.waitForNonExistence(timeout: 10))
        XCTAssertTrue(secondDownload.waitForNonExistence(timeout: 10))
        XCTAssertTrue(activeDownload.exists)
        XCTAssertTrue(app.navigationBars["Downloads"].exists)
    }
}
