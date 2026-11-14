import Foundation
import XCTest

@testable import PutioCore

@MainActor
private final class ManualSchedule: PutioPositionReportSchedule {
  let interval: Duration
  private(set) var invalidated = false
  private let callback: @MainActor @Sendable () -> Void

  init(interval: Duration, callback: @escaping @MainActor @Sendable () -> Void) {
    self.interval = interval
    self.callback = callback
  }

  func invalidate() { invalidated = true }

  /// Fires like a schedule that missed its cancellation would.
  func tick() { callback() }
}

@MainActor
private final class ReporterHarness {
  var position: Int? = 0
  private(set) var schedules: [ManualSchedule] = []
  private(set) var reported: [Int] = []
  private(set) var attempted: [Int] = []
  var failingSaves = 0
  var saveError = PutioRuntimeError.invalidResponse
  let pipeline = PutioPlaybackPositionPipeline()
  let fileID = PutioFileID(rawValue: 7)

  func reporter(
    remembersPosition: Bool = true,
    savedPosition: Int? = nil,
    endOfPlayback: PutioVideoPositionReporter.EndOfPlayback = .resetsPosition
  ) -> PutioVideoPositionReporter {
    PutioVideoPositionReporter(
      fileID: fileID,
      remembersPosition: remembersPosition,
      pipeline: pipeline,
      report: { [weak self] _, seconds in try self?.save(seconds) },
      currentPosition: { [weak self] in self?.position },
      savedPosition: savedPosition,
      endOfPlayback: endOfPlayback,
      schedule: { [weak self] interval, callback in
        let schedule = ManualSchedule(interval: interval, callback: callback)
        self?.schedules.append(schedule)
        return schedule
      }
    )
  }

  func drain() async {
    await pipeline.waitForPendingReports(fileID: fileID)
  }

  private func save(_ seconds: Int) throws {
    attempted.append(seconds)
    if failingSaves > 0 {
      failingSaves -= 1
      throw saveError
    }
    reported.append(seconds)
  }
}

final class PutioVideoResumePromptTests: XCTestCase {
  func testPromptAppearsOnlyWithRememberedPositionAndDuration() {
    XCTAssertNotNil(
      PutioVideoResumePrompt(startFromSeconds: 90, durationSeconds: 5400, remembersPosition: true))
    XCTAssertNil(
      PutioVideoResumePrompt(startFromSeconds: 90, durationSeconds: 5400, remembersPosition: false))
    XCTAssertNil(
      PutioVideoResumePrompt(startFromSeconds: 0, durationSeconds: 5400, remembersPosition: true))
    XCTAssertNil(
      PutioVideoResumePrompt(startFromSeconds: 90, durationSeconds: nil, remembersPosition: true))
    XCTAssertNil(
      PutioVideoResumePrompt(startFromSeconds: 90, durationSeconds: 0, remembersPosition: true))
    XCTAssertNil(
      PutioVideoResumePrompt(
        startFromSeconds: 90, durationSeconds: .infinity, remembersPosition: true))
  }

  func testChoicesStartAtThePositionOrTheBeginningAndPreviewTheirProgress() throws {
    let prompt = try XCTUnwrap(
      PutioVideoResumePrompt(startFromSeconds: 1350, durationSeconds: 5400, remembersPosition: true)
    )
    XCTAssertEqual(prompt.startSeconds(for: .resume), 1350)
    XCTAssertEqual(prompt.startSeconds(for: .startOver), 0)
    XCTAssertEqual(prompt.progress(for: .resume), 0.25, accuracy: 0.0001)
    XCTAssertEqual(prompt.progress(for: .startOver), 0)
  }

  func testProgressNeverOverflowsWhenThePositionPassesTheDuration() throws {
    let prompt = try XCTUnwrap(
      PutioVideoResumePrompt(startFromSeconds: 600, durationSeconds: 590, remembersPosition: true))
    XCTAssertEqual(prompt.progress(for: .resume), 1)
  }

  func testResumeTitleUsesClockTimeAndVoiceOverHearsADuration() throws {
    let short = try XCTUnwrap(
      PutioVideoResumePrompt(startFromSeconds: 1931, durationSeconds: 5400, remembersPosition: true)
    )
    XCTAssertEqual(short.resumeTitle, "Continue from 0:32:11")
    XCTAssertEqual(short.resumeAccessibilityLabel, "Continue from 32 minutes, 11 seconds")
    let long = try XCTUnwrap(
      PutioVideoResumePrompt(startFromSeconds: 3725, durationSeconds: 7200, remembersPosition: true)
    )
    XCTAssertEqual(long.resumeTitle, "Continue from 1:02:05")
    XCTAssertEqual(PutioVideoResumePrompt.startOverTitle, "Start from the beginning")
  }
}

