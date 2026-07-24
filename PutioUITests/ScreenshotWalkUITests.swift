import SnapshotTesting
import XCTest

// Captures labeled screenshots of every main screen into the result bundle
// and asserts them against committed baselines in PutioUITests/__Snapshots__/.
// The app is dark-only, so the walk captures a single appearance. Re-record
// intentionally with `make screenshots-record`, then review the image diff in
// the PR. The ephemeral simulator pins the status bar so pixels are
// deterministic.
final class ScreenshotWalkUITests: XCTestCase {
    private var isRecording: Bool {
        ProcessInfo.processInfo.environment["PUTIO_RECORD_SNAPSHOTS"] == "1"
    }
    private func launchFixtureApp(loggedIn: Bool = true, failRoutes: String? = nil) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["PUTIO_E2E_MOCK_API"] = "1"
        if loggedIn {
            app.launchEnvironment["PUTIO_E2E_ACCESS_TOKEN"] = "e2e-token"
        }
        app.launchEnvironment["PUTIO_E2E_RESET_STATE"] = "1"
        if let failRoutes {
            app.launchEnvironment["PUTIO_E2E_FAIL_ROUTES"] = failRoutes
        }
        app.launch()
        return app
    }

    // Presentation animations (~0.35s) race screenshot capture; give modals
    // and pushes a beat to settle so baselines stay deterministic.
    private func settle() {
        Thread.sleep(forTimeInterval: 0.8)
    }

    private func capture(_ app: XCUIApplication, named name: String) {
        let screenshot = app.screenshot()

        // No manual XCTAttachment: SnapshotTesting already attaches the
        // recorded image and the failure diff when an assertion fails, and
        // result bundles are only uploaded on failure.

        // precision tolerates a small share of outlier pixels; perceptual
        // precision absorbs antialiasing drift across Xcode/simulator builds.
        assertSnapshot(
            of: screenshot.image,
            as: .image(precision: 0.995, perceptualPrecision: 0.98),
            named: String(name.dropFirst("walk-".count)),
            record: isRecording,
            testName: "walk"
        )
    }

    private func walkMainScreens() {
        let app = launchFixtureApp()

        XCTAssertTrue(app.tables["putio-files-table"].cells["putio-file-42"].waitForExistence(timeout: 10))
        capture(app, named: "walk-dark-files")

        // Wait for tab-specific content so captures never race the fixture
        // load; a generic nav-bar wait is satisfiable before rendering ends.
        let readiness: [String: XCUIElement] = [
            "Downloads": app.staticTexts["No downloads"],
            "History": app.tables["putio-history-table"].staticTexts["E2E Upload.mp4"],
            "Account": app.tables.staticTexts["Manage your trash"]
        ]

        for tab in ["Downloads", "History", "Account"] {
            let button = app.tabBars.buttons[tab]
            XCTAssertTrue(button.waitForExistence(timeout: 5), "\(tab) tab should exist")
            button.tap()
            XCTAssertTrue(readiness[tab]!.waitForExistence(timeout: 10), "\(tab) content should render")
            capture(app, named: "walk-dark-\(tab.lowercased())")
        }

        let trashRow = app.tables.staticTexts["Manage your trash"]
        XCTAssertTrue(trashRow.waitForExistence(timeout: 5))
        trashRow.tap()
        XCTAssertTrue(app.staticTexts["E2E Trashed Movie.mp4"].waitForExistence(timeout: 5))
        capture(app, named: "walk-dark-trash")
    }

    private func walkSecondaryScreens() {
        let app = launchFixtureApp()

        // Audio player, reached from the files list.
        let song = app.tables["putio-files-table"].cells["putio-file-43"]
        XCTAssertTrue(song.waitForExistence(timeout: 10))
        song.tap()
        XCTAssertTrue(app.staticTexts["E2E Song.mp3"].waitForExistence(timeout: 10))
        // The player loads a local ten-minute silent WAV (see
        // PutioE2EPlaybackAsset), so it reaches a real ready state
        // hermetically: the duration label proves the asset loaded and the
        // next-item lookup settles on its deterministic empty result. Should
        // playback advance before capture, the elapsed glyphs and the slider
        // thumb's sub-percent crawl sit far inside the snapshot tolerance.
        XCTAssertTrue(
            app.staticTexts["10:00"].waitForExistence(timeout: 15),
            "duration label should show the loaded fixture length"
        )
        XCTAssertTrue(
            app.staticTexts["We couldn't find anything to play"].waitForExistence(timeout: 10),
            "next-item lookup should settle on the empty fixture result"
        )
        settle()
        capture(app, named: "walk-dark-audio-player")
        let closeButton = app.navigationBars.buttons["Stop"]
        XCTAssertTrue(closeButton.waitForExistence(timeout: 5), "audio player close button should exist")
        closeButton.tap()
        settle()

        // Move-files sheet via selection mode (Select lives in the More menu).
        XCTAssertTrue(app.tables["putio-files-table"].cells["putio-file-42"].waitForExistence(timeout: 5))
        app.buttons["More"].tap()
        let selectAction = app.buttons["Select"]
        XCTAssertTrue(selectAction.waitForExistence(timeout: 5), "Select should be in the More menu")
        selectAction.tap()
        app.tables["putio-files-table"].cells["putio-file-42"].tap()
        app.buttons["Move"].tap()
        XCTAssertTrue(app.navigationBars["Your Files"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["E2E Movie.mp4"].firstMatch.waitForExistence(timeout: 10), "move sheet content should render")
        settle()
        capture(app, named: "walk-dark-move-files")
        app.buttons["Cancel"].firstMatch.tap()
        settle()

        // Downloads tutorial sheet.
        app.tabBars.buttons["Downloads"].tap()
        let tutorialButton = app.buttons["Downloads tutorial"]
        XCTAssertTrue(tutorialButton.waitForExistence(timeout: 5))
        tutorialButton.tap()
        XCTAssertTrue(app.staticTexts["Downloads: Mini Tutorial"].waitForExistence(timeout: 5))
        settle()
        capture(app, named: "walk-dark-downloads-tutorial")
        app.swipeDown(velocity: .fast)
        XCTAssertTrue(app.staticTexts["Downloads: Mini Tutorial"].waitForNonExistence(timeout: 5), "tutorial sheet should dismiss")

        // Routes and sessions from the Account screen.
        app.tabBars.buttons["Account"].tap()
        let routesRow = app.tables.staticTexts["Choose your proxy"]
        XCTAssertTrue(routesRow.waitForExistence(timeout: 5))
        routesRow.tap()
        XCTAssertTrue(app.staticTexts["Amsterdam"].waitForExistence(timeout: 10))
        settle()
        capture(app, named: "walk-dark-routes")
        app.navigationBars.buttons["Account"].tap()

        let sessionsRow = app.tables.staticTexts["Where you are logged in"]
        XCTAssertTrue(sessionsRow.waitForExistence(timeout: 5))
        sessionsRow.tap()
        XCTAssertTrue(app.staticTexts["E2E Web App"].waitForExistence(timeout: 10))
        settle()
        capture(app, named: "walk-dark-sessions")
    }

    private func walkUnhappyPaths() {
        let loginApp = launchFixtureApp(loggedIn: false)
        XCTAssertTrue(loginApp.buttons["Log in"].waitForExistence(timeout: 10))

        // The login screen auto-starts web auth, which pops a system consent
        // alert at a nondeterministic moment; dismiss it before capturing.
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let consentAlert = springboard.alerts.firstMatch
        if consentAlert.waitForExistence(timeout: 10) {
            consentAlert.buttons["Cancel"].tap()
            XCTAssertTrue(consentAlert.waitForNonExistence(timeout: 5), "consent alert should dismiss")
        }

        // Cancelling web auth surfaces an in-app failure alert; dismiss it so
        // the baseline shows the resting login screen.
        let failureAlert = loginApp.alerts.firstMatch
        if failureAlert.waitForExistence(timeout: 5) {
            failureAlert.buttons["OK"].tap()
            XCTAssertTrue(failureAlert.waitForNonExistence(timeout: 5), "failure alert should dismiss")
        }
        settle()
        capture(loginApp, named: "walk-dark-login")
        loginApp.terminate()

        let errorApp = launchFixtureApp(failRoutes: "GET /v2/events/list")
        let historyTab = errorApp.tabBars.buttons["History"]
        XCTAssertTrue(historyTab.waitForExistence(timeout: 10))
        historyTab.tap()
        XCTAssertTrue(errorApp.staticTexts["Oops"].waitForExistence(timeout: 10))
        capture(errorApp, named: "walk-dark-history-error")
    }

    func testMainScreensScreenshotWalk() {
        walkMainScreens()
    }

    func testSecondaryScreensScreenshotWalk() {
        walkSecondaryScreens()
    }

    func testUnhappyPathsScreenshotWalk() {
        walkUnhappyPaths()
    }
}
