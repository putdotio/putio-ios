import XCTest

@testable import Putio

@MainActor
final class PutioAudioSleepTimerTests: XCTestCase {
  private func waitUntil(
    _ condition: @MainActor () -> Bool, file: StaticString = #filePath, line: UInt = #line
  ) async {
    let deadline = ContinuousClock.now + .seconds(2)
    while !condition() {
      if ContinuousClock.now > deadline {
        return XCTFail("condition not met before the deadline", file: file, line: line)
      }
      await Task.yield()
    }
  }

  func testChoicesMatchTheMenu() {
    XCTAssertEqual(
      PutioSleepTimerChoice.allCases.map(\.title),
      ["15 minutes", "30 minutes", "45 minutes", "1 hour"])
  }

  func testCountsDownAndExpiresOnceAtZero() async {
    let clock = PutioManualSleepTimerClock()
    let timer = PutioAudioSleepTimer(clock: clock)
    var expiries = 0
    timer.onExpire = { expiries += 1 }

    timer.start(.fifteenMinutes)
    XCTAssertEqual(timer.remainingSeconds, 900)
    clock.advance(by: .seconds(198))
    await waitUntil { timer.remainingSeconds == 702 }
    XCTAssertEqual(PutioAudioClock.text(702), "11:42")
    clock.advance(by: .seconds(701))
    await waitUntil { timer.remainingSeconds == 1 }
    XCTAssertEqual(expiries, 0)
    clock.advance(by: .seconds(1))
    await waitUntil { expiries == 1 }

    XCTAssertFalse(timer.isRunning)
    XCTAssertNil(timer.choice)
    XCTAssertNil(timer.remainingSeconds)
    clock.advance(by: .seconds(3600))
    for _ in 0..<20 { await Task.yield() }
    XCTAssertEqual(expiries, 1)
  }

  func testAnotherChoiceRestartsFromItsFullLength() async {
    let clock = PutioManualSleepTimerClock()
    let timer = PutioAudioSleepTimer(clock: clock)
    var expiries = 0
    timer.onExpire = { expiries += 1 }

    timer.start(.fifteenMinutes)
    clock.advance(by: .seconds(600))
    await waitUntil { timer.remainingSeconds == 300 }
    timer.start(.thirtyMinutes)
    XCTAssertEqual(timer.choice, .thirtyMinutes)
    XCTAssertEqual(timer.remainingSeconds, 1800)
    clock.advance(by: .seconds(300))
    await waitUntil { timer.remainingSeconds == 1500 }
    XCTAssertEqual(expiries, 0, "the first run's deadline must not fire")
    clock.advance(by: .seconds(1500))
    await waitUntil { expiries == 1 }
  }

  func testOffCancelsWithoutPausing() async {
    let clock = PutioManualSleepTimerClock()
    let timer = PutioAudioSleepTimer(clock: clock)
    var expiries = 0
    timer.onExpire = { expiries += 1 }

    timer.start(.oneHour)
    timer.cancel()
    clock.advance(by: .seconds(3600))
    for _ in 0..<20 { await Task.yield() }

    XCTAssertEqual(expiries, 0)
    XCTAssertNil(timer.remainingSeconds)
    XCTAssertFalse(timer.isRunning)
  }
}
