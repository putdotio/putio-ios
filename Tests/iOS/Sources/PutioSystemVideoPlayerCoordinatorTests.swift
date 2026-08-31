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
  private(set) var seekTime: CMTime?
  private(set) var timeObservation: PlayerTimeObservationSpy?
  private var seekCompletion: (@Sendable (Bool) -> Void)?

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

  func observeTime(
    every interval: CMTime,
    using callback: @escaping @MainActor @Sendable (CMTime) -> Void
  ) -> any PutioPlayerTimeObservation {
    events.append("observe-time")
    let observation = PlayerTimeObservationSpy(interval: interval, callback: callback)
    timeObservation = observation
    return observation
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
}

@MainActor
private final class PlayerTimeObservationSpy: PutioPlayerTimeObservation {
  let interval: CMTime
  private(set) var invalidationCount = 0
  private let callback: @MainActor @Sendable (CMTime) -> Void

  init(interval: CMTime, callback: @escaping @MainActor @Sendable (CMTime) -> Void) {
    self.interval = interval
    self.callback = callback
  }

  func invalidate() {
    invalidationCount += 1
  }

  func emit(seconds: Double) {
    callback(CMTime(seconds: seconds, preferredTimescale: 600))
  }

  func emit(_ time: CMTime) {
    callback(time)
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
    completed.append((fileID, position))
  }

  func releaseFirstReport() {
    firstReportContinuation?.resume()
    firstReportContinuation = nil
  }
}

@MainActor
private final class PlaybackPositionClockSpy {
  private(set) var instant = ContinuousClock.now

  func advance(by duration: Duration) {
    instant = instant.advanced(by: duration)
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

    XCTAssertEqual(driver.events, ["seek", "observe-time", "play"])
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
    XCTAssertNil(driver.timeObservation)
    XCTAssertTrue(reports.started.isEmpty)
  }

  func testReadyPlayerSamplesOnExactFifteenSecondInterval() async throws {
    let audioSession = PlaybackAudioSessionSpy()
    let statusObservation = PlayerItemStatusObservationSpy()
    let clock = PlaybackPositionClockSpy()
    let (coordinator, capture) = makeCoordinator(
      audioSession: audioSession,
      statusObservation: statusObservation,
      positionReportNow: { clock.instant }
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
    XCTAssertNil(driver.timeObservation)

    statusObservation.emit(.readyToPlay)
    await Task.yield()
    let timeObservation = try XCTUnwrap(driver.timeObservation)
    XCTAssertEqual(CMTimeGetSeconds(timeObservation.interval), 15)

    timeObservation.emit(seconds: 0)
    clock.advance(by: .seconds(14))
    timeObservation.emit(seconds: 120)
    await Task.yield()
    XCTAssertTrue(reports.started.isEmpty)

    clock.advance(by: .seconds(1))
    timeObservation.emit(seconds: 15.9)
    await coordinator.waitForPendingPositionReports()

    XCTAssertEqual(reports.completed.map(\.0), [fileID])
    XCTAssertEqual(reports.completed.map(\.1), [15])

    timeObservation.emit(seconds: 300)
    await Task.yield()
    XCTAssertEqual(reports.completed.map(\.1), [15])
    driver.currentTime = .invalid
    coordinator.stop(controller: controller)
    await coordinator.waitForPendingPositionReports()
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
    let observation = try XCTUnwrap(capture.driver?.timeObservation)

    observation.emit(.invalid)
    observation.emit(.indefinite)
    observation.emit(seconds: -1)
    observation.emit(seconds: Double(Int.max))
    await Task.yield()

    XCTAssertTrue(reports.started.isEmpty)
    capture.driver?.currentTime = .invalid
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
    let timeObservation = try XCTUnwrap(driver.timeObservation)
    driver.currentTime = CMTime(seconds: 44.8, preferredTimescale: 600)

    coordinator.stop(controller: controller)
    coordinator.stop(controller: controller)
    timeObservation.emit(seconds: 60)
    await coordinator.waitForPendingPositionReports()

    XCTAssertEqual(reports.completed.map(\.1), [44])
    XCTAssertEqual(timeObservation.invalidationCount, 1)
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
    driver.currentTime = CMTime(seconds: 8, preferredTimescale: 600)
    notificationCenter.post(name: AVPlayerItem.timeJumpedNotification, object: item)
    coordinator.stop(controller: controller)
    await coordinator.waitForPendingPositionReports()

    XCTAssertEqual(reports.completed.map(\.1), [0, 8])
  }

  func testReportsRemainOrderedAndFailureDoesNotBecomePlaybackFailure() async throws {
    let audioSession = PlaybackAudioSessionSpy()
    let statusObservation = PlayerItemStatusObservationSpy()
    let clock = PlaybackPositionClockSpy()
    let (coordinator, capture) = makeCoordinator(
      audioSession: audioSession,
      statusObservation: statusObservation,
      positionReportNow: { clock.instant }
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
    let timeObservation = try XCTUnwrap(driver.timeObservation)
    clock.advance(by: .seconds(15))
    timeObservation.emit(seconds: 15)
    clock.advance(by: .seconds(15))
    timeObservation.emit(seconds: 30)
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
    positionPipeline: PutioPlaybackPositionPipeline? = nil,
    positionReportNow: PutioSystemVideoPlayerCoordinator.PositionReportNow? = nil
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
      positionReportNow: positionReportNow ?? { ContinuousClock.now }
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
