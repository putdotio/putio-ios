import AVFoundation
import AVKit
import PutioCore
import SwiftUI
import XCTest

@testable import PutioTV

@MainActor
private final class ReportedPositions {
  private(set) var reports: [(PutioFileID, Int)] = []

  func record(_ fileID: PutioFileID, _ seconds: Int) {
    reports.append((fileID, seconds))
  }
}

/// The system player as the TV app drives it, against the bundled HLS
/// fixtures over loopback HTTP.
@MainActor
final class TVPlaybackTests: XCTestCase {
  private let viewport = CGSize(width: 1920, height: 1080)

  /// put.io shapes the subtitle renditions from the account: the first one
  /// `DEFAULT` with auto-selection on, none `DEFAULT` with it off, and none
  /// at all while subtitles are hidden. Applying that default changes only
  /// the subtitle group, whichever audio track is playing.
  func testDefaultSubtitleFollowsEachServerShapeWithoutMovingTheAudio() async throws {
    let (server, base) = try await serveMedia()
    defer { server.stop() }
    for (manifest, expected) in [
      ("multi-subtitles", "en"), ("multi-subtitles-unselected", "off"),
      ("multi-subtitles-hidden", "unavailable"),
    ] {
      let item = AVPlayerItem(url: base.appending(path: "multi-audio/\(manifest).m3u8"))
      let player = AVPlayer(playerItem: item)
      player.appliesMediaSelectionCriteriaAutomatically = false
      await waitUntil("\(manifest) ready") { item.status == .readyToPlay }
      let audibleGroup = try await item.asset.loadMediaSelectionGroup(for: .audible)
      let audible = try XCTUnwrap(audibleGroup)
      let turkish = try XCTUnwrap(
        audible.options.first { TVMediaSelection.languageCode(of: $0) == "tr" })
      item.select(turkish, in: audible)

      await TVVideoPlayerCoordinator.selectDefaultSubtitle(in: item)

      await waitUntil("\(manifest) subtitle") {
        await TVMediaSelection.current(in: item).subtitle == expected
      }
      let selection = await TVMediaSelection.current(in: item)
      XCTAssertEqual(selection.subtitle, expected, manifest)
      XCTAssertEqual(selection.audio, "tr", "\(manifest): the subtitle default moved the audio")
      player.replaceCurrentItem(with: nil)
    }
  }

  /// Continue seeks to the saved position before playing; leaving flushes
  /// the position the viewer reached.
  func testResumeStartsAtTheSavedPositionAndLeavingReportsTheExitPosition() async throws {
    let (server, base) = try await serveMedia()
    defer { server.stop() }
    let reported = ReportedPositions()
    let pipeline = PutioPlaybackPositionPipeline()
    let (coordinator, controller, probes) = try await startPlayer(
      base: base, startSeconds: 120, remembersPosition: true, pipeline: pipeline,
      reported: reported)
    let player = try XCTUnwrap(coordinator.player)
    await waitUntil("resumed") { CMTimeGetSeconds(player.currentTime()) >= 120 }
    XCTAssertTrue(probes.isReady)

    coordinator.stop(controller: controller)
    await pipeline.waitForPendingReports(fileID: Self.fileID)
    XCTAssertEqual(reported.reports.map(\.0), [Self.fileID])
    XCTAssertGreaterThanOrEqual(reported.reports.first?.1 ?? 0, 120)
  }

  /// Start from the beginning plays from zero and still reports; an account
  /// that does not remember positions reports nothing.
  func testStartOverPlaysFromZeroAndRememberOffReportsNothing() async throws {
    let (server, base) = try await serveMedia()
    defer { server.stop() }
    for remembers in [true, false] {
      let reported = ReportedPositions()
      let pipeline = PutioPlaybackPositionPipeline()
      let (coordinator, controller, _) = try await startPlayer(
        base: base, startSeconds: 0, remembersPosition: remembers, pipeline: pipeline,
        reported: reported)
      let player = try XCTUnwrap(coordinator.player)
      XCTAssertLessThan(CMTimeGetSeconds(player.currentTime()), 5)
      coordinator.stop(controller: controller)
      await pipeline.waitForPendingReports(fileID: Self.fileID)
      if remembers {
        XCTAssertEqual(reported.reports.count, 1)
        XCTAssertLessThan(reported.reports.first?.1 ?? 99, 5)
      } else {
        XCTAssertTrue(reported.reports.isEmpty, "remember-position off must not report")
      }
    }
  }

