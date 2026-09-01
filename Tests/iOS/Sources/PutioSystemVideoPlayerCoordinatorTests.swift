import AVFoundation
import AVKit
import Foundation
import PutioCore
import XCTest

@testable import Putio

@MainActor
private final class VideoPlayerDriverSpy: PutioVideoPlayerDriving {
  let player: AVPlayer
  var currentTime: CMTime = .zero
  private(set) var events: [String] = []
  private(set) var positionObservationIntervals: [CMTime] = []
  private(set) var positionObservationRemovalCount = 0
  private(set) var seekTime: CMTime?
  private var seekCompletion: (@Sendable (Bool) -> Void)?
  private var positionChanged: (@Sendable (CMTime) -> Void)?

  init(item: AVPlayerItem) {
    player = AVPlayer(playerItem: item)
  }

  func play() {
    events.append("play")
  }

  func seek(to time: CMTime, completion: @escaping @Sendable (Bool) -> Void) {
    events.append("seek")
    seekTime = time
    seekCompletion = completion
  }

  func stop() {
    events.append("stop")
    player.currentItem?.cancelPendingSeeks()
    player.pause()
    player.replaceCurrentItem(with: nil)
  }

  func completeSeek(_ finished: Bool) {
    seekCompletion?(finished)
  }

  func observePosition(
    every interval: CMTime,
    callback: @escaping @Sendable (CMTime) -> Void
  ) -> Any {
    positionObservationIntervals.append(interval)
    positionChanged = callback
    return NSObject()
  }

  func removePositionObservation(_ observation: Any) {
    positionObservationRemovalCount += 1
    positionChanged = nil
  }

  func emitPosition(_ time: CMTime) {
    positionChanged?(time)
  }
}

@MainActor
private final class PositionReportScheduleSpy: PutioPositionReportSchedule {
  let interval: Duration
  private(set) var invalidationCount = 0
  private let callback: @MainActor @Sendable () -> Void

  init(interval: Duration, callback: @escaping @MainActor @Sendable () -> Void) {
    self.interval = interval
    self.callback = callback
  }

  func invalidate() {
    invalidationCount += 1
  }

  func tick() {
    callback()
  }
}

@MainActor
private final class ControlledScheduleSleep {
  private struct Request {
    let duration: Duration
    let continuation: CheckedContinuation<Void, any Error>
  }

  private var requests: [Request] = []

  var durations: [Duration] {
    requests.map(\.duration)
  }

  func callAsFunction(_ duration: Duration) async throws {
    try await withCheckedThrowingContinuation { continuation in
      requests.append(Request(duration: duration, continuation: continuation))
    }
  }

  func resumeRequest(at index: Int) {
    requests[index].continuation.resume()
  }
}

@MainActor
private final class PlaybackPositionReportSpy {
  enum Failure: Error {
    case rejected
  }

  private(set) var started: [(PutioFileID, Int)] = []
  private(set) var completed: [(PutioFileID, Int)] = []
  var blocksFirstReport = false
  var failsFirstReport = false
  var firstReportError: Error?
  private var firstReportContinuation: CheckedContinuation<Void, Never>?

  func report(fileID: PutioFileID, position: Int) async throws {
    started.append((fileID, position))
    if blocksFirstReport, started.count == 1 {
      await withCheckedContinuation { continuation in
        firstReportContinuation = continuation
      }
    }
    if failsFirstReport, started.count == 1 {
      throw Failure.rejected
    }
    if let firstReportError, started.count == 1 {
      throw firstReportError
    }
    completed.append((fileID, position))
  }

  func releaseFirstReport() {
    firstReportContinuation?.resume()
    firstReportContinuation = nil
  }
}

@MainActor
private final class PlaybackAudioSessionSpy: PutioPlaybackAudioSessioning {
  enum Failure: Error {
    case activation
  }

  var activationError: Error?
  private(set) var events: [String] = []

  func activate() throws {
    events.append("activate")
    if let activationError { throw activationError }
  }

  func deactivate() {
    events.append("deactivate")
  }
}

@MainActor
private final class VideoPlayerDriverCapture {
  var driver: VideoPlayerDriverSpy?
  var item: AVPlayerItem?
  var positionReportSchedule: PositionReportScheduleSpy?
}

@MainActor
private final class PlayerItemStatusObservationSpy: PutioPlayerItemStatusObservation {
  private(set) var invalidationCount = 0
  var statusChanged: (@Sendable (AVPlayerItem.Status) -> Void)?

  func invalidate() {
    invalidationCount += 1
  }

  func emit(_ status: AVPlayerItem.Status) {
    statusChanged?(status)
  }
}

@MainActor
final class PutioSystemVideoPlayerCoordinatorTests: XCTestCase {
  private let fileID = PutioFileID(rawValue: 411)

