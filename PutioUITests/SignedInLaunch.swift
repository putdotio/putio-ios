import XCTest

extension XCUIApplication {
    // Every mocked test launches signed in, so a tab item is the first proof the
    // app got there. When the sign-in bootstrap fails the app drops to the login
    // screen instead, and the raw XCUITest failure ("No matches found for
    // Descendants matching type TabBar") describes the symptom rather than the
    // cause. Distinguish the two so a CI failure is readable on its own.
    @discardableResult
    func waitForSignedInTabBar(
        timeout: TimeInterval = 20,
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> Bool {
        if tabItem("Files").waitForExistence(timeout: timeout) {
            return true
        }

        if buttons["Log in"].exists {
            XCTFail(
                "app fell back to the login screen: the mocked sign-in bootstrap did not complete",
                file: file,
                line: line
            )
        } else {
            XCTFail("no signed-in tab item appeared within \(timeout)s", file: file, line: line)
        }

        return false
    }

    // Resolves a tab item on either presentation. iPadOS renders a
    // UITabBarController as a top tab bar with no TabBar element in the
    // accessibility tree at all — just buttons inside an anonymous container —
    // so a `tabBars` query matches nothing there, and the iPad store-capture
    // lane could not reach a single tab.
    //
    // The scoped query comes first, so iPhone keeps resolving exactly the
    // element it did before. The app-wide fallback is safe for the four tab
    // labels: the only other buttons these tests meet are More, Search, Select,
    // Move, Cancel, Stop and "Downloads tutorial". A file *cell* can be named
    // Downloads, but a cell is not a button.
    func tabItem(_ name: String) -> XCUIElement {
        let scoped = tabBars.buttons[name]
        return scoped.exists ? scoped : buttons[name].firstMatch
    }
}
