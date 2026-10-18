import XCTest

// Measures the app against the large-account fixture (PUTIO_E2E_FIXTURE=large).
// Skipped unless the runner has PUTIO_PERF=1, so the e2e suite only lists
// these. `mise run perf` sets it, builds with optimization, and prints the
// medians; numbers from a Debug -Onone build are not comparable.
final class PerformanceUITests: XCTestCase {
    private let environment = ProcessInfo.processInfo.environment

    // Ids and names from PutioE2ELargeFixture.Anchor, the first rows of the root.
    private let firstChainFolder = 100_000_001
    private let largeImage = 400_000_001
    private let largeImageName = "Perf fixture photo 8064x6048.jpg"
    private let document = 500_000_001
    private let documentName = "Perf fixture document 300 pages.pdf"
    private let foldersPushed = 5

    override func setUpWithError() throws {
        try XCTSkipUnless(environment["PUTIO_PERF"] == "1", "Run through `mise run perf`.")
        continueAfterFailure = false
    }

    func testLaunch() {
        let app = makeApp()
        launchToFiles(app)

        measure(metrics: [XCTApplicationLaunchMetric(waitUntilResponsive: true)], options: measureOptions()) {
            app.launch()
        }
    }

    func testLaunchToFiles() {
        let app = makeApp()
        launchToFiles(app)

        measure(metrics: [signpost("LaunchToFiles"), signpost("FetchUser"), signpost("FilesFetch"), signpost("FilesReload")], options: measureOptions()) {
            launchToFiles(app)
        }
    }

    func testScrollRootFolder() {
        let app = makeApp()
        launchToFiles(app)
        let table = app.tables["putio-files-table"]

        // On the simulator both scroll metrics report duration only; hitches
        // need a device.
        let metrics: [XCTMetric] = [
            XCTOSSignpostMetric.scrollingAndDecelerationMetric,
            XCTHitchMetric(application: app),
            XCTCPUMetric(application: app),
            XCTMemoryMetric(application: app)
        ]
        measure(metrics: metrics, options: measureOptions(.manuallyStop)) {
            for _ in 0..<6 {
                table.swipeUp(velocity: .fast)
            }
            stopMeasuring()
            scrollToTop(table, until: fileCell(app, firstChainFolder))
        }
    }

    func testSelectAll() {
        let app = makeApp()
        launchToFiles(app)
        app.buttons["More"].tap()
        let select = app.buttons["Select"]
        XCTAssertTrue(select.waitForExistence(timeout: 5))
        select.tap()

        let selectAll = app.navigationBars.buttons["Select All"]
        let deselectAll = app.navigationBars.buttons["Deselect All"]
        XCTAssertTrue(selectAll.waitForExistence(timeout: 5))

        measure(metrics: [signpost("SelectAll")], options: measureOptions(.manuallyStop)) {
            selectAll.tap()
            XCTAssertTrue(deselectAll.waitForExistence(timeout: 60))
            stopMeasuring()
            deselectAll.tap()
            XCTAssertTrue(selectAll.waitForExistence(timeout: 60))
        }
    }

    func testOpenLargeImage() {
        measureOpening(file: largeImage, titled: largeImageName, signpostName: "ImageOpen")
    }

    func testOpenLargePDF() {
        measureOpening(file: document, titled: documentName, signpostName: "PDFOpen")
    }

    // Each iteration is a fresh launch: push five folders, pop back to the
    // root, then background and foreground. Reports the FilesViewControllers
    // still alive and the /files/list requests the foreground fired; both
    // are 1 when nothing outlives its pop.
    func testFolderPushPopAndForeground() {
        let app = makeApp()
        let counts = CountMetric()
        let metrics: [XCTMetric] = [counts, XCTMemoryMetric(application: app)]

        measure(metrics: metrics, options: measureOptions(.manuallyStart, .manuallyStop)) {
            launchToFiles(app)

            startMeasuring()
            for level in 0..<foldersPushed {
                fileCell(app, firstChainFolder + level).tap()
                XCTAssertTrue(fileCell(app, firstChainFolder + level + 1).waitForExistence(timeout: 30))
            }
            for level in (0..<foldersPushed).reversed() {
                app.navigationBars.buttons.element(boundBy: 0).tap()
                XCTAssertTrue(fileCell(app, firstChainFolder + level).waitForExistence(timeout: 30))
            }

            let afterPop = probe(app)
            XCUIDevice.shared.press(.home)
            app.activate()
            let afterForeground = waitForRequestsToSettle(app, after: afterPop.filesListRequests)

            counts.record([
                Count(
                    identifier: "io.put.perf.live-files-controllers",
                    displayName: "Live FilesViewControllers after pop",
                    value: afterPop.liveFilesControllers
                ),
                Count(
                    identifier: "io.put.perf.foreground-files-list",
                    displayName: "files/list requests per foreground",
                    value: afterForeground.filesListRequests - afterPop.filesListRequests
                )
            ])
            stopMeasuring()
        }
    }

