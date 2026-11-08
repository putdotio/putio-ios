import XCTest

final class ListMutationUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    private func launchFixtureApp() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["PUTIO_E2E_MOCK_API"] = "1"
        app.launchEnvironment["PUTIO_E2E_ACCESS_TOKEN"] = "e2e-token"
        app.launchEnvironment["PUTIO_E2E_RESET_STATE"] = "1"
        app.launch()
        return app
    }

    func testMovingAFileIntoAFolderClosesTheMoveSheet() {
        let app = launchFixtureApp()
        guard app.waitForSignedInTabBar() else { return }

        let movie = app.tables["putio-files-table"].cells["putio-file-42"]
        XCTAssertTrue(movie.waitForExistence(timeout: 10))
        app.buttons["More"].tap()
        let selectAction = app.buttons["Select"]
        XCTAssertTrue(selectAction.waitForExistence(timeout: 5))
        selectAction.tap()
        movie.tap()
        app.buttons["Move"].tap()

        XCTAssertTrue(app.navigationBars["Your Files"].waitForExistence(timeout: 5))
        let destinations = app.tables.matching(NSPredicate(format: "identifier != %@", "putio-files-table")).firstMatch
        let folder = destinations.staticTexts["Movies"]
        XCTAssertTrue(folder.waitForExistence(timeout: 10))
        folder.tap()

        let folderBar = app.navigationBars["Movies"]
        XCTAssertTrue(folderBar.waitForExistence(timeout: 5))
        let moveHere = app.toolbars.buttons["Move Here"]
        expectation(for: NSPredicate(format: "isEnabled == true"), evaluatedWith: moveHere)
        waitForExpectations(timeout: 10)
        moveHere.tap()

        XCTAssertTrue(folderBar.waitForNonExistence(timeout: 10), "a successful move should close the sheet")
        XCTAssertFalse(app.alerts.firstMatch.exists, "a successful move should not show an error")
        XCTAssertTrue(movie.waitForExistence(timeout: 10))
    }

    func testEmptyingTrashLeavesNoStaleRows() {
        let app = launchFixtureApp()
        guard app.waitForSignedInTabBar() else { return }

        app.tabItem("Account").tap()
        let trashRow = app.tables.staticTexts["Manage your trash"]
        XCTAssertTrue(trashRow.waitForExistence(timeout: 10))
        trashRow.tap()

        let trashedFile = app.staticTexts["Elephants Dream.mp4"]
        XCTAssertTrue(trashedFile.waitForExistence(timeout: 10))

        let trashBar = app.navigationBars["Trash"]
        let menu = trashBar.buttons.matching(NSPredicate(format: "label != %@ AND identifier != %@", "Account", "BackButton")).firstMatch
        expectation(for: NSPredicate(format: "isEnabled == true"), evaluatedWith: menu)
        waitForExpectations(timeout: 10)
        menu.tap()

        let emptyAction = app.buttons["Empty trash"]
        XCTAssertTrue(emptyAction.waitForExistence(timeout: 5))
        emptyAction.tap()
        let confirmation = app.alerts["Are you sure to delete those files?"]
        XCTAssertTrue(confirmation.waitForExistence(timeout: 5))
        confirmation.buttons["Yes, empty trash"].tap()

        assertEmptyAfterPullToRefresh(app, emptyState: "Your trash is empty", staleRow: trashedFile)
    }

    func testClearingHistoryLeavesNoStaleRows() {
        let app = launchFixtureApp()
        guard app.waitForSignedInTabBar() else { return }

        app.tabItem("History").tap()
        let event = app.tables["putio-history-table"].staticTexts["Tears of Steel.mp4"]
        XCTAssertTrue(event.waitForExistence(timeout: 10))

        let clear = app.navigationBars["History"].buttons["Clear"]
        expectation(for: NSPredicate(format: "isEnabled == true"), evaluatedWith: clear)
        waitForExpectations(timeout: 10)
        clear.tap()
        let confirmation = app.sheets["Are you sure?"]
        XCTAssertTrue(confirmation.waitForExistence(timeout: 5))
        confirmation.buttons["Clear"].tap()

        assertEmptyAfterPullToRefresh(app, emptyState: "Your history is empty", staleRow: event)
    }

    private func assertEmptyAfterPullToRefresh(
        _ app: XCUIApplication,
        emptyState: String,
        staleRow: XCUIElement,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let placeholder = app.staticTexts[emptyState]
        XCTAssertTrue(placeholder.waitForExistence(timeout: 10), "the empty state should show", file: file, line: line)
        XCTAssertFalse(staleRow.exists, "the emptied table should drop its rows", file: file, line: line)

        app.swipeDown(velocity: .slow)

        XCTAssertEqual(app.state, .runningForeground, file: file, line: line)
        XCTAssertTrue(placeholder.waitForExistence(timeout: 10), "the empty state should stay after a refresh", file: file, line: line)
        XCTAssertFalse(staleRow.exists, "a refresh should not bring stale rows back", file: file, line: line)
    }
}