final class PutioVideoStartTests: XCTestCase {
  func testAsksOnlyForAPositionAboveZeroAndBelowTheWatchedMarkWithTheSettingOn() {
    func asks(_ saved: Int, _ duration: Double?, remembers: Bool = true) -> Bool {
      PutioVideoStart.asksWhereToStart(
        savedSeconds: saved, durationSeconds: duration, remembersPosition: remembers)
    }
    XCTAssertFalse(asks(0, 5400), "no saved position")
    XCTAssertTrue(asks(1122, 5400), "mid-file")
    XCTAssertTrue(asks(5129, 5400), "just below 95%")
    XCTAssertFalse(asks(5130, 5400), "95%")
    XCTAssertFalse(asks(5184, 5400), "96%")
    XCTAssertFalse(asks(1122, 5400, remembers: false), "setting off")
    XCTAssertTrue(asks(1122, nil), "an unknown length cannot be watched")
  }

  func testStartOverPlaysFromZeroAndResumeKeepsTheSavedPosition() {
    let url = URL(string: "https://media.example.test/video.m3u8")!
    let saved = PutioPlaybackSource(url: url, startFromSeconds: 1122)
    XCTAssertEqual(PutioVideoStart.source(saved, startingWith: .resume), saved)
    XCTAssertEqual(
      PutioVideoStart.source(saved, startingWith: .startOver),
      PutioPlaybackSource(url: url, startFromSeconds: 0))
  }

  func testRouteCarriesStartOverOnly() {
    let route = PutioVideoRoute(
      id: PutioFileID(rawValue: 7), parentID: PutioFileID(rawValue: 1), title: "Movie.mkv")
    XCTAssertFalse(route.startsOver)
    XCTAssertTrue(route.starting(with: .startOver).startsOver)
    XCTAssertFalse(route.starting(with: .resume).startsOver)
  }
}

@MainActor
final class PutioVideoResumePrompterTests: XCTestCase {
  func testAnAnswerReachesTheAskerAndClosesThePrompt() async {
    let prompter = PutioVideoResumePrompter()
    let asking = Task { await prompter.ask(positionSeconds: 1122) }
    while !prompter.isAsking { await Task.yield() }
    XCTAssertEqual(prompter.positionSeconds, 1122)
    prompter.answer(.startOver)
    let choice = await asking.value
    XCTAssertEqual(choice, .startOver)
    XCTAssertFalse(prompter.isAsking)
  }

  func testDismissingOrCancellingAnswersNothing() async {
    let prompter = PutioVideoResumePrompter()
    let dismissed = Task { await prompter.ask(positionSeconds: 60) }
    while !prompter.isAsking { await Task.yield() }
    prompter.answer(nil)
    let dismissedChoice = await dismissed.value
    XCTAssertNil(dismissedChoice)

    let cancelled = Task { await prompter.ask(positionSeconds: 60) }
    while !prompter.isAsking { await Task.yield() }
    cancelled.cancel()
    let cancelledChoice = await cancelled.value
    XCTAssertNil(cancelledChoice)
    XCTAssertFalse(prompter.isAsking)
  }
}

@MainActor
final class PutioVideoPositionReporterTests: XCTestCase {
  func testSamplesOnTheTenSecondCadenceOnlyOnceReady() async throws {
    let harness = ReporterHarness()
    let reporter = harness.reporter()
    reporter.positionEstablished()
    reporter.startReporting()
    let schedule = try XCTUnwrap(harness.schedules.first)
    XCTAssertEqual(schedule.interval, .seconds(10))

    harness.position = 4
    schedule.tick()
    await harness.drain()
    XCTAssertEqual(harness.reported, [], "a sample before readiness is not a position")

    reporter.ready()
    XCTAssertEqual(harness.schedules.count, 1, "readiness keeps the running cadence")
    harness.position = 10
    schedule.tick()
    await harness.drain()
    harness.position = 20
    schedule.tick()
    await harness.drain()
    XCTAssertEqual(harness.reported, [10, 20])
  }

  func testPauseSeekAndBackgroundSaveAtOnceAndAHeldPositionIsNotSentAgain() async throws {
    let harness = ReporterHarness()
    let reporter = harness.reporter(savedPosition: 90)
    reporter.positionEstablished()
    reporter.ready()
    let schedule = try XCTUnwrap(harness.schedules.first)

    harness.position = 90
    reporter.savePosition()
    await harness.drain()
    XCTAssertEqual(harness.attempted, [], "the server already holds the start position")

    harness.position = 94
    reporter.savePosition()
    await harness.drain()
    schedule.tick()
    reporter.savePosition()
    await harness.drain()
    XCTAssertEqual(harness.attempted, [94], "a paused player saves once")

    harness.position = 300
    reporter.savePosition()
    await harness.drain()
    reporter.stop()
    await harness.drain()
    XCTAssertEqual(harness.reported, [94, 300])
  }

