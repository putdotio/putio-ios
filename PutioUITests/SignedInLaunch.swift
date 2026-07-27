import XCTest

extension XCUIApplication {
    // Every mocked test launches signed in, so the tab bar is the first proof
    // the app got there. When the sign-in bootstrap fails the app drops to the
    // login screen instead, and the raw XCUITest failure ("No matches found for
    // Descendants matching type TabBar") describes the symptom rather than the
    // cause. Distinguish the two so a CI failure is readable on its own.
    @discardableResult
    func waitForSignedInTabBar(
        timeout: TimeInterval = 20,
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> Bool {
        if tabBars.firstMatch.waitForExistence(timeout: timeout) {
            return true
        }

        if buttons["Log in"].exists {
            XCTFail(
                "app fell back to the login screen: the mocked sign-in bootstrap did not complete",
                file: file,
                line: line
            )
        } else {
            XCTFail("signed-in tab bar did not appear within \(timeout)s", file: file, line: line)
        }

        return false
    }
}