  func testProductionPositionScheduleRepeatsOnTheMonotonicIntervalAndInvalidates() async {
    let sleep = ControlledScheduleSleep()
    var callbackCount = 0
    let schedule = PutioMonotonicPositionReportSchedule(
      interval: .seconds(15),
      sleep: { try await sleep($0) },
      callback: { callbackCount += 1 }
    )

    while sleep.durations.count < 1 {
      await Task.yield()
    }
    XCTAssertEqual(sleep.durations, [.seconds(15)])
    XCTAssertEqual(callbackCount, 0)

    sleep.resumeRequest(at: 0)
    while callbackCount < 1 || sleep.durations.count < 2 {
      await Task.yield()
    }
    XCTAssertEqual(sleep.durations, [.seconds(15), .seconds(15)])
    XCTAssertEqual(callbackCount, 1)

    schedule.invalidate()
    sleep.resumeRequest(at: 1)
    for _ in 0..<10 {
      await Task.yield()
    }
    XCTAssertEqual(sleep.durations, [.seconds(15), .seconds(15)])
    XCTAssertEqual(callbackCount, 1)
  }

  func testPlaybackPositionObservationIsHarnessOnlyBoundedAndRemoved() async throws {
    let productionStatus = PlayerItemStatusObservationSpy()
    let (productionCoordinator, productionCapture) = makeCoordinator(
      audioSession: PlaybackAudioSessionSpy(),
      statusObservation: productionStatus
    )
    let productionController = AVPlayerViewController()
    productionCoordinator.start(
      fileID: fileID,
      source: source(startFromSeconds: 0),
      in: productionController,
      onFailure: {}
    )
    let productionDriver = try XCTUnwrap(productionCapture.driver)

    XCTAssertTrue(productionDriver.positionObservationIntervals.isEmpty)
    productionCoordinator.stop(controller: productionController)
    XCTAssertEqual(productionDriver.positionObservationRemovalCount, 0)

    let harnessStatus = PlayerItemStatusObservationSpy()
    let (harnessCoordinator, harnessCapture) = makeCoordinator(
      audioSession: PlaybackAudioSessionSpy(),
      statusObservation: harnessStatus
    )
    let harnessController = AVPlayerViewController()
    var positions: [Int] = []
    harnessCoordinator.start(
      fileID: fileID,
      source: source(startFromSeconds: 0),
      in: harnessController,
      observesPlaybackState: true,
      onPositionChanged: { positions.append($0) },
      onFailure: {}
    )
    let harnessDriver = try XCTUnwrap(harnessCapture.driver)

    XCTAssertEqual(harnessDriver.positionObservationIntervals.count, 1)
    XCTAssertEqual(harnessDriver.positionObservationIntervals[0].seconds, 0.25, accuracy: 0.001)
    harnessDriver.emitPosition(CMTime(seconds: 91.9, preferredTimescale: 600))
    for time in [
      CMTime.invalid,
      .indefinite,
      .positiveInfinity,
      .negativeInfinity,
      CMTime(seconds: -1, preferredTimescale: 600),
      CMTime(seconds: Double(Int.max), preferredTimescale: 1),
    ] {
      harnessDriver.emitPosition(time)
    }
    await Task.yield()
    XCTAssertEqual(positions, [91])

    harnessCoordinator.stop(controller: harnessController)
    XCTAssertEqual(harnessDriver.positionObservationRemovalCount, 1)
    harnessDriver.emitPosition(CMTime(seconds: 92, preferredTimescale: 600))
    await Task.yield()
    XCTAssertEqual(positions, [91])
  }

  func testCurrentResumeSeekPlaysOnlyAfterCompletion() async throws {
    let audioSession = PlaybackAudioSessionSpy()
    let (coordinator, capture) = makeCoordinator(audioSession: audioSession)
    let controller = AVPlayerViewController()

    coordinator.start(source: source(startFromSeconds: 90), in: controller) {}
    let driver = try XCTUnwrap(capture.driver)

    XCTAssertEqual(audioSession.events, ["activate"])
    XCTAssertEqual(driver.events, ["seek"])
    XCTAssertEqual(CMTimeGetSeconds(try XCTUnwrap(driver.seekTime)), 90)
    XCTAssertTrue(controller.player === driver.player)

    driver.completeSeek(true)
    await Task.yield()

    XCTAssertEqual(driver.events, ["seek", "play"])
    XCTAssertEqual(capture.positionReportSchedule?.interval, .seconds(15))
    coordinator.stop(controller: controller)
  }

