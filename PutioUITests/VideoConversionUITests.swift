import XCTest

final class VideoConversionUITests: XCTestCase {
    private func openConvertingVideo(
        failRoutes: String? = nil,
        mp4Status: String? = nil,
        latencyMilliseconds: Int? = nil
    ) -> XCUIApplication? {
        let app = XCUIApplication()
        app.launchEnvironment["PUTIO_E2E_MOCK_API"] = "1"
        app.launchEnvironment["PUTIO_E2E_ACCESS_TOKEN"] = "e2e-token"
        app.launchEnvironment["PUTIO_E2E_RESET_STATE"] = "1"
        app.launchEnvironment["PUTIO_E2E_VIDEO_NEEDS_CONVERSION"] = "1"
        app.launchEnvironment["PUTIO_E2E_FAIL_ROUTES"] = failRoutes
        app.launchEnvironment["PUTIO_E2E_MP4_STATUS"] = mp4Status
        app.launchEnvironment["PUTIO_E2E_LATENCY_MS"] = latencyMilliseconds.map(String.init)
        app.launch()

        guard app.waitForSignedInTabBar() else { return nil }
        let movie = app.tables["putio-files-table"].cells["putio-file-42"]
        XCTAssertTrue(movie.waitForExistence(timeout: 10))
        movie.tap()
        return app
    }

    private func closeButton(_ app: XCUIApplication) -> XCUIElement {
        app.navigationBars.buttons.matching(NSPredicate(format: "label IN %@", ["Stop", "Close"])).firstMatch
    }

    private func statusText(_ app: XCUIApplication, containing text: String) -> XCUIElement {
        app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", text)).firstMatch
    }

    func testFailedConversionStartOffersRetryAndClose() {
        guard let app = openConvertingVideo(failRoutes: "POST /v2/files/42/mp4") else { return }

        XCTAssertTrue(statusText(app, containing: "Something went wrong").waitForExistence(timeout: 10))
        XCTAssertTrue(app.navigationBars.buttons["Retry"].exists)

        closeButton(app).tap()
        XCTAssertTrue(app.navigationBars.buttons["Retry"].waitForNonExistence(timeout: 5))
    }

    func testTerminalConversionErrorOffersRetry() {
        guard let app = openConvertingVideo(mp4Status: "ERROR") else { return }

        XCTAssertTrue(statusText(app, containing: "This video couldn't be converted").waitForExistence(timeout: 10))
        XCTAssertTrue(app.navigationBars.buttons["Retry"].exists)
    }

    func testCompletedConversionContinuesToPlayback() {
        guard let app = openConvertingVideo() else { return }

        XCTAssertTrue(app.alerts["Where would you like to start?"].waitForExistence(timeout: 10))
    }

    func testFailedStatusFetchOffersRetryAfterBoundedRetries() {
        guard let app = openConvertingVideo(failRoutes: "GET /v2/files/42/mp4") else { return }

        XCTAssertTrue(statusText(app, containing: "Something went wrong").waitForExistence(timeout: 30))
        XCTAssertTrue(app.navigationBars.buttons["Retry"].exists)
    }

    func testFailedConvertedFileFetchOffersRetry() {
        guard let app = openConvertingVideo(failRoutes: "GET /v2/files/42") else { return }

        XCTAssertTrue(statusText(app, containing: "Something went wrong").waitForExistence(timeout: 10))
        XCTAssertTrue(app.navigationBars.buttons["Retry"].exists)
        XCTAssertFalse(app.alerts["Where would you like to start?"].exists)
    }

    func testClosingBeforeTheStartResponseNeverContinuesToPlayback() {
        guard let app = openConvertingVideo(latencyMilliseconds: 1500) else { return }

        let close = closeButton(app)
        XCTAssertTrue(close.waitForExistence(timeout: 5))
        close.tap()

        XCTAssertFalse(app.alerts["Where would you like to start?"].waitForExistence(timeout: 8))
    }
}
