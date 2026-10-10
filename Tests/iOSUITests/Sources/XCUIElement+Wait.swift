import XCTest

extension XCUIElement {
  /// XCTest's `waitForExistence(timeout:)` and `waitForNonExistence(timeout:)`
  /// sleep a full one-second poll before they first look, even when the answer
  /// is already true, which made those waits nearly half of a journey test's
  /// time. These look first, then poll every 100 ms until the timeout.
  func appears(within timeout: TimeInterval) -> Bool {
    poll("appear", timeout: timeout) { $0.exists }
  }

  func disappears(within timeout: TimeInterval) -> Bool {
    poll("disappear", timeout: timeout) { !$0.exists }
  }

  private func poll(
    _ outcome: String, timeout: TimeInterval, until condition: (XCUIElement) -> Bool
  ) -> Bool {
    XCTContext.runActivity(named: "Waiting up to \(timeout)s for \(self) to \(outcome)") { _ in
      let deadline = Date.now.addingTimeInterval(timeout)
      while !condition(self) {
        guard Date.now < deadline else { return false }
        RunLoop.current.run(until: min(deadline, Date.now.addingTimeInterval(0.1)))
      }
      return true
    }
  }
}