  func testInterruptedCurrentResumeSeekReportsRecoverableFailure() async throws {
    let audioSession = PlaybackAudioSessionSpy()
    let (coordinator, capture) = makeCoordinator(audioSession: audioSession)
    let controller = AVPlayerViewController()
    var failures = 0

    coordinator.start(source: source(startFromSeconds: 90), in: controller) {
      failures += 1
    }
    let driver = try XCTUnwrap(capture.driver)

    driver.completeSeek(false)
    await Task.yield()

    XCTAssertEqual(driver.events, ["seek"])
    XCTAssertEqual(failures, 1)
    coordinator.stop(controller: controller)
  }

  func testStoppedResumeSeekCannotRestartDetachedPlayer() async throws {
    let audioSession = PlaybackAudioSessionSpy()
    let (coordinator, capture) = makeCoordinator(audioSession: audioSession)
    let controller = AVPlayerViewController()
    var failures = 0

    coordinator.start(source: source(startFromSeconds: 90), in: controller) {
      failures += 1
    }
    let driver = try XCTUnwrap(capture.driver)
    coordinator.stop(controller: controller)

    XCTAssertNil(controller.player)
    XCTAssertNil(driver.player.currentItem)
    XCTAssertEqual(driver.events, ["seek", "stop"])
    XCTAssertEqual(audioSession.events, ["activate", "deactivate"])

    driver.completeSeek(false)
    await Task.yield()

    XCTAssertEqual(driver.events, ["seek", "stop"])
    XCTAssertEqual(failures, 0)
  }

  func testResumeSeekCannotStartPlaybackAfterPlayerFailure() async throws {
    let audioSession = PlaybackAudioSessionSpy()
    let statusObservation = PlayerItemStatusObservationSpy()
    let (coordinator, capture) = makeCoordinator(
      audioSession: audioSession,
      statusObservation: statusObservation
    )
    let controller = AVPlayerViewController()
    var failures = 0

    coordinator.start(source: source(startFromSeconds: 90), in: controller) {
      failures += 1
    }
    let driver = try XCTUnwrap(capture.driver)

    statusObservation.emit(.failed)
    await Task.yield()
    driver.completeSeek(true)
    await Task.yield()

    XCTAssertEqual(failures, 1)
    XCTAssertEqual(driver.events, ["seek"])
    coordinator.stop(controller: controller)
  }

  func testFailedToEndReportsOnceForExactItemAndStopsObservingOnTeardown() async throws {
    let notificationCenter = NotificationCenter()
    let audioSession = PlaybackAudioSessionSpy()
    let (coordinator, capture) = makeCoordinator(
      audioSession: audioSession,
      notificationCenter: notificationCenter
    )
    let controller = AVPlayerViewController()
    var failures = 0

    coordinator.start(source: source(startFromSeconds: 0), in: controller) {
      failures += 1
    }
    let driver = try XCTUnwrap(capture.driver)
    let item = try XCTUnwrap(capture.item)
    XCTAssertEqual(driver.events, ["play"])

    notificationCenter.post(
      name: AVPlayerItem.failedToPlayToEndTimeNotification,
      object: AVPlayerItem(url: URL(string: "https://example.test/unrelated.m3u8")!)
    )
    await Task.yield()
    XCTAssertEqual(failures, 0)

    notificationCenter.post(name: AVPlayerItem.failedToPlayToEndTimeNotification, object: item)
    notificationCenter.post(name: AVPlayerItem.failedToPlayToEndTimeNotification, object: item)
    await Task.yield()
    XCTAssertEqual(failures, 1)

    coordinator.stop(controller: controller)
    notificationCenter.post(name: AVPlayerItem.failedToPlayToEndTimeNotification, object: item)
    await Task.yield()
    XCTAssertEqual(failures, 1)
  }

  func testItemStatusFailureReportsOnceAndIgnoresNonFailures() async throws {
    let audioSession = PlaybackAudioSessionSpy()
    let statusObservation = PlayerItemStatusObservationSpy()
    let (coordinator, capture) = makeCoordinator(
      audioSession: audioSession,
      statusObservation: statusObservation
    )
    let controller = AVPlayerViewController()
    var failures = 0

    coordinator.start(source: source(startFromSeconds: 0), in: controller) {
      failures += 1
    }
    _ = try XCTUnwrap(capture.driver)

    statusObservation.emit(.unknown)
    statusObservation.emit(.readyToPlay)
    await Task.yield()
    XCTAssertEqual(failures, 0)

    statusObservation.emit(.failed)
    statusObservation.emit(.failed)
    await Task.yield()
    XCTAssertEqual(failures, 1)

    coordinator.stop(controller: controller)
    XCTAssertEqual(statusObservation.invalidationCount, 1)
  }

