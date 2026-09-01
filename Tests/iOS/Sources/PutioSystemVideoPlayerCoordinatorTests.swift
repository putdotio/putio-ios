import AVFoundation
import AVKit
import Foundation
import PutioCore
import XCTest

@testable import Putio

@MainActor
private final class VideoPlayerDriverSpy: PutioVideoPlayerDriving {
  let player: AVPlayer
  private(set) var events: [String] = []
  private var seekCompletion: (@Sendable (Bool) -> Void)?

  init(item: AVPlayerItem) {
    player = AVPlayer(playerItem: item)
  }

  func play() {
    events.append("play")
  }

  func seek(to _: CMTime, completion: @escaping @Sendable (Bool) -> Void) {
    events.append("seek")
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
  func testCurrentResumeSeekPlaysOnlyAfterCompletion() async throws {
    let audioSession = PlaybackAudioSessionSpy()
    let (coordinator, capture) = makeCoordinator(audioSession: audioSession)
    let controller = AVPlayerViewController()

    coordinator.start(source: source(startFromSeconds: 90), in: controller) {}
    let driver = try XCTUnwrap(capture.driver)

    XCTAssertEqual(audioSession.events, ["activate"])
    XCTAssertEqual(driver.events, ["seek"])
    XCTAssertTrue(controller.player === driver.player)

    driver.completeSeek(true)
    await Task.yield()

    XCTAssertEqual(driver.events, ["seek", "play"])
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

  private func makeCoordinator(
    audioSession: PlaybackAudioSessionSpy,
    statusObservation: PlayerItemStatusObservationSpy? = nil,
    notificationCenter: NotificationCenter = NotificationCenter()
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
      notificationCenter: notificationCenter
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
