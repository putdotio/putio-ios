import XCTest

final class PlaybackSmokeUITests: XCTestCase {
    func testMockedPlaybackResumeFlow() {
        let app = XCUIApplication()
        app.launchEnvironment["PUTIO_E2E_MOCK_API"] = "1"
        app.launchEnvironment["PUTIO_E2E_ACCESS_TOKEN"] = "e2e-token"
        app.launchEnvironment["PUTIO_E2E_RESET_STATE"] = "1"
        app.launch()

        let movie = app.tables["putio-files-table"].cells["putio-file-42"]
        XCTAssertTrue(movie.waitForExistence(timeout: 10))

        movie.tap()

        let resumeDialog = app.alerts["Where would you like to start?"]
        XCTAssertTrue(resumeDialog.waitForExistence(timeout: 5))
        XCTAssertTrue(resumeDialog.staticTexts["Last saved timestamp for this video is 00:02:05"].exists)

        resumeDialog.buttons["Continue watching"].tap()

        XCTAssertTrue(app.otherElements["putio-video-player"].waitForExistence(timeout: 5))
    }
}
