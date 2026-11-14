import Observation
import SwiftUI

enum PutioSleepTimerChoice: Int, CaseIterable, Identifiable, Sendable {
  case fifteenMinutes = 15
  case thirtyMinutes = 30
  case fortyFiveMinutes = 45
  case oneHour = 60

  var id: Int { rawValue }

  var duration: Duration { .seconds(rawValue * 60) }

  var title: String {
    rawValue.isMultiple(of: 60)
      ? String(localized: "\(rawValue / 60) hours")
      : String(localized: "\(rawValue) minutes")
  }
}

@MainActor
protocol PutioSleepTimerClock: AnyObject {
  var now: ContinuousClock.Instant { get }
  func sleep(until deadline: ContinuousClock.Instant) async throws
}

@MainActor
final class PutioSystemSleepTimerClock: PutioSleepTimerClock {
  var now: ContinuousClock.Instant { .now }

  func sleep(until deadline: ContinuousClock.Instant) async throws {
    try await Task.sleep(until: deadline, clock: .continuous)
  }
}

@MainActor
@Observable
final class PutioAudioSleepTimer {
  private(set) var choice: PutioSleepTimerChoice?
  private(set) var remainingSeconds: Int?

  @ObservationIgnored let clock: any PutioSleepTimerClock
  @ObservationIgnored var onExpire: (@MainActor () -> Void)?
  @ObservationIgnored private var deadline: ContinuousClock.Instant?
  @ObservationIgnored private var task: Task<Void, Never>?

  init(clock: any PutioSleepTimerClock) {
    self.clock = clock
  }

  var isRunning: Bool { choice != nil }

  func start(_ choice: PutioSleepTimerChoice) {
    task?.cancel()
    let deadline = clock.now + choice.duration
    self.choice = choice
    self.deadline = deadline
    remainingSeconds = Self.wholeSeconds(choice.duration)
    task = Task { [weak self] in await self?.count(down: deadline) }
  }

  func cancel() {
    task?.cancel()
    task = nil
    choice = nil
    deadline = nil
    remainingSeconds = nil
  }

  private func count(down deadline: ContinuousClock.Instant) async {
    while self.deadline == deadline, !Task.isCancelled {
      let remaining = Self.wholeSeconds(deadline - clock.now)
      remainingSeconds = remaining
      guard remaining > 0 else {
        cancel()
        onExpire?()
        return
      }
      do {
        try await clock.sleep(until: deadline - .seconds(remaining - 1))
      } catch {
        return
      }
    }
  }

  private static func wholeSeconds(_ duration: Duration) -> Int {
    let (seconds, attoseconds) = duration.components
    guard seconds >= 0, duration > .zero else { return 0 }
    return Int(seconds) + (attoseconds > 0 ? 1 : 0)
  }
}
