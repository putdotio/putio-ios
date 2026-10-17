import XCTest

final class InactiveAccountUITests: XCTestCase {
    private let title = "Your account has been deactivated 😢"

    private func launchInactiveAccountApp() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["PUTIO_E2E_MOCK_API"] = "1"
        app.launchEnvironment["PUTIO_E2E_ACCESS_TOKEN"] = "e2e-token"
        app.launchEnvironment["PUTIO_E2E_RESET_STATE"] = "1"
        app.launchEnvironment["PUTIO_E2E_ACCOUNT"] = "inactive"
        app.launch()
        return app
    }

    func testNoticeStaysOnScreenAndReplacesOnlinePlayback() {
        let app = launchInactiveAccountApp()
        guard app.waitForSignedInTabBar() else { return }

        let notice = app.staticTexts["putio-account-notice"]
        XCTAssertTrue(notice.waitForExistence(timeout: 5))
        XCTAssertEqual(
            notice.label,
            "\(title), Your files are still here, but they are scheduled to be deleted in 14 days. Renew your plan at put.io to keep your files."
        )
        attachScreenshot(of: app, named: "Inactive account notice")

        let movie = app.tables["putio-files-table"].cells["putio-file-42"]
        XCTAssertTrue(movie.waitForExistence(timeout: 10), "browsing stays available")
        movie.tap()

        let alert = app.alerts[title]
        XCTAssertTrue(alert.waitForExistence(timeout: 5))
        XCTAssertFalse(app.otherElements["putio-video-player"].exists)
        attachScreenshot(of: app, named: "Inactive account playback alert")

        alert.buttons["Close"].tap()
        XCTAssertTrue(alert.waitForNonExistence(timeout: 5))
        XCTAssertFalse(app.otherElements["putio-video-player"].exists)

        app.tabItem("Downloads").tap()
        XCTAssertTrue(notice.exists, "the notice follows every signed-in tab")
        let download = app.tables["putio-downloads-table"].cells["putio-download-42"]
        XCTAssertTrue(download.waitForExistence(timeout: 10))
        download.tap()

        XCTAssertTrue(
            app.otherElements["putio-video-player"].waitForExistence(timeout: 5),
            "a downloaded file still plays"
        )
        XCTAssertFalse(app.alerts[title].exists)
    }

    private func attachScreenshot(of app: XCUIApplication, named name: String) {
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = name
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }
}
