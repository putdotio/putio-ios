import XCTest

final class VideoConversionUITests: XCTestCase {
    func testCompletedConversionContinuesToPlayback() {
        let app = XCUIApplication()
        app.launchEnvironment["PUTIO_E2E_MOCK_API"] = "1"
        app.launchEnvironment["PUTIO_E2E_ACCESS_TOKEN"] = "e2e-token"
        app.launchEnvironment["PUTIO_E2E_RESET_STATE"] = "1"
        app.launchEnvironment["PUTIO_E2E_VIDEO_NEEDS_CONVERSION"] = "1"
        app.launch()

        guard app.waitForSignedInTabBar() else { return }
        let movie = app.tables["putio-files-table"].cells["putio-file-42"]
        XCTAssertTrue(movie.appears(within: 10))
        movie.tap()

        XCTAssertTrue(app.alerts["Where would you like to start?"].appears(within: 10))
    }
}