  func testItemReadyReportsOnceAndCannotEscapeAfterTeardown() async {
    let audioSession = PlaybackAudioSessionSpy()
    let statusObservation = PlayerItemStatusObservationSpy()
    let (coordinator, _) = makeCoordinator(
      audioSession: audioSession,
      statusObservation: statusObservation
    )
    let controller = AVPlayerViewController()
    var ready = 0

    coordinator.start(
      source: source(startFromSeconds: 0),
      in: controller,
      onReady: { ready += 1 },
      onFailure: {}
    )
    statusObservation.emit(.readyToPlay)
    statusObservation.emit(.readyToPlay)
    await Task.yield()

    XCTAssertEqual(ready, 1)

    coordinator.stop(controller: controller)
    statusObservation.emit(.readyToPlay)
    await Task.yield()

    XCTAssertEqual(ready, 1)
  }

  func testStoppedItemStatusFailureCannotReportFromCapturedCallback() async {
    let audioSession = PlaybackAudioSessionSpy()
    let statusObservation = PlayerItemStatusObservationSpy()
    let (coordinator, _) = makeCoordinator(
      audioSession: audioSession,
      statusObservation: statusObservation
    )
    let controller = AVPlayerViewController()
    var failures = 0

    coordinator.start(source: source(startFromSeconds: 0), in: controller) {
      failures += 1
    }
    coordinator.stop(controller: controller)
    statusObservation.emit(.failed)
    await Task.yield()

    XCTAssertEqual(statusObservation.invalidationCount, 1)
    XCTAssertEqual(failures, 0)
  }

  func testAudioSessionActivationFailureUsesPlayerFailureBoundary() async throws {
    let audioSession = PlaybackAudioSessionSpy()
    audioSession.activationError = PlaybackAudioSessionSpy.Failure.activation
    let (coordinator, capture) = makeCoordinator(audioSession: audioSession)
    let controller = AVPlayerViewController()
    var failures = 0

    coordinator.start(source: source(startFromSeconds: 0), in: controller) {
      failures += 1
    }
    let driver = try XCTUnwrap(capture.driver)

    XCTAssertEqual(failures, 0)
    await Task.yield()
    XCTAssertEqual(failures, 1)
    XCTAssertTrue(driver.events.isEmpty)
    coordinator.stop(controller: controller)
    XCTAssertEqual(audioSession.events, ["activate"])
  }

  func testStoppedActivationFailureCannotReportAfterDeferredDelivery() async {
    let audioSession = PlaybackAudioSessionSpy()
    audioSession.activationError = PlaybackAudioSessionSpy.Failure.activation
    let (coordinator, _) = makeCoordinator(audioSession: audioSession)
    let controller = AVPlayerViewController()
    var failures = 0

    coordinator.start(source: source(startFromSeconds: 0), in: controller) {
      failures += 1
    }
    coordinator.stop(controller: controller)
    await Task.yield()

    XCTAssertEqual(failures, 0)
    XCTAssertNil(controller.player)
    XCTAssertEqual(audioSession.events, ["activate"])
  }

  func testRememberPositionOffSkipsResumeObservationAndFinalReport() async throws {
    let audioSession = PlaybackAudioSessionSpy()
    let statusObservation = PlayerItemStatusObservationSpy()
    let (coordinator, capture) = makeCoordinator(
      audioSession: audioSession,
      statusObservation: statusObservation
    )
    let controller = AVPlayerViewController()
    let reports = PlaybackPositionReportSpy()

    coordinator.start(
      fileID: fileID,
      source: source(startFromSeconds: 90),
      remembersPlaybackPosition: false,
      reportPosition: { try await reports.report(fileID: $0, position: $1) },
      in: controller,
      onFailure: {}
    )
    let driver = try XCTUnwrap(capture.driver)
    statusObservation.emit(.readyToPlay)
    await Task.yield()
    driver.currentTime = CMTime(seconds: 42, preferredTimescale: 600)

    coordinator.stop(controller: controller)
    await coordinator.waitForPendingPositionReports()

    XCTAssertEqual(driver.events, ["play", "stop"])
    XCTAssertNil(capture.positionReportSchedule)
    XCTAssertTrue(reports.started.isEmpty)
  }

  func testRememberPositionOffStillReportsPlaybackCompletion() async throws {
    let notificationCenter = NotificationCenter()
    let statusObservation = PlayerItemStatusObservationSpy()
    let (coordinator, capture) = makeCoordinator(
      audioSession: PlaybackAudioSessionSpy(),
      statusObservation: statusObservation,
      notificationCenter: notificationCenter
    )
    let controller = AVPlayerViewController()
    let reports = PlaybackPositionReportSpy()
    var completionCount = 0

    coordinator.start(
      fileID: fileID,
      source: source(startFromSeconds: 0),
      remembersPlaybackPosition: false,
      reportPosition: { try await reports.report(fileID: $0, position: $1) },
      in: controller,
      onPlaybackEnded: { completionCount += 1 },
      onFailure: {}
    )
    let item = try XCTUnwrap(capture.item)
    statusObservation.emit(.readyToPlay)
    await Task.yield()

    notificationCenter.post(name: AVPlayerItem.didPlayToEndTimeNotification, object: item)
    notificationCenter.post(name: AVPlayerItem.didPlayToEndTimeNotification, object: item)
    coordinator.stop(controller: controller)
    await coordinator.waitForPendingPositionReports()

    XCTAssertEqual(completionCount, 1)
    XCTAssertTrue(reports.started.isEmpty)
  }

