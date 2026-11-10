import XCTest

final class FilePreviewUITests: XCTestCase {
    private let largeImage = 400_000_001

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testLargeImageOpens() {
        let app = launch(opening: largeImage)

        XCTAssertTrue(app.navigationBars["Perf fixture photo 8064x6048.jpg"].appears(within: 60), "the large fixture root should list and open the file")
        assertPreviewShows(in: app)
    }

    private func launch(opening id: Int) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment = [
            "PUTIO_E2E_MOCK_API": "1",
            "PUTIO_E2E_ACCESS_TOKEN": "e2e-token",
            "PUTIO_E2E_RESET_STATE": "1",
            "PUTIO_E2E_FIXTURE": "large",
            "PUTIO_E2E_OPEN_FILE": String(id)
        ]
        app.launch()
        return app
    }

    private func assertPreviewShows(in app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(app.staticTexts["Fetching File"].disappears(within: 60), "the loader should hide", file: file, line: line)
        XCTAssertTrue(app.descendants(matching: .any)["putio-preview-content"].appears(within: 5), "the file should show", file: file, line: line)
        XCTAssertFalse(app.alerts.firstMatch.exists, "the preview should not report an error", file: file, line: line)
    }
}
