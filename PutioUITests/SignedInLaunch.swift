import XCTest

extension XCUIApplication {
    // A tab item is the first proof the app reached the signed-in state. When
    // the sign-in bootstrap fails instead, the raw XCUITest error names the
    // missing TabBar rather than the cause — so the two are told apart here.
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

    // iPadOS renders a UITabBarController with no TabBar element in the
    // accessibility tree at all, just buttons in an anonymous container, so
    // `tabBars` matches nothing there. The scoped query stays first so iPhone
    // resolves exactly what it did before; the app-wide fallback is safe
    // because no other button these tests meet carries a tab label.
    func tabItem(_ name: String) -> XCUIElement {
        let scoped = tabBars.buttons[name]
        return scoped.exists ? scoped : buttons[name].firstMatch
    }
}
