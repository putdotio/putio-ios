import XCTest

extension XCUIElement {
  /// XCTest's `waitForExistence(timeout:)` and `waitForNonExistence(timeout:)`
  /// sleep a full one-second poll before they first look, even when the answer
  /// is already true. These look first, then poll every 100 ms until the
  /// timeout, stretched by the harness-set `PUTIO_UI_TIMEOUT_SCALE` on a loaded host.
  ///
  /// `appears` also waits until the element stops moving, because a tap lands
  /// where the element is at that instant: a button in a sheet or cover that
  /// is still sliding in takes the tap at a stale position and misses.
  func appears(within timeout: TimeInterval) -> Bool {
    poll("appear", timeout: timeout) { $0.exists && $0.hasSettled(by: $1) }
  }

  func shows(within timeout: TimeInterval) -> Bool {
    poll("show", timeout: timeout) { element, _ in element.exists }
  }

  func becomesHittable(within timeout: TimeInterval) -> Bool {
    poll("become hittable", timeout: timeout) { element, _ in element.isHittable }
  }

  func becomesTappable(within timeout: TimeInterval) -> Bool {
    poll("become tappable", timeout: timeout) { element, _ in
      element.isHittable && element.isEnabled
    }
  }

  func becomesSelected(within timeout: TimeInterval) -> Bool {
    poll("become selected", timeout: timeout) { element, _ in
      element.exists && element.isSelected
    }
  }

  func becomesUnhittable(within timeout: TimeInterval) -> Bool {
    poll("become unhittable", timeout: timeout) { element, _ in !element.isHittable }
  }

  func hasValue(_ value: String, within timeout: TimeInterval) -> Bool {
    poll("read \(value)", timeout: timeout) { element, _ in
      element.exists && element.value as? String == value
    }
  }

  func disappears(within timeout: TimeInterval) -> Bool {
    poll("disappear", timeout: timeout) { element, _ in !element.exists }
  }

  static let timeoutScale: TimeInterval =
    ProcessInfo.processInfo.environment["PUTIO_UI_TIMEOUT_SCALE"]
    .flatMap(TimeInterval.init).map { max($0, 1) } ?? 1

  private func poll(
    _ outcome: String, timeout: TimeInterval, until condition: (XCUIElement, Date) -> Bool
  ) -> Bool {
    let timeout = timeout * Self.timeoutScale
    let activity = "Waiting up to \(timeout)s for \(self) to \(outcome)"
    return XCTContext.runActivity(named: activity) { _ in
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
    guard var previous = try? target.snapshot().frame else { return false }
    repeat {
      RunLoop.current.run(until: Date.now.addingTimeInterval(0.1))
      guard let current = try? target.snapshot().frame else { return false }
      if current == previous { return true }
      previous = current
    } while Date.now < deadline
    return false
  }

  private static func pause(until deadline: Date) {
    RunLoop.current.run(until: min(deadline, Date.now.addingTimeInterval(0.1)))
  }
}
