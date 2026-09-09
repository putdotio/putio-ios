import AVFoundation
import Foundation
import PutioCore
import XCTest

@testable import Putio

@MainActor
private final class AudioEngineSpy: PutioAudioEngine {
  var onReady: (@MainActor () -> Void)?
  var onEnded: (@MainActor () -> Void)?
  var onFailed: (@MainActor () -> Void)?
  var onPositionChanged: (@MainActor (Int) -> Void)?
  var elapsedSeconds = 0
  var durationSeconds: Int? = 240
  private(set) var events: [String] = []

  func load(url: URL, startFromSeconds: Int) {
    events.append("load:\(url.lastPathComponent)@\(startFromSeconds)")
  }
  func play(rate: Float) { events.append("play:\(rate)") }
  func pause() { events.append("pause") }
  func seek(to seconds: Int) { events.append("seek:\(seconds)") }
  func setRate(_ rate: Float) { events.append("rate:\(rate)") }
  func stop() { events.append("stop") }
}

@MainActor
private final class NowPlayingSpy: PutioNowPlayingSurface {
  private(set) var published: [PutioNowPlayingInfo] = []
  private(set) var clearCount = 0
  private var handler: (@MainActor (PutioRemoteAudioCommand) -> Void)?

  func publish(_ info: PutioNowPlayingInfo) { published.append(info) }
  func clear() { clearCount += 1 }
  func setCommandHandler(_ handler: @escaping @MainActor (PutioRemoteAudioCommand) -> Void) {
    self.handler = handler
  }
  func send(_ command: PutioRemoteAudioCommand) { handler?(command) }
}

@MainActor
private final class AudioSessionSpy: PutioAudioSessioning {
  var activationError: Error?
  private(set) var events: [String] = []
  func activate() throws {
    events.append("activate")
    if let activationError { throw activationError }
  }
  func deactivate() { events.append("deactivate") }
}

@MainActor
private final class ReportRecorder {
  private(set) var reports: [(PutioFileID, Int)] = []
  func report(_ fileID: PutioFileID, _ seconds: Int) async throws {
    reports.append((fileID, seconds))
  }
}

@MainActor
final class PutioAudioPlayerModelTests: XCTestCase {
  private let track = PutioAudioTrack(
    id: PutioFileID(rawValue: 430), parentID: .root, title: "Track.m4a")
  private let successor = PutioNextAudio(
    id: PutioFileID(rawValue: 431), parentID: .root, name: "Track 2.m4a")

  private struct Harness {
    let model: PutioAudioPlayerModel
    let engine: AudioEngineSpy
    let nowPlaying: NowPlayingSpy
    let session: AudioSessionSpy
    let reports: ReportRecorder
    let center: NotificationCenter
    let pipeline: PutioPlaybackPositionPipeline
  }

  private func makeHarness(
    defaults: UserDefaults = UserDefaults(suiteName: UUID().uuidString)!,
    resolve: @escaping PutioAudioResolve = { id in
      PutioPlaybackSource(
        url: URL(string: "https://media.example.test/\(id.rawValue).m4a?oauth_token=secret")!,
        startFromSeconds: 12)
    },
    loadNext: PutioNextAudioLoad? = nil
  ) -> Harness {
    let engine = AudioEngineSpy()
    let nowPlaying = NowPlayingSpy()
    let session = AudioSessionSpy()
    let reports = ReportRecorder()
    let center = NotificationCenter()
    let pipeline = PutioPlaybackPositionPipeline()
    let successor = successor
    let model = PutioAudioPlayerModel(
      track: track,
      engine: engine,
      nowPlaying: nowPlaying,
      audioSession: session,
      speedStore: PutioAudioSpeedStore(defaults: defaults),
      positionPipeline: pipeline,
      notificationCenter: center,
      reportPosition: { try await reports.report($0, $1) },
      resolve: resolve,
      loadNext: loadNext ?? { id in id.rawValue == 430 ? successor : nil }
    )
    return Harness(
      model: model, engine: engine, nowPlaying: nowPlaying, session: session,
      reports: reports, center: center, pipeline: pipeline)
  }

