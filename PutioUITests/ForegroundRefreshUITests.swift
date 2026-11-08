import XCTest

final class ForegroundRefreshUITests: XCTestCase {
    private let foldersPushed = 3
    private let stabilityWindow: TimeInterval = 1

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
        XCTAssertTrue(downloadsFolder.appears(within: 10))
        let probe = app.otherElements["putio-perf-probe"]
        XCTAssertTrue(probe.appears(within: 5), "the mocked API installs the request probe")
        var requests = stableRequestCount(probe)

        for _ in 0..<foldersPushed {
            downloadsFolder.tap()
            assertRequests(probe, reach: requests + 1, "each pushed folder fetches its listing once")
            requests += 1
            XCTAssertTrue(downloadsFolder.appears(within: 10))
        }
        for _ in 0..<foldersPushed {
            app.navigationBars.buttons.element(boundBy: 0).tap()
            XCTAssertTrue(downloadsFolder.appears(within: 10))
        }
        let beforeBackground = stableRequestCount(probe)

        XCUIDevice.shared.press(.home)
        XCTAssertTrue(app.wait(for: .runningBackground, timeout: 10))
        app.activate()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 10))

        assertRequests(probe, reach: beforeBackground + 1, "only the visible folder refetches on foreground")
    }

    private func requestCount(_ probe: XCUIElement) -> Int {
        Self.requestCount(of: probe.value)
    }

    private static func requestCount(of value: Any?) -> Int {
        let digits = (value as? String ?? "").replacingOccurrences(of: "files-list-requests=", with: "")
        return Int(digits) ?? -1
    }

    private func countChanges(_ probe: XCUIElement, from count: Int, within timeout: TimeInterval) -> Bool {
        let changed = NSPredicate { element, _ in
            Self.requestCount(of: (element as? XCUIElement)?.value) != count
        }
        return probe.reaches(changed, within: timeout)
    }

    private func stableRequestCount(_ probe: XCUIElement) -> Int {
        var count = requestCount(probe)
        var windows = 0
        while windows < 10, countChanges(probe, from: count, within: stabilityWindow) {
            count = requestCount(probe)
            windows += 1
        }
        return count
    }

    private func assertRequests(
        _ probe: XCUIElement,
        reach expected: Int,
        _ message: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let reached = NSPredicate { element, _ in
            Self.requestCount(of: (element as? XCUIElement)?.value) >= expected
        }
        XCTAssertTrue(probe.reaches(reached, within: 10), "\(message): never reached \(expected) requests", file: file, line: line)
        XCTAssertEqual(requestCount(probe), expected, message, file: file, line: line)
        XCTAssertFalse(
            countChanges(probe, from: expected, within: stabilityWindow),
            "\(message): got \(requestCount(probe)) requests, expected \(expected)",
            file: file,
            line: line
        )
    }
}
