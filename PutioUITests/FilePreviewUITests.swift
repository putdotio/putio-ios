import XCTest

final class FilePreviewUITests: XCTestCase {
    private let largeImage = 400_000_001
    private let document = 500_000_001
    private let deletedMessage = "The original version of this file has been deleted from your put.io account."

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testMissingPDFSaysTheFileWasDeleted() {
        let app = launch(missingRoutes: download(document))
        assertPreview(app, of: document, failsWith: deletedMessage)
    }

    func testMissingImageSaysTheFileWasDeleted() {
        let app = launch(missingRoutes: download(largeImage))
        assertPreview(app, of: largeImage, failsWith: deletedMessage)
    }

    func testPDFServerErrorSaysTheFetchFailed() {
        let app = launch(failRoutes: download(document))
        assertPreview(app, of: document, failsWith: "An error occurred while fetching the PDF")
    }

    func testImageServerErrorSaysTheFetchFailed() {
        let app = launch(failRoutes: download(largeImage))
        assertPreview(app, of: largeImage, failsWith: "An error occurred while fetching the image")
    }

    private func launch(failRoutes: String? = nil, missingRoutes: String? = nil) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment = [
            "PUTIO_E2E_MOCK_API": "1",
            "PUTIO_E2E_ACCESS_TOKEN": "e2e-token",
            "PUTIO_E2E_RESET_STATE": "1",
            "PUTIO_E2E_FIXTURE": "large"
        ]
        app.launchEnvironment["PUTIO_E2E_FAIL_ROUTES"] = failRoutes
        app.launchEnvironment["PUTIO_E2E_MISSING_ROUTES"] = missingRoutes
        app.launch()
        return app
    }

    private func download(_ id: Int) -> String {
        "GET /v2/files/\(id)/download"
    }

    private func assertPreview(
        _ app: XCUIApplication,
        of id: Int,
        failsWith message: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard app.waitForSignedInTabBar(file: file, line: line) else { return }
        let cell = app.cells["putio-file-\(id)"]
        XCTAssertTrue(cell.waitForExistence(timeout: 60), "large fixture root should list", file: file, line: line)
        cell.tap()

        let alert = app.alerts["Oops!"]
        XCTAssertTrue(alert.waitForExistence(timeout: 30), "preview should report the failed download", file: file, line: line)
        XCTAssertTrue(alert.staticTexts[message].exists, "alert should say: \(message)", file: file, line: line)

        alert.buttons["Go Back"].tap()
        XCTAssertTrue(cell.waitForExistence(timeout: 10), "Go Back should return to the list", file: file, line: line)
    }
}