  func testStartResolvesActivatesSessionAndPlaysFromSavedPosition() async {
    let h = makeHarness()

    await h.model.start()

    XCTAssertEqual(h.model.state, .playing(track))
    XCTAssertEqual(h.session.events, ["activate"])
    XCTAssertEqual(h.engine.events, ["load:430.m4a@12", "play:1.0"])
    XCTAssertEqual(h.nowPlaying.published.last?.title, "Track.m4a")
    XCTAssertEqual(h.nowPlaying.published.last?.rate, 1)
    XCTAssertEqual(h.model.elapsedSeconds, 12)
  }

  func testResolutionFailureIsTypedAndRetryRecovers() async {
    var attempts = 0
    let h = makeHarness(resolve: { id in
      attempts += 1
      if attempts == 1 { throw PutioRuntimeError.transient }
      return PutioPlaybackSource(
        url: URL(string: "https://m.test/\(id.rawValue)")!, startFromSeconds: 0)
    })

    await h.model.start()
    guard case .failed(_, let failure) = h.model.state else {
      return XCTFail("expected a typed failure")
    }
    XCTAssertEqual(failure.kind, .transient)
    XCTAssertEqual(h.nowPlaying.clearCount, 1)

    await h.model.retry()
    XCTAssertEqual(h.model.state, .playing(track))
  }

  func testPauseReportsPositionAndResumeContinuesAtTheChosenSpeed() async {
    let h = makeHarness()
    await h.model.start()
    h.model.setSpeed(.faster)
    h.engine.onPositionChanged?(40)

    h.model.pause()
    await h.pipeline.waitForPendingReports(fileID: track.id)

    XCTAssertEqual(h.model.state, .paused(track))
    XCTAssertEqual(h.reports.reports.map(\.1), [40])
    XCTAssertEqual(h.nowPlaying.published.last?.rate, 0)

    h.model.resume()
    XCTAssertEqual(h.model.state, .playing(track))
    XCTAssertEqual(h.engine.events.last, "play:1.25")
    XCTAssertEqual(h.nowPlaying.published.last?.rate, 1.25)
  }

  func testSpeedPersistsAcrossModelsAndAppliesImmediately() async {
    let defaults = UserDefaults(suiteName: UUID().uuidString)!
    let first = makeHarness(defaults: defaults)
    await first.model.start()
    first.model.setSpeed(.fastest)
    XCTAssertEqual(first.engine.events.last, "rate:2.0")

    let second = makeHarness(defaults: defaults)
    XCTAssertEqual(second.model.speed, .fastest)
    await second.model.start()
    XCTAssertEqual(second.engine.events.last, "play:2.0")
  }

  func testPositionReportsFollowTheCadenceWhilePlaying() async {
    let h = makeHarness()
    await h.model.start()
    for seconds in [13, 20, 27, 28, 44, 45] {
      h.engine.onPositionChanged?(seconds)
    }
    await h.pipeline.waitForPendingReports(fileID: track.id)

    XCTAssertEqual(h.reports.reports.map(\.1), [27, 44])
  }

  func testEndOfTrackResetsPositionThenAdvancesToTheSuccessor() async {
    let h = makeHarness()
    await h.model.start()
    h.engine.onPositionChanged?(200)

    h.engine.onEnded?()
    while h.model.state
      != .playing(PutioAudioTrack(id: successor.id, parentID: .root, title: successor.name))
    {
      await Task.yield()
    }
    await h.pipeline.waitForPendingReports(fileID: track.id)

    XCTAssertEqual(h.reports.reports.map(\.1), [200, 0])
    XCTAssertEqual(h.engine.events.suffix(2), ["load:431.m4a@12", "play:1.0"])
    XCTAssertNil(h.model.advancingTo)
  }