  func testAFailedSaveIsSentAgainOnTheNextTick() async throws {
    let harness = ReporterHarness()
    let reporter = harness.reporter()
    reporter.positionEstablished()
    reporter.ready()
    let schedule = try XCTUnwrap(harness.schedules.first)

    harness.failingSaves = 1
    harness.position = 40
    reporter.savePosition()
    await harness.drain()
    XCTAssertEqual(harness.reported, [])
    schedule.tick()
    await harness.drain()
    XCTAssertEqual(harness.attempted, [40, 40])
    XCTAssertEqual(harness.reported, [40])
  }

  func testASaveThatLandsOnTheTransientRetryIsNotSentAgain() async throws {
    let harness = ReporterHarness()
    let reporter = harness.reporter()
    reporter.positionEstablished()
    reporter.ready()
    let schedule = try XCTUnwrap(harness.schedules.first)

    harness.failingSaves = 1
    harness.saveError = .transient
    harness.position = 40
    reporter.savePosition()
    await harness.drain()
    schedule.tick()
    await harness.drain()
    XCTAssertEqual(harness.attempted, [40, 40])
    XCTAssertEqual(harness.reported, [40])
  }

  func testPlaybackFailureSavesThePositionAndEndsTheCadence() async throws {
    let harness = ReporterHarness()
    let reporter = harness.reporter()
    reporter.positionEstablished()
    reporter.ready()
    let schedule = try XCTUnwrap(harness.schedules.first)
    harness.position = 61
    reporter.playbackFailed()
    XCTAssertTrue(schedule.invalidated)
    harness.position = 70
    schedule.tick()
    reporter.stop()
    await harness.drain()
    XCTAssertEqual(harness.reported, [61])
  }

  func testAnEndThatKeepsItsPositionSavesTheWatchedMarkOnce() async {
    let harness = ReporterHarness()
    let reporter = harness.reporter(endOfPlayback: .keepsPosition)
    reporter.positionEstablished()
    reporter.ready()
    harness.position = 590
    XCTAssertTrue(reporter.playbackEnded())
    reporter.stop()
    await harness.drain()
    XCTAssertEqual(harness.reported, [590])
  }

  func testAFailedEndSaveIsSentAgainOnTheNextTick() async throws {
    let harness = ReporterHarness()
    let reporter = harness.reporter(endOfPlayback: .keepsPosition)
    reporter.positionEstablished()
    reporter.ready()
    let schedule = try XCTUnwrap(harness.schedules.first)

    harness.failingSaves = 1
    harness.position = 590
    XCTAssertTrue(reporter.playbackEnded())
    await harness.drain()
    XCTAssertEqual(harness.reported, [])
    schedule.tick()
    await harness.drain()
    XCTAssertEqual(harness.attempted, [590, 590])
    XCTAssertEqual(harness.reported, [590])
    schedule.tick()
    reporter.stop()
    await harness.drain()
    XCTAssertEqual(harness.attempted, [590, 590])
  }

  func testNoCadenceBeforeThePositionIsEstablished() {
    let harness = ReporterHarness()
    let reporter = harness.reporter()
    reporter.ready()
    XCTAssertTrue(harness.schedules.isEmpty, "a pending resume seek must not report position 0")
    reporter.positionEstablished()
    reporter.startReporting()
    XCTAssertEqual(harness.schedules.count, 1)
  }

  func testStopFlushesTheExitPositionOnceAndEndsTheCadence() async throws {
    let harness = ReporterHarness()
    let reporter = harness.reporter()
    reporter.positionEstablished()
    reporter.ready()
    let schedule = try XCTUnwrap(harness.schedules.first)
    harness.position = 42
    reporter.stop()
    reporter.stop()
    XCTAssertTrue(schedule.invalidated)
    harness.position = 50
    schedule.tick()
    await harness.drain()
    XCTAssertEqual(harness.reported, [42])
  }

  func testStopBeforeReadinessKeepsTheServerPosition() async {
    let harness = ReporterHarness()
    let reporter = harness.reporter()
    harness.position = 0
    reporter.stop()
    await harness.drain()
    XCTAssertEqual(harness.reported, [], "a teardown during the resume seek must not erase it")
  }

  func testEndResetsToZeroAndTheExitDoesNotRestoreTheDuration() async {
    let harness = ReporterHarness()
    let reporter = harness.reporter()
    reporter.positionEstablished()
    reporter.ready()
    harness.position = 590
    XCTAssertTrue(reporter.playbackEnded())
    XCTAssertFalse(reporter.playbackEnded(), "one end per pass")
    reporter.stop()
    await harness.drain()
    XCTAssertEqual(harness.reported, [0])
  }

