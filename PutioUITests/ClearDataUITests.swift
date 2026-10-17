import XCTest

final class ClearDataUITests: XCTestCase {
    private func openClearData(failRoutes: String? = nil) -> XCUIApplication? {
        let app = XCUIApplication()
        app.launchEnvironment["PUTIO_E2E_MOCK_API"] = "1"
        app.launchEnvironment["PUTIO_E2E_ACCESS_TOKEN"] = "e2e-token"
        app.launchEnvironment["PUTIO_E2E_RESET_STATE"] = "1"
        if let failRoutes {
            app.launchEnvironment["PUTIO_E2E_FAIL_ROUTES"] = failRoutes
        }
        app.launch()

        guard app.waitForSignedInTabBar() else { return nil }
        app.tabItem("Account").tap()

        let row = app.tables.staticTexts["Clear your data"]
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        row.tap()

        guard app.tables["putio-clear-data-table"].waitForExistence(timeout: 5) else {
            XCTFail("Clear your data should open")
            return nil
        }
        return app
    }

    // The forced failure detects the request: an error alert with OK appears
    // only if the app sent POST /v2/account/clear.
    func testCancelSendsNothingAndConfirmSendsTheRequest() throws {
        let app = try XCTUnwrap(openClearData(failRoutes: "POST /v2/account/clear"))
        let table = app.tables["putio-clear-data-table"]
        let clear = app.navigationBars["Clear your data"].buttons["Clear"]

        XCTAssertFalse(clear.isEnabled, "Clear should wait for a selection")
        table.staticTexts["Files"].tap()
        table.staticTexts["History"].tap()
        XCTAssertTrue(clear.isEnabled)
        attachScreenshot(of: app, named: "Clear your data")

        clear.tap()
        let confirmation = app.alerts["Clear the selected data?"]
        XCTAssertTrue(confirmation.waitForExistence(timeout: 5))
        XCTAssertTrue(
            confirmation.staticTexts["This permanently deletes Files and History from your put.io account. It can't be undone."].exists
        )
        attachScreenshot(of: app, named: "Clear confirmation")

        confirmation.buttons["Cancel"].tap()
        XCTAssertFalse(app.alerts.buttons["OK"].waitForExistence(timeout: 3), "Cancel must not send the request")

        clear.tap()
        XCTAssertTrue(confirmation.waitForExistence(timeout: 5))
        confirmation.buttons["Clear"].tap()
        XCTAssertTrue(app.alerts.buttons["OK"].waitForExistence(timeout: 10), "Clear should send the request")
    }

    func testConfirmClearsAndReturnsToAccount() throws {
        let app = try XCTUnwrap(openClearData())

        app.tables["putio-clear-data-table"].staticTexts["Trash"].tap()
        app.navigationBars["Clear your data"].buttons["Clear"].tap()

        let confirmation = app.alerts["Clear the selected data?"]
        XCTAssertTrue(confirmation.waitForExistence(timeout: 5))
        confirmation.buttons["Clear"].tap()

        let closed = expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: app.tables["putio-clear-data-table"])
        wait(for: [closed], timeout: 10)
        XCTAssertTrue(app.tables.staticTexts["Destroy your account"].exists, "a successful clear should return to Account")
    }

    private func attachScreenshot(of app: XCUIApplication, named name: String) {
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = name
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }
}
