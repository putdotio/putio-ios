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

    override func setUpWithError() throws {
        try XCTSkipUnless(environment["PUTIO_PERF"] == "1", "Run through `mise run perf`.")
        continueAfterFailure = false
    }

    func testLaunchToFiles() {
        let app = makeApp()
        launchToFiles(app)

        measure(metrics: [signpost("LaunchToFiles"), signpost("FetchUser"), signpost("FilesFetch"), signpost("FilesReload")], options: measureOptions()) {
            launchToFiles(app)
        }
    }

    func testOpenLargeImage() {
        measureOpening(file: largeImage, titled: largeImageName, signpostName: "ImageOpen")
    }

    func testOpenLargePDF() {
        measureOpening(file: document, titled: documentName, signpostName: "PDFOpen")
    }

    private func makeApp() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment = [
            "PUTIO_E2E_MOCK_API": "1",
            "PUTIO_E2E_ANIMATIONS": "1",
            "PUTIO_E2E_ACCESS_TOKEN": "e2e-token",
            "PUTIO_E2E_RESET_STATE": "1",
            "PUTIO_E2E_FIXTURE": "large",
            "PUTIO_E2E_LATENCY_MS": environment["PUTIO_PERF_LATENCY_MS"] ?? "0"
        ]
        return app
    }

    private func measureOptions(_ invocation: XCTMeasureOptions.InvocationOptions...) -> XCTMeasureOptions {
        let options = XCTMeasureOptions()
        options.iterationCount = environment["PUTIO_PERF_ITERATIONS"].flatMap(Int.init) ?? 3
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
}
