import XCTest

final class FilePreviewUITests: XCTestCase {
    private let largeImage = 400_000_001
    private let document = 500_000_001

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testLargeImageOpens() {
        assertPreviewOpens(file: largeImage, titled: "Perf fixture photo 8064x6048.jpg")
    }

    func testLargePDFOpens() {
        assertPreviewOpens(file: document, titled: "Perf fixture document 300 pages.pdf")
    }

    private func assertPreviewOpens(
        file id: Int,
        titled title: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let app = XCUIApplication()
        app.launchEnvironment = [
            "PUTIO_E2E_MOCK_API": "1",
            "PUTIO_E2E_ACCESS_TOKEN": "e2e-token",
            "PUTIO_E2E_RESET_STATE": "1",
            "PUTIO_E2E_FIXTURE": "large",
            "PUTIO_E2E_OPEN_FILE": String(id)
        ]
        app.launch()

        XCTAssertTrue(app.navigationBars[title].appears(within: 60), "the large fixture root should list and open the file", file: file, line: line)
        XCTAssertTrue(app.staticTexts["Fetching File"].disappears(within: 60), "the loader should hide", file: file, line: line)
        XCTAssertTrue(app.descendants(matching: .any)["putio-preview-content"].appears(within: 5), "the file should show", file: file, line: line)
        XCTAssertFalse(app.alerts.firstMatch.exists, "the preview should not report an error", file: file, line: line)
    }
}
