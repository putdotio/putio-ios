import SnapshotTesting
import XCTest

// Captures every main screen and asserts it against the committed baselines in
// PutioUITests/__Snapshots__/. Re-record intentionally with
// `mise run screenshots-record` and review the image diff.
final class ScreenshotWalkUITests: XCTestCase {
    private var isRecording: Bool {
        ProcessInfo.processInfo.environment["PUTIO_RECORD_SNAPSHOTS"] == "1"
    }

    // Redirects the iPad store-capture lane away from __Snapshots__/.
    // SnapshotTesting names a file after the test, not the device, so without
    // this the iPad captures would overwrite the iPhone set CI compares.
    private var snapshotDirectoryOverride: String? {
        ProcessInfo.processInfo.environment["PUTIO_SNAPSHOT_DIR"]
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

    // Presentation animations (~0.35s) race capture; let them settle.
    private func settle() {
        Thread.sleep(forTimeInterval: 0.8)
    }

    private func capture(_ app: XCUIApplication, named name: String) {
        let screenshot = app.screenshot()

        // verifySnapshot rather than assertSnapshot: only the former takes a
        // snapshotDirectory, and its returned failure text is what
        // verify-snapshot-recording.rb matches to tell a record-mode failure
        // from a real one.
        //
        // precision tolerates a few outlier pixels; perceptualPrecision absorbs
        // antialiasing drift across Xcode and simulator builds.
        let failure = verifySnapshot(
            of: screenshot.image,
            as: .image(precision: 0.995, perceptualPrecision: 0.98),
            named: String(name.dropFirst("walk-".count)),
            record: isRecording,
            snapshotDirectory: snapshotDirectoryOverride,
            testName: "walk"
        )

        if let failure {
            XCTFail(failure)
        }
    }

    private func walkMainScreens() {
        let app = launchFixtureApp()

        guard app.waitForSignedInTabBar() else { return }
        XCTAssertTrue(app.tables["putio-files-table"].cells["putio-file-42"].waitForExistence(timeout: 10))
        capture(app, named: "walk-dark-files")

        // Tab-specific, because a generic nav-bar wait is satisfiable before
        // rendering ends.
        let readiness: [String: XCUIElement] = [
            // Scoped to the table: the fixture library is shared, so a bare
            // title also matches rows on other tabs.
            "Downloads": app.tables["putio-downloads-table"].cells["putio-download-75"],
            "History": app.tables["putio-history-table"].staticTexts["Tears of Steel.mp4"],
            "Account": app.tables.staticTexts["Manage your trash"]
        ]

        for tab in ["Downloads", "History", "Account"] {
            let button = app.tabItem(tab)
            XCTAssertTrue(button.waitForExistence(timeout: 5), "\(tab) tab should exist")
            button.tap()
            XCTAssertTrue(readiness[tab]!.waitForExistence(timeout: 10), "\(tab) content should render")
            capture(app, named: "walk-dark-\(tab.lowercased())")
        }

        let trashRow = app.tables.staticTexts["Manage your trash"]
        XCTAssertTrue(trashRow.waitForExistence(timeout: 5))
        trashRow.tap()
        XCTAssertTrue(app.staticTexts["Elephants Dream.mp4"].waitForExistence(timeout: 5))
        capture(app, named: "walk-dark-trash")
    }

    private func walkVideoPlayer() {
        let app = launchFixtureApp()

        guard app.waitForSignedInTabBar() else { return }

        // Also the App Store set's second slot, so this capture is
        // marketing-facing. The bundled still frame (Putio/E2EMedia) keeps it
        // identical on every run.
        let movie = app.tables["putio-files-table"].cells["putio-file-42"]
        XCTAssertTrue(movie.waitForExistence(timeout: 10))
        movie.tap()

        // File 42 has a saved position, so the app asks before playing. Start
        // from the beginning — resuming seeks, and capture can beat the seek.
        let resumeDialog = app.alerts["Where would you like to start?"]
        XCTAssertTrue(resumeDialog.waitForExistence(timeout: 10), "resume prompt should appear for a file with a start position")
        resumeDialog.buttons["Start from the beginning"].tap()

        let player = app.otherElements["putio-video-player"]
        XCTAssertTrue(player.waitForExistence(timeout: 10))

        // The frame is only decoded once the player reports ready; capturing
        // earlier yields black.
        let ready = NSPredicate(format: "value == %@", "ready")
        expectation(for: ready, evaluatedWith: player)
        waitForExpectations(timeout: 20)

        settle()
        capture(app, named: "walk-dark-video-player")
    }

    private func walkSecondaryScreens() {
        let app = launchFixtureApp()

        guard app.waitForSignedInTabBar() else { return }

        let song = app.tables["putio-files-table"].cells["putio-file-43"]
        XCTAssertTrue(song.waitForExistence(timeout: 10))
        song.tap()
        XCTAssertTrue(app.staticTexts["Sintel Theme.mp3"].waitForExistence(timeout: 10))
        // The duration label is what proves the local asset actually loaded.
        // Any playback that advances before capture moves the elapsed glyphs
        // and slider thumb far less than the snapshot tolerance.
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

        XCTAssertTrue(app.tables["putio-files-table"].cells["putio-file-42"].waitForExistence(timeout: 5))
        app.buttons["More"].tap()
        let selectAction = app.buttons["Select"]
        XCTAssertTrue(selectAction.waitForExistence(timeout: 5), "Select should be in the More menu")
        selectAction.tap()
        app.tables["putio-files-table"].cells["putio-file-42"].tap()
        app.buttons["Move"].tap()
        XCTAssertTrue(app.navigationBars["Your Files"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Big Buck Bunny.mp4"].firstMatch.waitForExistence(timeout: 10), "move sheet content should render")
        settle()
        capture(app, named: "walk-dark-move-files")
        app.buttons["Cancel"].firstMatch.tap()
        settle()

        app.tabItem("Downloads").tap()
        let tutorialButton = app.buttons["Downloads tutorial"]
        XCTAssertTrue(tutorialButton.waitForExistence(timeout: 5))
        tutorialButton.tap()
        XCTAssertTrue(app.staticTexts["Downloads: Mini Tutorial"].waitForExistence(timeout: 5))
        // The sheet's clip parks on a fixed frame under the mocked API and
        // reports "parked" once it is on screen (see
        // DownloadsTutorialViewController). The seek is asynchronous, so
        // waiting on that is what keeps capture off a racing frame.
        let tutorialFrame = NSPredicate(format: "value == %@", "parked")
        expectation(for: tutorialFrame, evaluatedWith: app.otherElements["putio-downloads-tutorial"])
        waitForExpectations(timeout: 10)
        settle()
        capture(app, named: "walk-dark-downloads-tutorial")
        app.swipeDown(velocity: .fast)
        XCTAssertTrue(app.staticTexts["Downloads: Mini Tutorial"].waitForNonExistence(timeout: 5), "tutorial sheet should dismiss")

        app.tabItem("Account").tap()
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
        XCTAssertTrue(app.staticTexts["put.io Web"].waitForExistence(timeout: 10))
        settle()
        capture(app, named: "walk-dark-sessions")
    }

    private func walkUnhappyPaths() {
        let loginApp = launchFixtureApp(loggedIn: false)
        XCTAssertTrue(loginApp.buttons["Log in"].waitForExistence(timeout: 10))

        // Web auth does not auto-start under the mocked API, so no system
        // consent alert should cover this capture. Give the alert a window to
        // appear rather than checking one instant — that race is the point.
        XCTAssertFalse(
            XCUIApplication(bundleIdentifier: "com.apple.springboard").alerts.firstMatch
                .waitForExistence(timeout: 3),
            "web auth should not auto-start against the mocked API"
        )
        settle()
        capture(loginApp, named: "walk-dark-login")
        loginApp.terminate()

        let errorApp = launchFixtureApp(failRoutes: "GET /v2/events/list")
        guard errorApp.waitForSignedInTabBar() else { return }
        errorApp.tabItem("History").tap()
        XCTAssertTrue(errorApp.staticTexts["Oops"].waitForExistence(timeout: 10))
        capture(errorApp, named: "walk-dark-history-error")
    }

    func testMainScreensScreenshotWalk() {
        walkMainScreens()
    }

    func testVideoPlayerScreenshotWalk() {
        walkVideoPlayer()
    }

    func testSecondaryScreensScreenshotWalk() {
        walkSecondaryScreens()
    }

    func testUnhappyPathsScreenshotWalk() {
        walkUnhappyPaths()
    }
}
