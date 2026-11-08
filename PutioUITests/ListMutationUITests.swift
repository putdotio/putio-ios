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
        XCTAssertTrue(movie.appears(within: 10))
        app.buttons["More"].tap()
        let selectAction = app.buttons["Select"]
        XCTAssertTrue(selectAction.appears(within: 5))
        selectAction.tap()
        movie.tap()
        app.buttons["Move"].tap()

        XCTAssertTrue(app.navigationBars["Your Files"].appears(within: 5))
        let destinations = app.tables.matching(NSPredicate(format: "identifier != %@", "putio-files-table")).firstMatch
        let folder = destinations.staticTexts["Movies"]
        XCTAssertTrue(folder.appears(within: 10))
        folder.tap()

        let folderBar = app.navigationBars["Movies"]
        XCTAssertTrue(folderBar.appears(within: 5))
        let moveHere = app.toolbars.buttons["Move Here"]
        XCTAssertTrue(moveHere.reaches(NSPredicate(format: "isEnabled == true"), within: 10), "Move Here should enable")
        moveHere.tap()

        XCTAssertTrue(folderBar.disappears(within: 10), "a successful move should close the sheet")
        XCTAssertFalse(app.alerts.firstMatch.exists, "a successful move should not show an error")
        XCTAssertTrue(movie.appears(within: 10))
    }

    func testEmptyingTrashLeavesNoStaleRows() {
        let app = launchFixtureApp()
        guard app.waitForSignedInTabBar() else { return }

        app.tabItem("Account").tap()
        let trashRow = app.tables.staticTexts["Manage your trash"]
        XCTAssertTrue(trashRow.appears(within: 10))
        trashRow.tap()

        let trashedFile = app.staticTexts["Elephants Dream.mp4"]
        XCTAssertTrue(trashedFile.appears(within: 10))

        let trashBar = app.navigationBars["Trash"]
        let menu = trashBar.buttons.matching(NSPredicate(format: "label != %@ AND identifier != %@", "Account", "BackButton")).firstMatch
        XCTAssertTrue(menu.reaches(NSPredicate(format: "isEnabled == true"), within: 10), "the trash menu should enable")
        menu.tap()

        let emptyAction = app.buttons["Empty trash"]
        XCTAssertTrue(emptyAction.appears(within: 5))
        emptyAction.tap()
        let confirmation = app.alerts["Are you sure to delete those files?"]
        XCTAssertTrue(confirmation.appears(within: 5))
        confirmation.buttons["Yes, empty trash"].tap()

        assertPullToRefreshAfterEmptying(
            app,
            table: app.tables["putio-trash-table"],
            emptyState: "Your trash is empty",
            staleRow: trashedFile,
            arrivedRow: app.staticTexts["Sintel.mp4"]
        )
    }

    func testClearingHistoryLeavesNoStaleRows() {
        let app = launchFixtureApp()
        guard app.waitForSignedInTabBar() else { return }

        app.tabItem("History").tap()
        let event = app.tables["putio-history-table"].staticTexts["Tears of Steel.mp4"]
        XCTAssertTrue(event.appears(within: 10))

        let clear = app.navigationBars["History"].buttons["Clear"]
        XCTAssertTrue(clear.reaches(NSPredicate(format: "isEnabled == true"), within: 10), "Clear should enable")
        clear.tap()
        let confirmation = app.sheets["Are you sure?"]
        XCTAssertTrue(confirmation.appears(within: 5))
        confirmation.buttons["Clear"].tap()

        assertPullToRefreshAfterEmptying(
            app,
            table: app.tables["putio-history-table"],
            emptyState: "Your history is empty",
            staleRow: event,
            arrivedRow: app.tables["putio-history-table"].staticTexts["Sintel.mp4"]
        )
    }

    private func assertPullToRefreshAfterEmptying(
        _ app: XCUIApplication,
        table: XCUIElement,
        emptyState: String,
        staleRow: XCUIElement,
        arrivedRow: XCUIElement,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let placeholder = app.staticTexts[emptyState]
        XCTAssertTrue(placeholder.appears(within: 10), "the empty state should show", file: file, line: line)
        XCTAssertFalse(staleRow.exists, "the emptied table should drop its rows", file: file, line: line)

        table.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.1))
            .press(forDuration: 0.1, thenDragTo: table.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.9)), withVelocity: .slow, thenHoldForDuration: 0.3)

        XCTAssertTrue(arrivedRow.appears(within: 10), "the pull should refresh the table under the empty state", file: file, line: line)
        XCTAssertEqual(app.state, .runningForeground, file: file, line: line)
        XCTAssertFalse(placeholder.exists, "the refreshed list should replace the empty state", file: file, line: line)
        XCTAssertFalse(staleRow.exists, "a refresh should not bring stale rows back", file: file, line: line)
    }
}