  /// The native speed control lists the system rates; the chosen rate is the
  /// one playback resumes at after a pause and keeps through a seek, and a
  /// new playback starts at 1x.
  func testSpeedControlOffersTheSystemRatesAndHoldsThroughPauseAndSeek() async throws {
    let (server, base) = try await serveMedia()
    defer { server.stop() }
    let (coordinator, controller, _) = try await startPlayer(
      base: base, startSeconds: 0, remembersPosition: false,
      pipeline: PutioPlaybackPositionPipeline(), reported: ReportedPositions())
    let player = try XCTUnwrap(coordinator.player)
    XCTAssertEqual(controller.speeds.map(\.rate), [2, 1.5, 1.25, 1, 0.5])
    XCTAssertEqual(player.defaultRate, 1)

    let faster = try XCTUnwrap(controller.speeds.first { $0.rate == 1.5 })
    controller.selectSpeed(faster)
    await waitUntil("1.5x") { player.rate == 1.5 }
    XCTAssertEqual(controller.selectedSpeed?.rate, 1.5)

    player.pause()
    await waitUntil("paused") { player.rate == 0 }
    player.play()
    await waitUntil("resumed at 1.5x") { player.rate == 1.5 }

    let seeked = expectation(description: "seeked")
    player.seek(to: CMTime(seconds: 60, preferredTimescale: 600)) { _ in seeked.fulfill() }
    await fulfillment(of: [seeked], timeout: 15)
    await waitUntil("1.5x after the seek") { player.rate == 1.5 }
    XCTAssertEqual(controller.selectedSpeed?.rate, 1.5)
    coordinator.stop(controller: controller)

    let (next, nextController, _) = try await startPlayer(
      base: base, startSeconds: 0, remembersPosition: false,
      pipeline: PutioPlaybackPositionPipeline(), reported: ReportedPositions())
    XCTAssertEqual(next.player?.defaultRate, 1, "a new playback starts at 1x")
    XCTAssertEqual(nextController.selectedSpeed?.rate, 1)
    next.stop(controller: nextController)
  }

  func testResumePromptMatchesBaseline() throws {
    let prompt = try XCTUnwrap(
      PutioVideoResumePrompt(startFromSeconds: 1931, durationSeconds: 3330, remembersPosition: true)
    )
    _ = try assertRenderingSnapshot(
      name: "tv-playback-resume",
      view: TVResumePromptView(
        fileName: "The.Wire.S03E04.Back.Burners.1080p.BluRay.x264-DEMAND.mkv", prompt: prompt
      ) { _ in },
      size: viewport)
  }

  /// The preview follows the focused choice: none watched from the start.
  func testResumePromptStartOverPreviewMatchesBaseline() throws {
    let prompt = try XCTUnwrap(
      PutioVideoResumePrompt(startFromSeconds: 1931, durationSeconds: 3330, remembersPosition: true)
    )
    _ = try assertRenderingSnapshot(
      name: "tv-playback-resume-start-over",
      view: TVResumePromptView(
        fileName: "The.Wire.S03E04.Back.Burners.1080p.BluRay.x264-DEMAND.mkv", prompt: prompt,
        initialChoice: .startOver
      ) { _ in },
      size: viewport)
  }

  func testConversionProgressMatchesBaseline() throws {
    _ = try assertRenderingSnapshot(
      name: "tv-playback-converting",
      view: TVConversionStatusView(state: .converting(progress: 0.35))
        .environment(\.locale, Locale(identifier: "en_US"))
        .background(Color.black),
      size: viewport)
  }

  func testUpNextMatchesBaseline() throws {
    _ = try assertRenderingSnapshot(
      name: "tv-playback-up-next",
      view: TVUpNextView(
        nextVideo: PutioNextVideo(
          id: PutioFileID(rawValue: 414), parentID: .root, name: "Root Movie 2.mkv"),
        autoplaySecondsRemaining: 3, onPlay: {}, onCancel: {}),
      size: viewport)
  }

  // MARK: Helpers

  private static let fileID = PutioFileID(rawValue: 412)

  private func serveMedia() async throws -> (LoopbackMediaServer, URL) {
    let playlist = try XCTUnwrap(
      Bundle.main.url(
        forResource: "runtime-proof", withExtension: "m3u8", subdirectory: "HarnessMedia"))
    let server = try LoopbackMediaServer(directory: playlist.deletingLastPathComponent())
    return (server, try await server.start())
  }

  /// Starts the 590-second fixture and waits until the player is ready at
  /// its start position.
  private func startPlayer(
    base: URL, startSeconds: Int, remembersPosition: Bool,
    pipeline: PutioPlaybackPositionPipeline, reported: ReportedPositions
  ) async throws -> (TVVideoPlayerCoordinator, AVPlayerViewController, TVPlaybackProbes) {
    let coordinator = TVVideoPlayerCoordinator()
    let controller = AVPlayerViewController()
    let probes = TVPlaybackProbes()
    coordinator.start(
      item: AVPlayerItem(url: base.appending(path: "runtime-proof.m3u8")),
      fileID: Self.fileID, startSeconds: startSeconds, remembersPosition: remembersPosition,
      pipeline: pipeline, reportPosition: { reported.record($0, $1) }, in: controller,
      probes: probes, onFailure: { XCTFail("playback failed") })
    await waitUntil("player ready") { probes.isReady }
    return (coordinator, controller, probes)
  }

  private func waitUntil(
    _ what: String, timeout: Duration = .seconds(30),
    file: StaticString = #filePath, line: UInt = #line,
    _ condition: @MainActor () async -> Bool
  ) async {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
      if await condition() { return }
      try? await Task.sleep(for: .milliseconds(100))
    }
    if await condition() { return }
    XCTFail("timed out waiting for \(what)", file: file, line: line)
  }
}