  func testReadyPlayerSamplesOnExactFifteenSecondInterval() async throws {
    let audioSession = PlaybackAudioSessionSpy()
    let statusObservation = PlayerItemStatusObservationSpy()
    let (coordinator, capture) = makeCoordinator(
      audioSession: audioSession,
      statusObservation: statusObservation
    )
    let controller = AVPlayerViewController()
    let reports = PlaybackPositionReportSpy()

    coordinator.start(
      fileID: fileID,
      source: source(startFromSeconds: 0),
      remembersPlaybackPosition: true,
      reportPosition: { try await reports.report(fileID: $0, position: $1) },
      in: controller,
      onFailure: {}
    )
    let driver = try XCTUnwrap(capture.driver)
    XCTAssertNil(capture.positionReportSchedule)

    statusObservation.emit(.readyToPlay)
    await Task.yield()
    let schedule = try XCTUnwrap(capture.positionReportSchedule)
    XCTAssertEqual(schedule.interval, .seconds(15))

    driver.currentTime = CMTime(seconds: 15.9, preferredTimescale: 600)
    schedule.tick()
    await coordinator.waitForPendingPositionReports()

    XCTAssertEqual(reports.completed.map(\.0), [fileID])
    XCTAssertEqual(reports.completed.map(\.1), [15])

    driver.currentTime = CMTime(seconds: 300, preferredTimescale: 600)
    schedule.tick()
    await coordinator.waitForPendingPositionReports()
    XCTAssertEqual(reports.completed.map(\.1), [15, 300])
    driver.currentTime = .invalid
    coordinator.stop(controller: controller)
    await coordinator.waitForPendingPositionReports()
  }

  func testMonotonicScheduleSamplesCurrentPositionAtNonUnitPlaybackRates() async throws {
    let statusObservation = PlayerItemStatusObservationSpy()
    let (coordinator, capture) = makeCoordinator(
      audioSession: PlaybackAudioSessionSpy(),
      statusObservation: statusObservation
    )
    let controller = AVPlayerViewController()
    let reports = PlaybackPositionReportSpy()

    coordinator.start(
      fileID: fileID,
      source: source(startFromSeconds: 0),
      reportPosition: { try await reports.report(fileID: $0, position: $1) },
      in: controller,
      onFailure: {}
    )
    let driver = try XCTUnwrap(capture.driver)
    statusObservation.emit(.readyToPlay)
    await Task.yield()
    let schedule = try XCTUnwrap(capture.positionReportSchedule)

    driver.currentTime = CMTime(seconds: 7.5, preferredTimescale: 600)
    schedule.tick()
    await coordinator.waitForPendingPositionReports()
    driver.currentTime = CMTime(seconds: 30, preferredTimescale: 600)
    schedule.tick()
    await coordinator.waitForPendingPositionReports()

    XCTAssertEqual(reports.completed.map(\.1), [7, 30])
    driver.currentTime = .invalid
    coordinator.stop(controller: controller)
  }

  func testInvalidPeriodicPositionsAreIgnored() async throws {
    let audioSession = PlaybackAudioSessionSpy()
    let statusObservation = PlayerItemStatusObservationSpy()
    let (coordinator, capture) = makeCoordinator(
      audioSession: audioSession,
      statusObservation: statusObservation
    )
    let controller = AVPlayerViewController()
    let reports = PlaybackPositionReportSpy()

    coordinator.start(
      fileID: fileID,
      source: source(startFromSeconds: 0),
      remembersPlaybackPosition: true,
      reportPosition: { try await reports.report(fileID: $0, position: $1) },
      in: controller,
      onFailure: {}
    )
    statusObservation.emit(.readyToPlay)
    await Task.yield()
    let driver = try XCTUnwrap(capture.driver)
    let schedule = try XCTUnwrap(capture.positionReportSchedule)

    for time in [CMTime.invalid, .indefinite, CMTime(seconds: -1, preferredTimescale: 600)] {
      driver.currentTime = time
      schedule.tick()
    }
    driver.currentTime = CMTime(seconds: Double(Int.max), preferredTimescale: 600)
    schedule.tick()
    await Task.yield()

    XCTAssertTrue(reports.started.isEmpty)
    driver.currentTime = .invalid
    coordinator.stop(controller: controller)
    await coordinator.waitForPendingPositionReports()
    XCTAssertTrue(reports.started.isEmpty)
  }

