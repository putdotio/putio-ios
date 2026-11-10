import XCTest

final class ClearDataUITests: XCTestCase {
    private func openClearData() -> XCUIApplication? {
        let app = XCUIApplication()
        app.launchEnvironment["PUTIO_E2E_MOCK_API"] = "1"
        app.launchEnvironment["PUTIO_E2E_ACCESS_TOKEN"] = "e2e-token"
        app.launchEnvironment["PUTIO_E2E_RESET_STATE"] = "1"
        app.launch()

        guard app.waitForSignedInTabBar() else { return nil }
        app.tabItem("Account").tap()

        let rows = app.tables.staticTexts.matching(NSPredicate(format: "label == %@", "Clear your data"))
        let single = XCTNSPredicateExpectation(predicate: NSPredicate(format: "count == 1"), object: rows)
        XCTAssertEqual(XCTWaiter.wait(for: [single], timeout: 10), .completed, "Account should settle on one Clear your data row")
        rows.element.tap()

        guard app.tables["putio-clear-data-table"].appears(within: 5) else {
            XCTFail("Clear your data should open")
            return nil
        }
        return app
    }

    func testConfirmClearsAndReturnsToAccount() throws {
        let app = try XCTUnwrap(openClearData())

        app.tables["putio-clear-data-table"].staticTexts["Trash"].tap()
        app.navigationBars["Clear your data"].buttons["Clear"].tap()

        let confirmation = app.alerts["Clear the selected data?"]
        XCTAssertTrue(confirmation.appears(within: 5))
        confirmation.buttons["Clear"].tap()

        XCTAssertTrue(app.tables["putio-clear-data-table"].disappears(within: 10), "a successful clear should close the screen")
        XCTAssertTrue(app.tables.staticTexts["Destroy your account"].exists, "a successful clear should return to Account")
    }
}
