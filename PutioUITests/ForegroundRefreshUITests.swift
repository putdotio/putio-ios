import XCTest

final class ForegroundRefreshUITests: XCTestCase {
    private let foldersPushed = 3

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testForegroundAfterFolderNavigationRefetchesTheFilesListOnce() {
        let app = XCUIApplication()
        app.launchEnvironment = [
            "PUTIO_E2E_MOCK_API": "1",
            "PUTIO_E2E_ACCESS_TOKEN": "e2e-token",
            "PUTIO_E2E_RESET_STATE": "1"
        ]
        app.launch()

        guard app.waitForSignedInTabBar() else { return }
        let downloadsFolder = app.cells["putio-file-101"]
        XCTAssertTrue(downloadsFolder.waitForExistence(timeout: 10))
        var requests = settledFilesListRequests(app)

        for _ in 0..<foldersPushed {
            downloadsFolder.tap()
            let afterPush = settledFilesListRequests(app)
            XCTAssertEqual(afterPush - requests, 1, "each pushed folder fetches its listing once")
            requests = afterPush
            XCTAssertTrue(downloadsFolder.waitForExistence(timeout: 10))
        }
        for _ in 0..<foldersPushed {
            app.navigationBars.buttons.element(boundBy: 0).tap()
            XCTAssertTrue(downloadsFolder.waitForExistence(timeout: 10))
        }
        let beforeBackground = settledFilesListRequests(app)

        XCUIDevice.shared.press(.home)
        XCTAssertTrue(app.wait(for: .runningBackground, timeout: 10))
        app.activate()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 10))

        XCTAssertEqual(settledFilesListRequests(app) - beforeBackground, 1, "only the visible folder refetches on foreground")
    }

    private func filesListRequests(_ app: XCUIApplication) -> Int {
        let probe = app.otherElements["putio-perf-probe"]
        XCTAssertTrue(probe.waitForExistence(timeout: 5), "the mocked API installs the request probe")
        let value = (probe.value as? String ?? "").replacingOccurrences(of: "files-list-requests=", with: "")
        return Int(value) ?? -1
    }

    private func settledFilesListRequests(_ app: XCUIApplication) -> Int {
        var last = filesListRequests(app)
        var unchangedReads = 0
        var reads = 0
        while unchangedReads < 4, reads < 40 {
            Thread.sleep(forTimeInterval: 0.5)
            let current = filesListRequests(app)
            unchangedReads = current == last ? unchangedReads + 1 : 0
            last = current
            reads += 1
        }
        return last
    }
}
