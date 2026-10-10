import XCTest

extension XCUIElement {
  /// XCTest's `waitForExistence(timeout:)` and `waitForNonExistence(timeout:)`
  /// sleep a full one-second poll before they first look, even when the answer
  /// is already true, which made those waits nearly half of a journey test's
  /// time. These look first, then poll every 100 ms until the timeout.
  ///
  /// `appears` also waits until the element stops moving, because a tap lands
  /// where the element is at that instant: a button in a sheet or cover that
  /// is still sliding in takes the tap at a stale position and misses.
  func appears(within timeout: TimeInterval) -> Bool {
    poll("appear", timeout: timeout) { $0.exists && $0.hasSettled(by: $1) }
  }

  func disappears(within timeout: TimeInterval) -> Bool {
    poll("disappear", timeout: timeout) { element, _ in !element.exists }
  }

  private func poll(
    _ outcome: String, timeout: TimeInterval, until condition: (XCUIElement, Date) -> Bool
  ) -> Bool {
    XCTContext.runActivity(named: "Waiting up to \(timeout)s for \(self) to \(outcome)") { _ in
      let deadline = Date.now.addingTimeInterval(timeout)
      while !condition(self, deadline) {
        guard Date.now < deadline else { return false }
        Self.pause(until: deadline)
      }
      return true
    }
  }

  /// True once two frames read 100 ms apart match. Reads the first match,
  /// because `frame` fails a query that matches several elements.
  private func hasSettled(by deadline: Date) -> Bool {
    let target = firstMatch
    var previous = target.frame
    while Date.now < deadline {
      Self.pause(until: deadline)
      guard target.exists else { return false }
      let current = target.frame
      if current == previous { return true }
      previous = current
    }
    return false
  }

  private static func pause(until deadline: Date) {
    RunLoop.current.run(until: min(deadline, Date.now.addingTimeInterval(0.1)))
  }
}