    private func makeApp() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment = [
            "PUTIO_E2E_MOCK_API": "1",
            "PUTIO_E2E_ACCESS_TOKEN": "e2e-token",
            "PUTIO_E2E_RESET_STATE": "1",
            "PUTIO_E2E_FIXTURE": "large",
            "PUTIO_E2E_LATENCY_MS": environment["PUTIO_PERF_LATENCY_MS"] ?? "0"
        ]
        return app
    }

    private func measureOptions(_ invocation: XCTMeasureOptions.InvocationOptions...) -> XCTMeasureOptions {
        let options = XCTMeasureOptions()
        options.iterationCount = environment["PUTIO_PERF_ITERATIONS"].flatMap(Int.init) ?? 10
        options.invocationOptions = XCTMeasureOptions.InvocationOptions(invocation)
        return options
    }

    private func signpost(_ name: String) -> XCTOSSignpostMetric {
        XCTOSSignpostMetric(subsystem: "io.put.perf", category: "PointsOfInterest", name: name)
    }

    private func fileCell(_ app: XCUIApplication, _ id: Int) -> XCUIElement {
        app.cells["putio-file-\(id)"]
    }

    private func launchToFiles(_ app: XCUIApplication) {
        app.launch()
        XCTAssertTrue(fileCell(app, firstChainFolder).waitForExistence(timeout: 60), "large fixture root should list")
    }

    // The first open generates the fixture's media and caches it, so it runs
    // before measuring.
    private func measureOpening(file id: Int, titled title: String, signpostName: String) {
        let app = makeApp()
        launchToFiles(app)
        openPreview(app, file: id, titled: title)
        goBack(app)

        measure(metrics: [signpost(signpostName), XCTMemoryMetric(application: app)], options: measureOptions(.manuallyStop)) {
            openPreview(app, file: id, titled: title)
            stopMeasuring()
            goBack(app)
        }
    }

    private func openPreview(_ app: XCUIApplication, file id: Int, titled title: String) {
        fileCell(app, id).tap()
        XCTAssertTrue(app.navigationBars[title].waitForExistence(timeout: 10))
        // The preview hides this label once the file is on screen.
        XCTAssertTrue(app.staticTexts["Fetching File"].waitForNonExistence(timeout: 60))
    }

    private func goBack(_ app: XCUIApplication) {
        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(fileCell(app, firstChainFolder).waitForExistence(timeout: 10))
    }

    private func scrollToTop(_ table: XCUIElement, until cell: XCUIElement) {
        var swipes = 0
        while !(cell.exists && cell.isHittable), swipes < 30 {
            table.swipeDown(velocity: .fast)
            swipes += 1
        }
    }

    private struct ProbeCounts {
        let filesListRequests: Int
        let liveFilesControllers: Int
    }

    // PutioE2EPerfProbe: "files-list-requests=N live-files-controllers=M".
    private func probe(_ app: XCUIApplication) -> ProbeCounts {
        let element = app.otherElements["putio-perf-probe"]
        XCTAssertTrue(element.waitForExistence(timeout: 5), "large fixture installs the perf probe")
        let fields = Dictionary(
            (element.value as? String ?? "").split(separator: " ").compactMap { field -> (String, Int)? in
                let parts = field.split(separator: "=")
                guard parts.count == 2, let value = Int(parts[1]) else { return nil }
                return (String(parts[0]), value)
            },
            uniquingKeysWith: { _, last in last }
        )
        return ProbeCounts(
            filesListRequests: fields["files-list-requests"] ?? -1,
            liveFilesControllers: fields["live-files-controllers"] ?? -1
        )
    }

    // Foreground refreshes start as the app activates; done once the count
    // has moved and then held still across two reads.
    private func waitForRequestsToSettle(_ app: XCUIApplication, after baseline: Int) -> ProbeCounts {
        var last = probe(app)
        for _ in 0..<20 {
            Thread.sleep(forTimeInterval: 0.5)
            let current = probe(app)
            if current.filesListRequests > baseline, current.filesListRequests == last.filesListRequests {
                return current
            }
            last = current
        }
        XCTFail("files/list requests did not settle after foregrounding")
        return last
    }
}

private struct Count {
    let identifier: String
    let displayName: String
    let value: Int
}

/// Turns counts a measured block records into XCTest measurements, so they
/// land in the result bundle beside the built-in metrics. XCTest copies a
/// metric for every iteration; the copies share one box.
private final class CountMetric: NSObject, XCTMetric {
    private final class Box {
        var counts: [Count] = []
    }

    private let box: Box

    override convenience init() {
        self.init(box: Box())
    }

    private init(box: Box) {
        self.box = box
        super.init()
    }

    func record(_ counts: [Count]) {
        box.counts = counts
    }

    func copy(with zone: NSZone? = nil) -> Any {
        CountMetric(box: box)
    }

    func reportMeasurements(
        from startTime: XCTPerformanceMeasurementTimestamp,
        to endTime: XCTPerformanceMeasurementTimestamp
    ) throws -> [XCTPerformanceMeasurement] {
        box.counts.map {
            XCTPerformanceMeasurement(
                identifier: $0.identifier,
                displayName: $0.displayName,
                doubleValue: Double($0.value),
                // A bare count: the display name says what is counted.
                unitSymbol: ""
            )
        }
    }
}
