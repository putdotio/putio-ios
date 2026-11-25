import PutioCore
import SwiftUI
import XCTest

@testable import PutioTV

/// The playback state screens and the audio player as boards
/// rd-tvos-pb-13 through rd-tvos-pb-21 draw them.
@MainActor
final class TVPlaybackStatesTests: XCTestCase {
  private let viewport = CGSize(width: 1920, height: 1080)

  func testConnectionLostMatchesBaseline() throws {
    try assertFailure(.connectionLost, name: "tv-playback-connection-lost")
  }

  func testLinkExpiredMatchesBaseline() throws {
    try assertFailure(.accessExpired, name: "tv-playback-link-expired")
  }

  func testUnsupportedMatchesBaseline() throws {
    try assertFailure(.unsupported, name: "tv-playback-unsupported")
  }

  func testPlaybackErrorMatchesBaseline() throws {
    try assertFailure(.playback, name: "tv-playback-error")
  }

  func testStalledMatchesBaseline() async throws {
    HarnessSeededAPI.resetFileActions()
    let runtime = PutioRuntimeFactory.make(scenario: .signedIn)
    await runtime.session.restore()
    _ = try assertRenderingSnapshot(
      name: "tv-playback-stalled",
      view: TVPlaybackStalledScreen(
        fileName: Self.videoName, runtime: runtime, retry: {}, back: {}),
      size: viewport)
  }

  func testNowPlayingMatchesBaseline() async throws {
    let (playback, model) = await playingSession()
    _ = try assertRenderingSnapshot(
      name: "tv-audio-now-playing",
      view: TVNowPlayingView(playback: playback, model: model, onClose: {}),
      size: viewport)
  }

  func testNowPlayingPausedMatchesBaseline() async throws {
    let (playback, model) = await playingSession()
    model.pause()
    _ = try assertRenderingSnapshot(
      name: "tv-audio-now-playing-paused",
      view: TVNowPlayingView(playback: playback, model: model, onClose: {}),
      size: viewport)
  }

  func testRunningSleepTimerMatchesBaseline() async throws {
    let (playback, model) = await playingSession()
    playback.sleepTimer.start(.thirtyMinutes)
    _ = try assertRenderingSnapshot(
      name: "tv-audio-sleep-timer",
      view: TVNowPlayingView(playback: playback, model: model, onClose: {}),
      size: viewport)
  }

  func testMiniPlayerMatchesBaseline() async throws {
    let (_, model) = await playingSession()
    _ = try assertRenderingSnapshot(
      name: "tv-audio-mini-player",
      view: TVAudioMiniPlayer(model: model, onOpen: {}, onStop: {})
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
        .background(PutioTheme.Colors.background),
      size: CGSize(width: 1920, height: 200))
  }

  // MARK: Helpers

  private static let videoName = "Blue.Lights.S04E01.1080p.HDTV.H264-ORGANiC.mkv"

  private func assertFailure(
    _ failure: PutioVideoPlaybackFailure, name: String, testName: String = #function
  ) throws {
    _ = try assertRenderingSnapshot(
      name: name,
      view: TVPlaybackFailureScreen(
        failure: failure, fileID: PutioFileID(rawValue: 441), fileName: Self.videoName,
        retry: {}, back: {}),
      size: viewport, testName: testName)
  }

  /// A track 12:04 into its 54:14, in a three-track Podcasts folder.
  private func playingSession() async -> (PutioAudioPlaybackSession, PutioAudioPlayerModel) {
    let folder = PutioFileID(rawValue: 3_101)
    let queue = [
      PutioQueuedAudio(
        id: PutioFileID(rawValue: 3_102), parentID: folder,
        name: "FFTT Tree Rings October 6, 2026.mp3"),
      PutioQueuedAudio(
        id: PutioFileID(rawValue: 3_103), parentID: folder,
        name: "FFTT Tree Rings October 23, 2026.mp3"),
      PutioQueuedAudio(
        id: PutioFileID(rawValue: 3_104), parentID: folder,
        name: "FFTT Tree Rings November 9, 2026.mp3"),
    ]
    let track = PutioAudioTrack(id: queue[1].id, parentID: folder, title: queue[1].name)
    let suite = "io.put.tests.tv-audio-states"
    let defaults = UserDefaults(suiteName: suite) ?? .standard
    defaults.removePersistentDomain(forName: suite)
    let model = PutioAudioPlayerModel(
      track: track,
      engine: FixedAudioEngine(elapsed: 724, duration: 3_254),
      nowPlaying: SilentNowPlaying(),
      audioSession: SilentAudioSession(),
      sessionEvents: SilentAudioSessionEvents(),
      speedStore: PutioAudioSpeedStore(defaults: defaults),
      positionPipeline: PutioPlaybackPositionPipeline(),
      remembersPlaybackPosition: { false },
      reportPosition: { _, _ in },
      resolve: { _ in
        PutioPlaybackSource(url: URL(fileURLWithPath: "/dev/null"), startFromSeconds: 0)
      },
      loadNeighbours: { track in
        PutioAudioNeighbours(of: track.id, in: queue, folderName: "Podcasts")
      })
    let playback = PutioAudioPlaybackSession(sleepTimer: PutioAudioSleepTimer(clock: StillClock()))
    playback.present(model)
    await model.start()
    for _ in 0..<50 where model.neighbours == nil || model.elapsedSeconds != 724 {
      await Task.yield()
    }
    XCTAssertEqual(model.elapsedSeconds, 724)
    XCTAssertTrue(model.isPlaying)
    return (playback, model)
  }
}

@MainActor
private final class FixedAudioEngine: PutioAudioEngine {
  var onReady: (@MainActor (Int) -> Void)?
  var onEnded: (@MainActor () -> Void)?
  var onFailed: (@MainActor () -> Void)?
  var onPositionChanged: (@MainActor (Int) -> Void)?
  var onPlayingChanged: (@MainActor (Bool) -> Void)?
  private(set) var durationSeconds: Int?
  private let elapsed: Int
  private let duration: Int

  init(elapsed: Int, duration: Int) {
    self.elapsed = elapsed
    self.duration = duration
  }

  func load(url: URL, startFromSeconds: Int) { durationSeconds = duration }
  func play(rate: Float) {
    Task { @MainActor in
      onReady?(elapsed)
      onPositionChanged?(elapsed)
    }
  }
  func pause() { onPlayingChanged?(false) }
  func seek(to seconds: Int) {}
  func setRate(_ rate: Float) {}
  func stop() {}
}

@MainActor
private final class SilentNowPlaying: PutioNowPlayingSurface {
  func publish(_ info: PutioNowPlayingInfo) {}
  func clear() {}
  func setCommandHandler(_ handler: @escaping @MainActor (PutioRemoteAudioCommand) -> Void) {}
  func setTrackCommands(previous: Bool, next: Bool) {}
  func detachCommands() {}
}

@MainActor
private final class SilentAudioSession: PutioAudioSessioning {
  func activate() throws {}
  func deactivate() {}
}

@MainActor
private final class SilentAudioSessionEvents: PutioAudioSessionEvents {
  func start(_ handler: @escaping @MainActor (PutioAudioSessionEvent) -> Void) {}
  func stop() {}
}

@MainActor
private final class StillClock: PutioSleepTimerClock {
  var now: ContinuousClock.Instant { .now }
  func sleep(until deadline: ContinuousClock.Instant) async throws {
    try await Task.sleep(for: .seconds(3_600))
  }
}
