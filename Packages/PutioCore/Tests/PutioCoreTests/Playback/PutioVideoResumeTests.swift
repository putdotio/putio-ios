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
  let pipeline = PutioPlaybackPositionPipeline()
  let fileID = PutioFileID(rawValue: 7)

  func reporter(remembersPosition: Bool = true) -> PutioVideoPositionReporter {
    PutioVideoPositionReporter(
      fileID: fileID,
      remembersPosition: remembersPosition,
      pipeline: pipeline,
      report: { [weak self] _, seconds in self?.reported.append(seconds) },
      currentPosition: { [weak self] in self?.position },
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

@MainActor
final class PutioVideoPositionReporterTests: XCTestCase {
  func testSamplesOnTheFifteenSecondCadenceOnlyOnceReady() async throws {
    let harness = ReporterHarness()
    let reporter = harness.reporter()
    reporter.positionEstablished()
    reporter.startReporting()
    let schedule = try XCTUnwrap(harness.schedules.first)
    XCTAssertEqual(schedule.interval, .seconds(15))

    harness.position = 4
    schedule.tick()
    await harness.drain()
    XCTAssertEqual(harness.reported, [], "a sample before readiness is not a position")

    reporter.ready()
    XCTAssertEqual(harness.schedules.count, 1, "readiness keeps the running cadence")
    harness.position = 15
    schedule.tick()
    await harness.drain()
    harness.position = 30
    schedule.tick()
    await harness.drain()
    XCTAssertEqual(harness.reported, [15, 30])
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
