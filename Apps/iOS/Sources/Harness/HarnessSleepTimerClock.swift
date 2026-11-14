#if DEBUG
  import Foundation
  import SwiftUI

  @MainActor
  final class PutioManualSleepTimerClock: PutioSleepTimerClock {
    static let harnessStep: Duration = .seconds(198)

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

  struct HarnessSleepClockProbe: View {
    let clock: PutioManualSleepTimerClock

    var body: some View {
      Button("Sleep timer clock") {
        clock.advance(by: PutioManualSleepTimerClock.harnessStep)
      }
      .buttonStyle(HarnessInvisibleButtonStyle())
      .accessibilityIdentifier("audio.sleep-clock")
    }
  }

  private struct HarnessInvisibleButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
      Color.clear
        .frame(width: 44, height: 44)
        .contentShape(Rectangle())
    }
  }
#endif
