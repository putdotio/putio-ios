import XCTest

final class PlaybackSmokeUITests: XCTestCase {
    private func launchFixtureApp() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["PUTIO_E2E_MOCK_API"] = "1"
        app.launchEnvironment["PUTIO_E2E_ACCESS_TOKEN"] = "e2e-token"
        app.launchEnvironment["PUTIO_E2E_RESET_STATE"] = "1"
        app.launch()
        return app
    }

    private func waitUntilHittable(
        _ element: XCUIElement,
        byScrolling scrollView: XCUIElement,
        maximumSwipes: Int = 3
    ) -> Bool {
        for attempt in 0...maximumSwipes {
            let hittable = NSPredicate { _, _ in element.exists && element.isHittable }
            let expectation = XCTNSPredicateExpectation(predicate: hittable, object: element)
            if XCTWaiter.wait(for: [expectation], timeout: 2) == .completed {
                return true
            }
            if attempt < maximumSwipes {
                scrollView.swipeUp()
            }
        }
        return false
    }

    func testMockedPlaybackResumeFlow() {
        let app = launchFixtureApp()

        guard app.waitForSignedInTabBar() else { return }
        let movie = app.tables["putio-files-table"].cells["putio-file-42"]
        XCTAssertTrue(movie.waitForExistence(timeout: 10))

        movie.tap()

        let resumeDialog = app.alerts["Where would you like to start?"]
        XCTAssertTrue(resumeDialog.waitForExistence(timeout: 5))
        XCTAssertTrue(resumeDialog.staticTexts["Last saved timestamp for this video is 00:02:05"].exists)

        resumeDialog.buttons["Continue watching"].tap()

        let player = app.otherElements["putio-video-player"]
        XCTAssertTrue(player.waitForExistence(timeout: 5))

        let playerReady = NSPredicate(format: "value == %@", "ready")
        expectation(for: playerReady, evaluatedWith: player)
        waitForExpectations(timeout: 10)
    }

    func testAudioPlaybackRateCanChangeWithinQueueAndResetForNewPlayer() {
        let app = launchFixtureApp()

        guard app.waitForSignedInTabBar() else { return }
        let song = app.tables["putio-files-table"].cells["putio-file-43"]
        XCTAssertTrue(song.waitForExistence(timeout: 10))
        song.tap()
        XCTAssertTrue(app.staticTexts["10:00"].waitForExistence(timeout: 15))

        let playbackRateButton = app.buttons["Playback speed"]
        XCTAssertTrue(playbackRateButton.waitForExistence(timeout: 5))
        XCTAssertTrue(playbackRateButton.isEnabled)
        XCTAssertGreaterThanOrEqual(playbackRateButton.frame.width, 48)
        XCTAssertGreaterThanOrEqual(playbackRateButton.frame.height, 48)
        XCTAssertEqual(playbackRateButton.value as? String, "1×")

        let playPauseButton = app.buttons["audio-player-play-pause"]
        let upNextLabel = app.staticTexts["Up next"]
        XCTAssertTrue(playPauseButton.waitForExistence(timeout: 5))
        XCTAssertTrue(upNextLabel.waitForExistence(timeout: 5))
        XCTAssertLessThanOrEqual(
            playPauseButton.frame.maxY + 8,
            upNextLabel.frame.minY,
            "playback controls should remain clear of the queue card"
        )

        playbackRateButton.tap()
        let fasterRate = app.buttons["1.5×"]
        XCTAssertTrue(fasterRate.waitForExistence(timeout: 5))
        fasterRate.tap()
        XCTAssertEqual(playbackRateButton.value as? String, "1.5×")

        playbackRateButton.tap()
        let normalRate = app.buttons["1×"]
        XCTAssertTrue(normalRate.waitForExistence(timeout: 5))
        normalRate.tap()
        XCTAssertEqual(playbackRateButton.value as? String, "1×")

        playbackRateButton.tap()
        XCTAssertTrue(fasterRate.waitForExistence(timeout: 5))
        fasterRate.tap()
        XCTAssertEqual(playbackRateButton.value as? String, "1.5×")

        app.navigationBars.buttons["Close"].tap()
        XCTAssertTrue(song.waitForExistence(timeout: 5))
        song.tap()
        XCTAssertTrue(app.staticTexts["10:00"].waitForExistence(timeout: 15))
        XCTAssertEqual(app.buttons["Playback speed"].value as? String, "1×")
    }

    func testAudioPlayerControlsRemainReachableInLandscape() {
        let app = launchFixtureApp()
        defer { XCUIDevice.shared.orientation = .portrait }

        guard app.waitForSignedInTabBar() else { return }
        let song = app.tables["putio-files-table"].cells["putio-file-43"]
        XCTAssertTrue(song.waitForExistence(timeout: 10))
        song.tap()
        XCTAssertTrue(app.staticTexts["10:00"].waitForExistence(timeout: 15))

        XCUIDevice.shared.orientation = .landscapeLeft

        let scrollView = app.scrollViews["audio-player-scroll-view"]
        XCTAssertTrue(scrollView.waitForExistence(timeout: 5))
        let landscapeLayout = NSPredicate { _, _ in
            scrollView.frame.width > scrollView.frame.height
        }
        let rotated = XCTNSPredicateExpectation(predicate: landscapeLayout, object: scrollView)
        XCTAssertEqual(XCTWaiter.wait(for: [rotated], timeout: 5), .completed)

        let playPauseButton = app.buttons["audio-player-play-pause"]
        XCTAssertTrue(waitUntilHittable(playPauseButton, byScrolling: scrollView))

        let upNextLabel = app.staticTexts["Up next"]
        XCTAssertTrue(waitUntilHittable(upNextLabel, byScrolling: scrollView))
    }

    func testFilesScreenLoadsWithFixtureData() {
        let app = launchFixtureApp()
        guard app.waitForSignedInTabBar() else { return }
        let movie = app.tables["putio-files-table"].cells["putio-file-42"]
        XCTAssertTrue(movie.waitForExistence(timeout: 10))

        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "Files Phosphor icons"
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }

    func testAccountScreenLoadsWithFixtureData() {
        let app = launchFixtureApp()
        guard app.waitForSignedInTabBar() else { return }

        app.tabItem("Account").tap()

        XCTAssertTrue(app.navigationBars["Account"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Default sort option for files"].exists)
        XCTAssertTrue(app.staticTexts["Choose your proxy"].exists)
        XCTAssertTrue(app.staticTexts["Two-factor authentication"].exists)

        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "Account Phosphor icons"
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }

    func testDownloadsMultiSelectDeletesCompletedItemsAndLeavesActiveDownload() {
        let app = launchFixtureApp()
        guard app.waitForSignedInTabBar() else { return }

        app.tabItem("Downloads").tap()
        let downloadsTable = app.tables["putio-downloads-table"]
        let firstDownload = downloadsTable.cells.containing(
            .staticText,
            identifier: "Big Buck Bunny.mp4"
        ).element
        let secondDownload = downloadsTable.cells.containing(
            .staticText,
            identifier: "Sintel.mp4"
        ).element
        let activeDownload = downloadsTable.cells.containing(
            .staticText,
            identifier: "Tears of Steel.mp4"
        ).element
        XCTAssertTrue(firstDownload.waitForExistence(timeout: 10))
        XCTAssertTrue(secondDownload.exists)
        XCTAssertTrue(activeDownload.exists)

        app.buttons["Select completed downloads"].tap()
        XCTAssertTrue(app.navigationBars["Select Items"].waitForExistence(timeout: 5))

        activeDownload.tap()
        XCTAssertTrue(app.navigationBars["Select Items"].exists, "active downloads must not become selected")

        firstDownload.tap()
        secondDownload.tap()
        XCTAssertTrue(app.navigationBars["2 Items"].waitForExistence(timeout: 5))

        firstDownload.tap()
        XCTAssertTrue(app.navigationBars["1 Item"].waitForExistence(timeout: 5))
        firstDownload.tap()
        XCTAssertTrue(app.navigationBars["2 Items"].waitForExistence(timeout: 5))

        app.buttons["Delete 2 selected downloads"].tap()
        let confirmation = app.sheets["Delete 2 Downloads?"]
        XCTAssertTrue(confirmation.waitForExistence(timeout: 5))
        confirmation.buttons["Delete"].tap()

        XCTAssertTrue(firstDownload.waitForNonExistence(timeout: 10))
        XCTAssertTrue(secondDownload.waitForNonExistence(timeout: 10))
        XCTAssertTrue(activeDownload.exists)
        XCTAssertTrue(app.navigationBars["Downloads"].exists)
    }
}