  func testTeardownBeforeResumeSeekCompletesDoesNotEraseServerPosition() async throws {
    let audioSession = PlaybackAudioSessionSpy()
    let statusObservation = PlayerItemStatusObservationSpy()
    let (coordinator, capture) = makeCoordinator(
      audioSession: audioSession,
      statusObservation: statusObservation
    )
    let controller = AVPlayerViewController()
    let reports = PlaybackPositionReportSpy()

    coordinator.start(
      fileID: fileID,
      source: source(startFromSeconds: 90),
      remembersPlaybackPosition: true,
      reportPosition: { try await reports.report(fileID: $0, position: $1) },
      in: controller,
      onFailure: {}
    )
    let driver = try XCTUnwrap(capture.driver)
    statusObservation.emit(.readyToPlay)
    await Task.yield()
    driver.currentTime = .zero

    coordinator.stop(controller: controller)
    await coordinator.waitForPendingPositionReports()

    XCTAssertTrue(reports.started.isEmpty)
  }

  func testTeardownCapturesFinalPositionOnceBeforeStoppingAndRejectsStaleSamples() async throws {
    let audioSession = PlaybackAudioSessionSpy()
    let statusObservation = PlayerItemStatusObservationSpy()
    let (coordinator, capture) = makeCoordinator(
      audioSession: audioSession,
      statusObservation: statusObservation
    )
    let controller = AVPlayerViewController()
    let reports = PlaybackPositionReportSpy()

    coordinator.start(
      fileID: fileID,
      source: source(startFromSeconds: 0),
      remembersPlaybackPosition: true,
      reportPosition: { try await reports.report(fileID: $0, position: $1) },
      in: controller,
      onFailure: {}
    )
    let driver = try XCTUnwrap(capture.driver)
    statusObservation.emit(.readyToPlay)
    await Task.yield()
    let schedule = try XCTUnwrap(capture.positionReportSchedule)
    driver.currentTime = CMTime(seconds: 44.8, preferredTimescale: 600)

    coordinator.stop(controller: controller)
    coordinator.stop(controller: controller)
    driver.currentTime = CMTime(seconds: 60, preferredTimescale: 600)
    schedule.tick()
    await coordinator.waitForPendingPositionReports()

    XCTAssertEqual(reports.completed.map(\.1), [44])
    XCTAssertEqual(schedule.invalidationCount, 1)
    XCTAssertEqual(driver.events.last, "stop")
  }

  func testPlaybackCompletionResetsPositionAndTeardownDoesNotRestoreTheDuration() async throws {
    let notificationCenter = NotificationCenter()
    let statusObservation = PlayerItemStatusObservationSpy()
    let (coordinator, capture) = makeCoordinator(
      audioSession: PlaybackAudioSessionSpy(),
      statusObservation: statusObservation,
      notificationCenter: notificationCenter
    )
    let controller = AVPlayerViewController()
    let reports = PlaybackPositionReportSpy()

    coordinator.start(
      fileID: fileID,
      source: source(startFromSeconds: 0),
      reportPosition: { try await reports.report(fileID: $0, position: $1) },
      in: controller,
      onFailure: {}
    )
    let driver = try XCTUnwrap(capture.driver)
    let item = try XCTUnwrap(capture.item)
    statusObservation.emit(.readyToPlay)
    await Task.yield()
    driver.currentTime = CMTime(seconds: 120, preferredTimescale: 600)

    notificationCenter.post(name: AVPlayerItem.didPlayToEndTimeNotification, object: item)
    coordinator.stop(controller: controller)
    await coordinator.waitForPendingPositionReports()

    XCTAssertEqual(reports.completed.map(\.1), [0])
  }

  func testReplayAfterCompletionReportsTheNewExitPosition() async throws {
    let notificationCenter = NotificationCenter()
    let statusObservation = PlayerItemStatusObservationSpy()
    let (coordinator, capture) = makeCoordinator(
      audioSession: PlaybackAudioSessionSpy(),
      statusObservation: statusObservation,
      notificationCenter: notificationCenter
    )
    let controller = AVPlayerViewController()
    let reports = PlaybackPositionReportSpy()
    reports.blocksFirstReport = true
    var restartCount = 0

    coordinator.start(
      fileID: fileID,
      source: source(startFromSeconds: 0),
      reportPosition: { try await reports.report(fileID: $0, position: $1) },
      in: controller,
      onPlaybackRestarted: { restartCount += 1 },
      onFailure: {}
    )
    let driver = try XCTUnwrap(capture.driver)
    let item = try XCTUnwrap(capture.item)
    statusObservation.emit(.readyToPlay)
    await Task.yield()
    let schedule = try XCTUnwrap(capture.positionReportSchedule)
    driver.currentTime = CMTime(seconds: 15, preferredTimescale: 600)
    schedule.tick()
    notificationCenter.post(name: AVPlayerItem.timeJumpedNotification, object: item)
    XCTAssertEqual(restartCount, 0)
    while reports.started.isEmpty {
      await Task.yield()
    }
    driver.currentTime = CMTime(seconds: 120, preferredTimescale: 600)

    notificationCenter.post(name: AVPlayerItem.didPlayToEndTimeNotification, object: item)
    driver.currentTime = CMTime(seconds: 8, preferredTimescale: 600)
    notificationCenter.post(name: AVPlayerItem.timeJumpedNotification, object: item)
    coordinator.stop(controller: controller)
    reports.releaseFirstReport()
    await coordinator.waitForPendingPositionReports()

    XCTAssertEqual(restartCount, 1)
    XCTAssertEqual(reports.completed.map(\.1), [15, 0, 8])
  }

