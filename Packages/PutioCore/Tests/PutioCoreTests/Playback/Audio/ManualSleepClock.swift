import Foundation

@testable import PutioCore

@MainActor
final class ManualSleepClock: PutioSleepTimerClock {
  private(set) var now: ContinuousClock.Instant = .now
  private var waiters: [CheckedContinuation<Void, Never>] = []

  func sleep(until deadline: ContinuousClock.Instant) async throws {
    while now < deadline {
      try Task.checkCancellation()
      await withCheckedContinuation { waiters.append($0) }
    }
    try Task.checkCancellation()
  }

  func advance(by duration: Duration) {
    now += duration
    let woken = waiters
    waiters = []
    for waiter in woken { waiter.resume() }
  }
}