  func testEndOfFolderEndsWithoutLoadingAnotherSource() async {
    let h = makeHarness(loadNext: { _ in nil })
    await h.model.start()

    h.engine.onEnded?()
    while h.model.state != .ended(track) { await Task.yield() }

    XCTAssertEqual(h.engine.events.filter { $0.hasPrefix("load") }.count, 1)
    XCTAssertEqual(h.nowPlaying.published.last?.rate, 0)

    h.model.togglePlayPause()
    while h.model.state != .playing(track) { await Task.yield() }
    XCTAssertEqual(h.engine.events.last(where: { $0.hasPrefix("load") }), "load:430.m4a@0")
  }

  func testInterruptionPausesAndResumesOnlyWhenTheSystemAsks() async {
    let h = makeHarness()
    await h.model.start()

    h.center.post(
      name: AVAudioSession.interruptionNotification, object: nil,
      userInfo: [AVAudioSessionInterruptionTypeKey: AVAudioSession.InterruptionType.began.rawValue])
    XCTAssertEqual(h.model.state, .interrupted(track))
    XCTAssertEqual(h.engine.events.last, "pause")

    h.center.post(
      name: AVAudioSession.interruptionNotification, object: nil,
      userInfo: [
        AVAudioSessionInterruptionTypeKey: AVAudioSession.InterruptionType.ended.rawValue,
        AVAudioSessionInterruptionOptionKey: UInt(0),
      ])
    XCTAssertEqual(h.model.state, .paused(track))

    h.model.resume()
    h.center.post(
      name: AVAudioSession.interruptionNotification, object: nil,
      userInfo: [AVAudioSessionInterruptionTypeKey: AVAudioSession.InterruptionType.began.rawValue])
    h.center.post(
      name: AVAudioSession.interruptionNotification, object: nil,
      userInfo: [
        AVAudioSessionInterruptionTypeKey: AVAudioSession.InterruptionType.ended.rawValue,
        AVAudioSessionInterruptionOptionKey:
          AVAudioSession.InterruptionOptions.shouldResume.rawValue,
      ])
    XCTAssertEqual(h.model.state, .playing(track))
  }

  func testUnpluggingHeadphonesPausesInsteadOfPlayingAloud() async {
    let h = makeHarness()
    await h.model.start()

    h.center.post(
      name: AVAudioSession.routeChangeNotification, object: nil,
      userInfo: [
        AVAudioSessionRouteChangeReasonKey:
          AVAudioSession.RouteChangeReason.oldDeviceUnavailable.rawValue
      ])

    XCTAssertEqual(h.model.state, .paused(track))
  }

  func testRemoteCommandsDriveTheTransport() async {
    let h = makeHarness()
    await h.model.start()

    h.nowPlaying.send(.pause)
    XCTAssertEqual(h.model.state, .paused(track))
    h.nowPlaying.send(.play)
    XCTAssertEqual(h.model.state, .playing(track))
    h.nowPlaying.send(.seek(seconds: 500))
    XCTAssertEqual(h.engine.events.last, "seek:240")
    h.nowPlaying.send(.toggle)
    XCTAssertEqual(h.model.state, .paused(track))
  }

  func testStopReportsFinalPositionClearsNowPlayingAndReleasesTheSession() async {
    let h = makeHarness()
    await h.model.start()
    h.engine.onPositionChanged?(90)

    h.model.stop()
    await h.pipeline.waitForPendingReports(fileID: track.id)

    XCTAssertEqual(h.reports.reports.map(\.1), [90])
    XCTAssertEqual(h.engine.events.last, "stop")
    XCTAssertEqual(h.nowPlaying.clearCount, 1)
    XCTAssertEqual(h.session.events, ["activate", "deactivate"])
  }

  func testSessionActivationFailureIsARecoverablePlaybackFailure() async {
    let h = makeHarness()
    h.session.activationError = AudioSessionSpy.Failure.activation

    await h.model.start()

    XCTAssertEqual(h.model.state, .failed(track, .playback))
    XCTAssertTrue(h.engine.events.isEmpty)
  }
}

extension AudioSessionSpy {
  fileprivate enum Failure: Error { case activation }
}