  func testReplayWaitsForTransientEOFResetRetryBeforeReportingTheNewPosition() async throws {
    let notificationCenter = NotificationCenter()
    let statusObservation = PlayerItemStatusObservationSpy()
    let (coordinator, capture) = makeCoordinator(
      audioSession: PlaybackAudioSessionSpy(),
      statusObservation: statusObservation,
      notificationCenter: notificationCenter
    )
    let controller = AVPlayerViewController()
    let reports = PlaybackPositionReportSpy()
    reports.blocksFirstReport = true
    reports.firstReportError = PutioRuntimeError.transient

    coordinator.start(
      fileID: fileID,
      source: source(startFromSeconds: 0),
      reportPosition: { try await reports.report(fileID: $0, position: $1) },
      in: controller,
      onFailure: {}
    )
    let driver = try XCTUnwrap(capture.driver)
    let item = try XCTUnwrap(capture.item)
    statusObservation.emit(.readyToPlay)
    await Task.yield()
    driver.currentTime = CMTime(seconds: 120, preferredTimescale: 600)

    notificationCenter.post(name: AVPlayerItem.didPlayToEndTimeNotification, object: item)
    while reports.started.isEmpty {
      await Task.yield()
    }
    driver.currentTime = CMTime(seconds: 8, preferredTimescale: 600)
    notificationCenter.post(name: AVPlayerItem.timeJumpedNotification, object: item)
    coordinator.stop(controller: controller)
    reports.releaseFirstReport()
    await coordinator.waitForPendingPositionReports()

    XCTAssertEqual(reports.started.map(\.1), [0, 0, 8])
    XCTAssertEqual(reports.completed.map(\.1), [0, 8])
  }

  func testReportsRemainOrderedAndFailureDoesNotBecomePlaybackFailure() async throws {
    let audioSession = PlaybackAudioSessionSpy()
    let statusObservation = PlayerItemStatusObservationSpy()
    let (coordinator, capture) = makeCoordinator(
      audioSession: audioSession,
      statusObservation: statusObservation
    )
    let controller = AVPlayerViewController()
    let reports = PlaybackPositionReportSpy()
    reports.blocksFirstReport = true
    reports.failsFirstReport = true
    var playbackFailures = 0

    coordinator.start(
      fileID: fileID,
      source: source(startFromSeconds: 0),
      remembersPlaybackPosition: true,
      reportPosition: { try await reports.report(fileID: $0, position: $1) },
      in: controller,
      onFailure: { playbackFailures += 1 }
    )
    let driver = try XCTUnwrap(capture.driver)
    statusObservation.emit(.readyToPlay)
    await Task.yield()
    let schedule = try XCTUnwrap(capture.positionReportSchedule)
    driver.currentTime = CMTime(seconds: 15, preferredTimescale: 600)
    schedule.tick()
    driver.currentTime = CMTime(seconds: 30, preferredTimescale: 600)
    schedule.tick()
    driver.currentTime = CMTime(seconds: 37, preferredTimescale: 600)
    coordinator.stop(controller: controller)

    while reports.started.isEmpty {
      await Task.yield()
    }
    XCTAssertEqual(reports.started.map(\.1), [15])
    reports.releaseFirstReport()
    await coordinator.waitForPendingPositionReports()

    XCTAssertEqual(reports.started.map(\.1), [15, 37])
    XCTAssertEqual(reports.completed.map(\.1), [37])
    XCTAssertEqual(playbackFailures, 0)
  }