  func testRestartAfterTheEndReportsTheNewExitPosition() async {
    let harness = ReporterHarness()
    let reporter = harness.reporter()
    reporter.positionEstablished()
    reporter.ready()
    XCTAssertTrue(reporter.playbackEnded())
    XCTAssertTrue(reporter.playbackRestarted())
    XCTAssertFalse(reporter.playbackRestarted())
    harness.position = 12
    reporter.stop()
    await harness.drain()
    XCTAssertEqual(harness.reported, [0, 12])
  }

  func testRememberPositionOffReportsNothingButStillCountsTheEnd() async {
    let harness = ReporterHarness()
    let reporter = harness.reporter(remembersPosition: false)
    reporter.positionEstablished()
    reporter.ready()
    XCTAssertTrue(harness.schedules.isEmpty)
    XCTAssertTrue(reporter.playbackEnded(), "continuation still follows the end")
    harness.position = 30
    reporter.stop()
    await harness.drain()
    XCTAssertEqual(harness.reported, [])
  }

  func testCancelEndsTheCadenceWithoutAFinalSample() async throws {
    let harness = ReporterHarness()
    let reporter = harness.reporter()
    reporter.positionEstablished()
    reporter.ready()
    harness.position = 20
    reporter.cancel()
    try XCTUnwrap(harness.schedules.first).tick()
    reporter.stop()
    await harness.drain()
    XCTAssertEqual(harness.reported, [])
  }

  func testPlayerClockReadings() {
    XCTAssertEqual(PutioVideoPositionReporter.normalizedPosition(seconds: 12.9), 12)
    XCTAssertNil(PutioVideoPositionReporter.normalizedPosition(seconds: .nan))
    XCTAssertNil(PutioVideoPositionReporter.normalizedPosition(seconds: -1))
    XCTAssertTrue(PutioVideoPositionReporter.isAtEnd(positionSeconds: 589.5, durationSeconds: 590))
    XCTAssertFalse(PutioVideoPositionReporter.isAtEnd(positionSeconds: 12, durationSeconds: 590))
    XCTAssertFalse(PutioVideoPositionReporter.isAtEnd(positionSeconds: 12, durationSeconds: .nan))
  }
}

final class PutioPlaybackProgressTests: XCTestCase {
  func testNinetyFivePercentOfTheLengthMarksWatchedAndPlaysFromTheStart() {
    XCTAssertFalse(PutioPlaybackProgress.isWatched(positionSeconds: 560, durationSeconds: 590))
    XCTAssertTrue(PutioPlaybackProgress.isWatched(positionSeconds: 561, durationSeconds: 590))
    XCTAssertTrue(PutioPlaybackProgress.isWatched(positionSeconds: 590, durationSeconds: 590))
    XCTAssertFalse(PutioPlaybackProgress.isWatched(positionSeconds: 589, durationSeconds: nil))
    XCTAssertFalse(PutioPlaybackProgress.isWatched(positionSeconds: 589, durationSeconds: .nan))
    XCTAssertEqual(PutioPlaybackProgress.startSeconds(savedSeconds: 560, durationSeconds: 590), 560)
    XCTAssertEqual(PutioPlaybackProgress.startSeconds(savedSeconds: 567, durationSeconds: 590), 0)
    XCTAssertEqual(PutioPlaybackProgress.startSeconds(savedSeconds: 567, durationSeconds: nil), 567)
    XCTAssertEqual(PutioPlaybackProgress.startSeconds(savedSeconds: 0, durationSeconds: 590), 0)
  }
}

private final class ScheduleHolder: @unchecked Sendable {
  var schedule: PutioMonotonicPositionReportSchedule?
}

@MainActor
final class PutioMonotonicPositionReportScheduleTests: XCTestCase {
  func testReleasingTheLastReferenceOffTheMainActorCancelsTheSchedule() async {
    let sleeping = expectation(description: "schedule sleeping")
    let cancelled = expectation(description: "schedule cancelled")
    let holder = ScheduleHolder()
    holder.schedule = PutioMonotonicPositionReportSchedule(
      interval: .seconds(3_600),
      sleep: { interval in
        sleeping.fulfill()
        do {
          try await Task.sleep(for: interval)
        } catch {
          cancelled.fulfill()
          throw error
        }
      },
      callback: {}
    )
    await fulfillment(of: [sleeping], timeout: 2)

    await Task.detached {
      XCTAssertFalse(Thread.isMainThread)
      holder.schedule = nil
    }.value

    await fulfillment(of: [cancelled], timeout: 2)
  }
}