  func testTransientFinalReportRetriesOnceBeforeThePipelineDrains() async throws {
    let statusObservation = PlayerItemStatusObservationSpy()
    let (coordinator, capture) = makeCoordinator(
      audioSession: PlaybackAudioSessionSpy(),
      statusObservation: statusObservation
    )
    let controller = AVPlayerViewController()
    let reports = PlaybackPositionReportSpy()
    reports.firstReportError = PutioRuntimeError.transient

    coordinator.start(
      fileID: fileID,
      source: source(startFromSeconds: 0),
      reportPosition: { try await reports.report(fileID: $0, position: $1) },
      in: controller,
      onFailure: {}
    )
    let driver = try XCTUnwrap(capture.driver)
    statusObservation.emit(.readyToPlay)
    await Task.yield()
    driver.currentTime = CMTime(seconds: 44, preferredTimescale: 600)

    coordinator.stop(controller: controller)
    await coordinator.waitForPendingPositionReports()

    XCTAssertEqual(reports.started.map(\.1), [44, 44])
    XCTAssertEqual(reports.completed.map(\.1), [44])
  }

  func testSharedPipelineFinishesOldFinalReportBeforeReopenedPlaybackResolves() async throws {
    let pipeline = PutioPlaybackPositionPipeline()
    let reports = PlaybackPositionReportSpy()
    reports.blocksFirstReport = true

    let firstStatus = PlayerItemStatusObservationSpy()
    let (firstCoordinator, firstCapture) = makeCoordinator(
      audioSession: PlaybackAudioSessionSpy(),
      statusObservation: firstStatus,
      positionPipeline: pipeline
    )
    let firstController = AVPlayerViewController()
    firstCoordinator.start(
      fileID: fileID,
      source: source(startFromSeconds: 0),
      reportPosition: { try await reports.report(fileID: $0, position: $1) },
      in: firstController,
      onFailure: {}
    )
    firstStatus.emit(.readyToPlay)
    await Task.yield()
    firstCapture.driver?.currentTime = CMTime(seconds: 30, preferredTimescale: 600)
    firstCoordinator.stop(controller: firstController)

    while reports.started.isEmpty {
      await Task.yield()
    }
    var reopenedResolutionStarted = false
    let resolutionBarrier = Task { @MainActor in
      await pipeline.waitForPendingReports(fileID: fileID)
      reopenedResolutionStarted = true
    }
    await Task.yield()
    XCTAssertFalse(reopenedResolutionStarted)

    reports.releaseFirstReport()
    await resolutionBarrier.value
    XCTAssertTrue(reopenedResolutionStarted)
    XCTAssertEqual(reports.completed.map(\.1), [30])

    let secondStatus = PlayerItemStatusObservationSpy()
    let (secondCoordinator, secondCapture) = makeCoordinator(
      audioSession: PlaybackAudioSessionSpy(),
      statusObservation: secondStatus,
      positionPipeline: pipeline
    )
    let secondController = AVPlayerViewController()
    secondCoordinator.start(
      fileID: fileID,
      source: source(startFromSeconds: 30),
      reportPosition: { try await reports.report(fileID: $0, position: $1) },
      in: secondController,
      onFailure: {}
    )
    secondCapture.driver?.completeSeek(true)
    await Task.yield()
    secondStatus.emit(.readyToPlay)
    await Task.yield()
    secondCapture.driver?.currentTime = CMTime(seconds: 45, preferredTimescale: 600)
    secondCoordinator.stop(controller: secondController)
    await secondCoordinator.waitForPendingPositionReports()

    XCTAssertEqual(reports.completed.map(\.1), [30, 45])
  }

  private func makeCoordinator(
    audioSession: PlaybackAudioSessionSpy,
    statusObservation: PlayerItemStatusObservationSpy? = nil,
    notificationCenter: NotificationCenter = NotificationCenter(),
    positionPipeline: PutioPlaybackPositionPipeline? = nil
  ) -> (PutioSystemVideoPlayerCoordinator, VideoPlayerDriverCapture) {
    let capture = VideoPlayerDriverCapture()
    let coordinator = PutioSystemVideoPlayerCoordinator(
      makeDriver: { item in
        let driver = VideoPlayerDriverSpy(item: item)
        capture.driver = driver
        capture.item = item
        return driver
      },
      observeItemStatus: { item, statusChanged in
        guard let statusObservation else {
          return item.observe(\.status, options: [.initial, .new]) { item, _ in
            statusChanged(item.status)
          }
        }
        statusObservation.statusChanged = statusChanged
        return statusObservation
      },
      audioSession: audioSession,
      notificationCenter: notificationCenter,
      positionPipeline: positionPipeline ?? PutioPlaybackPositionPipeline(),
      schedulePositionReports: { interval, callback in
        let schedule = PositionReportScheduleSpy(interval: interval, callback: callback)
        capture.positionReportSchedule = schedule
        return schedule
      }
    )
    return (coordinator, capture)
  }

  private func source(startFromSeconds: Int) -> PutioPlaybackSource {
    PutioPlaybackSource(
      url: URL(string: "https://example.test/video.m3u8")!,
      startFromSeconds: startFromSeconds
    )
  }
}
