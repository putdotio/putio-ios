import AVFoundation
import Foundation
import MediaPlayer
import PutioCore
import UIKit
import XCTest

@testable import Putio

@MainActor
private final class AudioEngineSpy: PutioAudioEngine {
  var onReady: (@MainActor (_ startSeconds: Int) -> Void)?
  var onEnded: (@MainActor () -> Void)?
  var onFailed: (@MainActor () -> Void)?
  var onPositionChanged: (@MainActor (Int) -> Void)?
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
  private(set) var detachCount = 0
  private(set) var attachmentCount = 0
  private var handler: (@MainActor (PutioRemoteAudioCommand) -> Void)?

  func publish(_ info: PutioNowPlayingInfo) { published.append(info) }
  func clear() { clearCount += 1 }
  func detachCommands() {
    detachCount += 1
    handler = nil
  }
  func setCommandHandler(_ handler: @escaping @MainActor (PutioRemoteAudioCommand) -> Void) {
    attachmentCount += 1
    self.handler = handler
  }
  private(set) var trackCommands: (previous: Bool, next: Bool) = (false, false)
  func setTrackCommands(previous: Bool, next: Bool) { trackCommands = (previous, next) }
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
private final class SettingBox {
  var remembers = true
}

@MainActor
private final class ReportRecorder {
  private(set) var reports: [(PutioFileID, Int)] = []
  var failingReports = 0
  func report(_ fileID: PutioFileID, _ seconds: Int) async throws {
    if failingReports > 0 {
      failingReports -= 1
      throw PutioRuntimeError.transient
    }
    reports.append((fileID, seconds))
  }
}

@MainActor
private final class ReportClock {
  private(set) var intervals: [Duration] = []
  private var callbacks: [@MainActor @Sendable () -> Void] = []
  private var invalidated: Set<Int> = []

  func schedule(
    _ interval: Duration, _ callback: @escaping @MainActor @Sendable () -> Void
  ) -> any PutioPositionReportSchedule {
    intervals.append(interval)
    callbacks.append(callback)
    return Schedule(clock: self, index: callbacks.count - 1)
  }

  func tick() {
    for (index, callback) in callbacks.enumerated() where !invalidated.contains(index) {
      callback()
    }
  }

  private final class Schedule: PutioPositionReportSchedule {
    let clock: ReportClock
    let index: Int
    init(clock: ReportClock, index: Int) {
      self.clock = clock
      self.index = index
    }
    func invalidate() { clock.invalidated.insert(index) }
  }
}

@MainActor
final class PutioAudioPlayerModelTests: XCTestCase {
  /// Yields until the condition holds or a short deadline passes, so a
  /// regression fails the test instead of hanging it.
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

  private let track = PutioAudioTrack(
    id: PutioFileID(rawValue: 430), parentID: .root, title: "Track.m4a")
  private let successor = PutioQueuedAudio(
    id: PutioFileID(rawValue: 431), parentID: .root, name: "Track 2.m4a")
  private let predecessor = PutioQueuedAudio(
    id: PutioFileID(rawValue: 429), parentID: .root, name: "Track 0.m4a")

  private struct Harness {
    let model: PutioAudioPlayerModel
    let engine: AudioEngineSpy
    let nowPlaying: NowPlayingSpy
    let session: AudioSessionSpy
    let reports: ReportRecorder
    let center: NotificationCenter
    let pipeline: PutioPlaybackPositionPipeline
    let clock: ReportClock
  }

  private func makeHarness(
    defaults: UserDefaults = UserDefaults(suiteName: UUID().uuidString)!,
    resolve: @escaping PutioAudioResolve = { id in
      PutioPlaybackSource(
        url: URL(string: "https://media.example.test/\(id.rawValue).m4a?oauth_token=secret")!,
        startFromSeconds: 12)
    },
    loadNeighbours: PutioAudioNeighboursLoad? = nil,
    remembersPlaybackPosition: @escaping PutioPlaybackPositionSetting = { true }
  ) -> Harness {
    let engine = AudioEngineSpy()
    let nowPlaying = NowPlayingSpy()
    let session = AudioSessionSpy()
    let reports = ReportRecorder()
    let center = NotificationCenter()
    let pipeline = PutioPlaybackPositionPipeline()
    let clock = ReportClock()
    let successor = successor
    let current = PutioQueuedAudio(id: track.id, parentID: track.parentID, name: track.title)
    let model = PutioAudioPlayerModel(
      track: track,
      engine: engine,
      nowPlaying: nowPlaying,
      audioSession: session,
      speedStore: PutioAudioSpeedStore(defaults: defaults),
      positionPipeline: pipeline,
      remembersPlaybackPosition: remembersPlaybackPosition,
      notificationCenter: center,
      schedulePositionReports: { clock.schedule($0, $1) },
      reportPosition: { try await reports.report($0, $1) },
      resolve: resolve,
      loadNeighbours: loadNeighbours ?? { track in
        track.id == current.id
          ? PutioAudioNeighbours(next: successor, folderName: "Music")
          : PutioAudioNeighbours(previous: current, folderName: "Music")
      }
    )
    return Harness(
      model: model, engine: engine, nowPlaying: nowPlaying, session: session,
      reports: reports, center: center, pipeline: pipeline, clock: clock)
  }

  func testMinimizingAndReopeningKeepsTheSamePlaybackAndRemoteCommands() async {
    let h = makeHarness()
    let playback = PutioAudioPlaybackSession()
    defer { playback.stop() }
    playback.present(h.model)
    await waitUntil { h.model.isPlaying }
    let events = h.engine.events
    playback.isPresented = false
    h.engine.onPositionChanged?(12)
    h.engine.onPositionChanged?(24)
    XCTAssertTrue(h.model.isPlaying)
    XCTAssertEqual(h.model.elapsedSeconds, 24)
    XCTAssertTrue(playback.model === h.model)
    XCTAssertEqual(h.engine.events, events)
    h.model.togglePlayPause()
    XCTAssertFalse(h.model.isPlaying)
    playback.isPresented = true
    XCTAssertEqual(h.model.elapsedSeconds, 24)
    XCTAssertFalse(h.model.isPlaying)
    XCTAssertFalse(h.engine.events.contains("stop"))
    playback.stop()
    XCTAssertNil(playback.model)
    XCTAssertFalse(playback.isPresented)
    XCTAssertEqual(h.engine.events.last, "stop")
  }

  func testReplacingMiniPlayerStopsPreviousTrack() async {
    let first = makeHarness()
    let second = makeHarness()
    let playback = PutioAudioPlaybackSession()
    defer { playback.stop() }
    playback.present(first.model)
    await waitUntil { first.model.isPlaying }
    playback.isPresented = false
    playback.present(second.model)
    await waitUntil { second.model.isPlaying }
    XCTAssertEqual(first.engine.events.last, "stop")
    XCTAssertTrue(playback.model === second.model)
    XCTAssertTrue(playback.isPresented)
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
    // Samples before the start seek lands describe position 0, not the resume.
    h.engine.onPositionChanged?(0)
    XCTAssertEqual(h.model.elapsedSeconds, 12)
    h.engine.onPositionChanged?(12)
    h.engine.onPositionChanged?(13)
    XCTAssertEqual(h.model.elapsedSeconds, 13)
  }

  func testAccountWithoutRememberedPositionsStartsAtZeroAndNeverReports() async {
    let h = makeHarness(remembersPlaybackPosition: { false })

    await h.model.start()
    XCTAssertEqual(h.engine.events, ["load:430.m4a@0", "play:1.0"])
    for second in 1...40 { h.engine.onPositionChanged?(second) }
    h.model.pause()
    h.model.resume()
    h.model.seek(to: 90)
    h.engine.onEnded?()
    await waitUntil { h.model.track.id == successor.id && h.model.isPlaying }
    h.model.stop()
    await h.pipeline.waitForPendingReports(fileID: track.id)
    await h.pipeline.waitForPendingReports(fileID: successor.id)

    XCTAssertTrue(h.reports.reports.isEmpty)
  }

  func testRememberPositionSettingIsReadAtEveryLoadAndReport() async {
    let setting = SettingBox()
    let h = makeHarness(remembersPlaybackPosition: { setting.remembers })

    await h.model.start()
    XCTAssertEqual(h.engine.events, ["load:430.m4a@12", "play:1.0"])
    h.engine.onPositionChanged?(12)
    h.engine.onPositionChanged?(30)
    h.clock.tick()
    // Turned off after the 30 s report was queued but before it was sent.
    setting.remembers = false
    h.engine.onPositionChanged?(50)
    h.model.pause()
    h.model.resume()
    h.engine.onEnded?()
    let next = PutioAudioTrack(id: successor.id, parentID: .root, title: successor.name)
    await waitUntil { h.model.state == .playing(next) }
    await h.pipeline.waitForPendingReports(fileID: track.id)

    XCTAssertTrue(h.reports.reports.isEmpty)
    XCTAssertEqual(h.engine.events.suffix(2), ["load:431.m4a@0", "play:1.0"])
  }

  func testTurningRememberPositionOnDuringATrackSavesFromThen() async {
    let setting = SettingBox()
    setting.remembers = false
    let h = makeHarness(remembersPlaybackPosition: { setting.remembers })

    await h.model.start()
    XCTAssertEqual(h.engine.events, ["load:430.m4a@0", "play:1.0"])
    h.engine.onPositionChanged?(8)
    h.clock.tick()
    await h.pipeline.waitForPendingReports(fileID: track.id)
    setting.remembers = true
    h.engine.onPositionChanged?(30)
    h.model.pause()
    await h.pipeline.waitForPendingReports(fileID: track.id)

    XCTAssertEqual(h.reports.reports.map(\.1), [30])
  }

  func testAPositionHeldBackWhileRememberingIsOffIsSavedOnceItTurnsOn() async {
    let setting = SettingBox()
    setting.remembers = false
    let h = makeHarness(remembersPlaybackPosition: { setting.remembers })

    await h.model.start()
    h.engine.onPositionChanged?(20)
    h.model.pause()
    await h.pipeline.waitForPendingReports(fileID: track.id)
    setting.remembers = true
    h.model.stop()
    await h.pipeline.waitForPendingReports(fileID: track.id)

    XCTAssertEqual(h.reports.reports.map(\.1), [20])
  }

  func testUnstartedViewModelDoesNotRegisterOrClearRemotePlayback() {
    let h = makeHarness()

    XCTAssertEqual(h.nowPlaying.attachmentCount, 0)
    h.model.stop()

    XCTAssertEqual(h.nowPlaying.clearCount, 0)
    XCTAssertEqual(h.nowPlaying.detachCount, 0)
    XCTAssertTrue(h.engine.events.isEmpty)
  }

  func testRepeatedStartPreservesPausedPlaybackWithoutRegisteringAgain() async {
    let h = makeHarness()
    defer { h.model.stop() }
    await h.model.start()
    h.nowPlaying.send(.pause)

    await h.model.start()

    XCTAssertEqual(h.model.state, .paused(track))
    XCTAssertEqual(h.nowPlaying.attachmentCount, 1)
    XCTAssertEqual(h.engine.events.filter { $0.hasPrefix("load:") }.count, 1)
  }

  func testRestartRestoresRemoteCommandsAndHeadphoneRemovalObserver() async {
    let h = makeHarness()
    defer { h.model.stop() }
    await h.model.start()
    h.model.stop()

    await h.model.start()
    h.nowPlaying.send(.pause)
    XCTAssertEqual(h.model.state, .paused(track))
    h.nowPlaying.send(.play)
    XCTAssertEqual(h.model.state, .playing(track))
    XCTAssertEqual(h.nowPlaying.attachmentCount, 2)

    h.center.post(
      name: AVAudioSession.routeChangeNotification, object: nil,
      userInfo: [
        AVAudioSessionRouteChangeReasonKey:
          AVAudioSession.RouteChangeReason.oldDeviceUnavailable.rawValue
      ])
    await waitUntil { h.model.state == .paused(track) }
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
    h.engine.onPositionChanged?(12)
    guard case .failed(_, let failure) = h.model.state else {
      return XCTFail("expected a typed failure")
    }
    XCTAssertEqual(failure.kind, .transient)
    XCTAssertEqual(h.nowPlaying.clearCount, 1)
    XCTAssertEqual(h.nowPlaying.detachCount, 0, "a failure must keep lock-screen commands")

    await h.model.retry()
    XCTAssertEqual(h.model.state, .playing(track))
    h.nowPlaying.send(.pause)
    XCTAssertEqual(h.model.state, .paused(track))
  }

  func testPauseReportsPositionAndResumeContinuesAtTheChosenSpeed() async {
    let h = makeHarness()
    await h.model.start()
    h.engine.onPositionChanged?(12)
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
    first.engine.onPositionChanged?(12)
    first.model.setSpeed(.quadruple)
    XCTAssertEqual(first.engine.events.last, "rate:4.0")

    let second = makeHarness(defaults: defaults)
    XCTAssertEqual(second.model.speed, .quadruple)
    await second.model.start()
    second.engine.onPositionChanged?(12)
    XCTAssertEqual(second.engine.events.last, "play:4.0")
  }

  func testSpeedsSpanAQuarterToFourTimesAndTheSlowestPersists() async {
    XCTAssertEqual(
      PutioAudioSpeed.allCases.map(\.rawValue),
      [0.25, 0.5, 0.75, 1, 1.25, 1.5, 2, 2.5, 3, 3.5, 4])
    XCTAssertEqual(
      PutioAudioSpeed.allCases.map(\.title),
      ["0.25×", "0.5×", "0.75×", "1×", "1.25×", "1.5×", "2×", "2.5×", "3×", "3.5×", "4×"])
    let defaults = UserDefaults(suiteName: UUID().uuidString)!
    let first = makeHarness(defaults: defaults)
    await first.model.start()
    first.model.setSpeed(.quarter)
    XCTAssertEqual(first.engine.events.last, "rate:0.25")

    let second = makeHarness(defaults: defaults)
    XCTAssertEqual(second.model.speed, .quarter)
    XCTAssertEqual(second.model.speed.title, "0.25×")
  }

  func testSkipMovesTenSecondsWithinTheTrackFromTheTransportAndRemote() async {
    let h = makeHarness()
    await h.model.start()

    h.model.skip(by: PutioAudioPlayerModel.skipInterval)
    XCTAssertEqual(h.engine.events.last, "seek:22")
    XCTAssertEqual(h.model.elapsedSeconds, 22)
    h.model.skip(by: -PutioAudioPlayerModel.skipInterval)
    XCTAssertEqual(h.engine.events.last, "seek:12")
    h.nowPlaying.send(.skip(seconds: -10))
    XCTAssertEqual(h.engine.events.last, "seek:2")
    h.nowPlaying.send(.skip(seconds: -10))
    XCTAssertEqual(h.engine.events.last, "seek:0")
    h.model.seek(to: 235)
    h.nowPlaying.send(.skip(seconds: 10))
    XCTAssertEqual(h.engine.events.last, "seek:240")
  }

  func testSystemSurfaceOffersTenSecondSkipCommandsUntilDetached() {
    let surface = PutioSystemNowPlayingSurface()
    let center = MPRemoteCommandCenter.shared()
    surface.setCommandHandler { _ in }
    defer { surface.detachCommands() }

    for command in [center.skipBackwardCommand, center.skipForwardCommand] {
      XCTAssertTrue(command.isEnabled)
      XCTAssertEqual(command.preferredIntervals, [10])
    }
    surface.detachCommands()
    XCTAssertFalse(center.skipBackwardCommand.isEnabled)
    XCTAssertFalse(center.skipForwardCommand.isEnabled)
  }

  func testPositionSavesEveryTenSecondsOfTheClockWhilePlaying() async {
    let h = makeHarness()
    await h.model.start()
    XCTAssertEqual(h.clock.intervals, [.seconds(10)])
    h.engine.onPositionChanged?(12)
    h.clock.tick()
    for seconds in [13, 20, 22] {
      h.engine.onPositionChanged?(seconds)
    }
    h.clock.tick()
    await h.pipeline.waitForPendingReports(fileID: track.id)
    h.engine.onPositionChanged?(32)
    h.clock.tick()
    await h.pipeline.waitForPendingReports(fileID: track.id)

    XCTAssertEqual(h.reports.reports.map(\.1), [22, 32])
  }

  func testBackgroundSavesThePositionAndAFailedSaveIsRetriedOnTheNextTick() async {
    let h = makeHarness()
    await h.model.start()
    h.engine.onPositionChanged?(12)
    h.engine.onPositionChanged?(47)
    h.reports.failingReports = 2

    h.center.post(name: UIApplication.didEnterBackgroundNotification, object: nil)
    await waitUntil { h.reports.failingReports == 0 }
    await h.pipeline.waitForPendingReports(fileID: track.id)
    XCTAssertTrue(h.reports.reports.isEmpty)
    XCTAssertTrue(h.model.isPlaying, "a failed save never interrupts playback")

    h.clock.tick()
    await h.pipeline.waitForPendingReports(fileID: track.id)
    XCTAssertEqual(h.reports.reports.map(\.1), [47])
  }

  func testEngineFailureSavesThePositionItFailedAt() async {
    let h = makeHarness()
    await h.model.start()
    h.engine.onPositionChanged?(12)
    h.engine.onPositionChanged?(73)

    h.engine.onFailed?()
    h.clock.tick()
    await h.pipeline.waitForPendingReports(fileID: track.id)

    XCTAssertEqual(h.model.state, .failed(track, .playback))
    XCTAssertEqual(h.reports.reports.map(\.1), [73])
  }

  func testAWatchedTrackStartsFromTheBeginning() async {
    let h = makeHarness(resolve: { id in
      PutioPlaybackSource(
        url: URL(string: "https://media.example.test/\(id.rawValue).m4a")!, startFromSeconds: 235)
    })
    await h.model.start()
    XCTAssertEqual(h.model.elapsedSeconds, 235)

    h.engine.onReady?(0)
    XCTAssertEqual(h.model.elapsedSeconds, 0)
    h.engine.onPositionChanged?(1)
    XCTAssertEqual(h.model.elapsedSeconds, 1, "samples from the start count once it starts there")
  }

  func testASeekBeforeTheTrackIsReadyKeepsTheSeekPosition() async {
    let h = makeHarness()
    await h.model.start()

    h.model.seek(to: 100)
    h.engine.onReady?(0)
    XCTAssertEqual(h.model.elapsedSeconds, 100)
    h.engine.onPositionChanged?(0)
    XCTAssertEqual(h.model.elapsedSeconds, 100)
    h.engine.onPositionChanged?(100)
    h.engine.onPositionChanged?(101)
    XCTAssertEqual(h.model.elapsedSeconds, 101)
  }

  func testEndOfTrackSavesTheWatchedMarkThenAdvancesToTheSuccessor() async {
    let h = makeHarness()
    await h.model.start()
    h.engine.onPositionChanged?(12)
    h.engine.onPositionChanged?(200)

    h.engine.onEnded?()
    XCTAssertEqual(h.nowPlaying.published.last?.elapsedSeconds, 0)
    h.engine.onPositionChanged?(240)
    h.clock.tick()
    let next = PutioAudioTrack(id: successor.id, parentID: .root, title: successor.name)
    await waitUntil { h.model.state == .playing(next) }
    await h.pipeline.waitForPendingReports(fileID: track.id)

    XCTAssertEqual(h.reports.reports.map(\.1), [240])
    XCTAssertEqual(h.engine.events.filter { $0 == "pause" }.count, 1)
    XCTAssertEqual(h.engine.events.suffix(2), ["load:431.m4a@12", "play:1.0"])
  }

  func testAFailedEndOfTrackSaveIsSentAgainBeforeTheSuccessorLoads() async {
    let h = makeHarness()
    await h.model.start()
    h.engine.onPositionChanged?(12)
    h.engine.onPositionChanged?(200)
    h.reports.failingReports = 2

    h.engine.onEnded?()
    let next = PutioAudioTrack(id: successor.id, parentID: .root, title: successor.name)
    await waitUntil { h.model.state == .playing(next) }

    XCTAssertEqual(h.reports.reports.map(\.0), [track.id])
    XCTAssertEqual(h.reports.reports.map(\.1), [240])
  }

  func testEndOfFolderEndsWithoutLoadingAnotherSource() async {
    let h = makeHarness(loadNeighbours: { _ in PutioAudioNeighbours() })
    await h.model.start()
    h.engine.onPositionChanged?(12)

    h.engine.onEnded?()
    await waitUntil { h.model.state == .ended(track) }

    XCTAssertEqual(h.engine.events.filter { $0.hasPrefix("load") }.count, 1)
    XCTAssertEqual(h.nowPlaying.published.last?.rate, 0)
    XCTAssertEqual(h.nowPlaying.published.last?.elapsedSeconds, 0)
    XCTAssertEqual(h.model.elapsedSeconds, 0)

    h.model.togglePlayPause()
    await waitUntil { h.model.state == .playing(track) }
    XCTAssertEqual(h.engine.events.last(where: { $0.hasPrefix("load") }), "load:430.m4a@0")
  }

  func testInterruptionPausesAndResumesOnlyWhenTheSystemAsks() async {
    let h = makeHarness()
    await h.model.start()
    h.engine.onPositionChanged?(12)

    h.center.post(
      name: AVAudioSession.interruptionNotification, object: nil,
      userInfo: [AVAudioSessionInterruptionTypeKey: AVAudioSession.InterruptionType.began.rawValue])
    await waitUntil { h.model.state == .interrupted(track) }
    XCTAssertEqual(h.model.state, .interrupted(track))
    XCTAssertEqual(h.engine.events.last, "pause")

    h.center.post(
      name: AVAudioSession.interruptionNotification, object: nil,
      userInfo: [
        AVAudioSessionInterruptionTypeKey: AVAudioSession.InterruptionType.ended.rawValue,
        AVAudioSessionInterruptionOptionKey: UInt(0),
      ])
    await waitUntil { h.model.state == .paused(track) }
    XCTAssertEqual(h.model.state, .paused(track))

    h.model.resume()
    h.center.post(
      name: AVAudioSession.interruptionNotification, object: nil,
      userInfo: [AVAudioSessionInterruptionTypeKey: AVAudioSession.InterruptionType.began.rawValue])
    await waitUntil { h.model.state == .interrupted(track) }
    h.center.post(
      name: AVAudioSession.interruptionNotification, object: nil,
      userInfo: [
        AVAudioSessionInterruptionTypeKey: AVAudioSession.InterruptionType.ended.rawValue,
        AVAudioSessionInterruptionOptionKey:
          AVAudioSession.InterruptionOptions.shouldResume.rawValue,
      ])
    await waitUntil { h.model.state == .playing(track) }
    XCTAssertEqual(h.model.state, .playing(track))
    // Each interruption releases the session; every resume activates again.
    XCTAssertEqual(h.session.events.filter { $0 == "activate" }.count, 3)
  }

  func testStoppedPlayerDoesNotRepublishAfterPendingSuccessorReturnsNone() async {
    var pending: CheckedContinuation<PutioAudioNeighbours, Never>?
    weak var retiringModel: PutioAudioPlayerModel?
    let nowPlaying: NowPlayingSpy
    let publicationCount: Int
    do {
      let h = makeHarness(loadNeighbours: { _ in
        await withCheckedContinuation { pending = $0 }
      })
      retiringModel = h.model
      nowPlaying = h.nowPlaying
      await h.model.start()
      h.engine.onPositionChanged?(12)
      h.engine.onEnded?()
      await waitUntil { pending != nil }
      h.model.stop()
      publicationCount = nowPlaying.published.count
    }
    guard let pending else { return XCTFail("successor lookup did not start") }
    pending.resume(returning: PutioAudioNeighbours())
    // The transition retains its model until advance finishes, including any
    // state publication after the suspended lookup returns.
    await waitUntil { retiringModel == nil }
    XCTAssertEqual(nowPlaying.published.count, publicationCount)
    XCTAssertEqual(nowPlaying.clearCount, 1)
  }

  func testSystemEngineIgnoresQueuedEndFromReplacedItem() async throws {
    let engine = PutioSystemAudioEngine()
    defer { engine.stop() }
    let ended = expectation(description: "retired item must not end its replacement")
    ended.isInverted = true
    engine.onEnded = { ended.fulfill() }
    let url = FileManager.default.temporaryDirectory.appending(path: "putio-retired-audio.m4a")
    engine.load(url: url, startFromSeconds: 0)
    let retiredItem = try XCTUnwrap(engine.player.currentItem)
    NotificationCenter.default.post(
      name: AVPlayerItem.didPlayToEndTimeNotification, object: retiredItem)
    engine.load(url: url, startFromSeconds: 0)
    await fulfillment(of: [ended], timeout: 0.2)
  }

  func testSystemEngineIgnoresQueuedFailureAfterStop() async throws {
    let engine = PutioSystemAudioEngine()
    let failed = expectation(description: "stopped item must not report failure")
    failed.isInverted = true
    engine.onFailed = { failed.fulfill() }
    let url = FileManager.default.temporaryDirectory.appending(path: "putio-stopped-audio.m4a")
    engine.load(url: url, startFromSeconds: 0)
    let retiredItem = try XCTUnwrap(engine.player.currentItem)
    NotificationCenter.default.post(
      name: AVPlayerItem.failedToPlayToEndTimeNotification, object: retiredItem)
    engine.stop()
    await fulfillment(of: [failed], timeout: 0.2)
  }

  func testSkipReportsTheAbandonedPositionBeforeAdvancing() async {
    let h = makeHarness()
    await h.model.start()
    h.engine.onPositionChanged?(12)
    h.engine.onPositionChanged?(180)
    await waitUntil { h.model.canSkipToNext }

    h.nowPlaying.send(.next)
    XCTAssertEqual(h.model.state, .loading(track), "a skip shows the transition immediately")
    XCTAssertEqual(h.nowPlaying.published.last?.rate, 0)
    let next = PutioAudioTrack(id: successor.id, parentID: .root, title: successor.name)
    await waitUntil { h.model.state == .playing(next) }
    await h.pipeline.waitForPendingReports(fileID: track.id)

    XCTAssertEqual(h.reports.reports.map(\.1), [180])
  }

  func testRemotePlayReplaysAnEndedFolderFromTheStart() async {
    let h = makeHarness(loadNeighbours: { _ in PutioAudioNeighbours() })
    await h.model.start()
    h.engine.onPositionChanged?(12)
    h.engine.onEnded?()
    await waitUntil { h.model.state == .ended(track) }

    h.nowPlaying.send(.play)
    await waitUntil { h.model.state == .playing(track) }

    XCTAssertEqual(h.engine.events.last(where: { $0.hasPrefix("load") }), "load:430.m4a@0")
  }

  func testPreviousAndNextFollowTheFolderAndTheLockScreenOffersOnlyWhatExists() async {
    let h = makeHarness()
    await h.model.start()
    h.engine.onPositionChanged?(12)
    await waitUntil { h.model.neighbours != nil }

    XCTAssertEqual(h.model.neighbours?.folderName, "Music")
    XCTAssertFalse(h.model.canSkipToPrevious)
    XCTAssertTrue(h.model.canSkipToNext)
    XCTAssertTrue(h.nowPlaying.trackCommands == (false, true))
    h.nowPlaying.send(.previous)
    XCTAssertEqual(h.model.state, .playing(track))

    h.model.skipToNext()
    let next = PutioAudioTrack(id: successor.id, parentID: .root, title: successor.name)
    await waitUntil { h.model.state == .playing(next) && h.model.neighbours != nil }
    XCTAssertTrue(h.model.canSkipToPrevious)
    XCTAssertFalse(h.model.canSkipToNext)
    XCTAssertTrue(h.nowPlaying.trackCommands == (true, false))

    h.engine.onPositionChanged?(12)
    h.engine.onPositionChanged?(70)
    h.nowPlaying.send(.previous)
    await waitUntil { h.model.state == .playing(track) }
    await h.pipeline.waitForPendingReports(fileID: successor.id)
    XCTAssertEqual(h.reports.reports.last.map(\.0), successor.id)
    XCTAssertEqual(h.reports.reports.last.map(\.1), 70)
    XCTAssertEqual(h.engine.events.suffix(2), ["load:430.m4a@12", "play:1.0"])
  }

  func testTheOnlyFileInAFolderOffersNeitherPreviousNorNext() async {
    let h = makeHarness(loadNeighbours: { _ in PutioAudioNeighbours(folderName: "Music") })
    await h.model.start()
    h.engine.onPositionChanged?(12)
    await waitUntil { h.model.neighbours != nil }

    XCTAssertFalse(h.model.canSkipToPrevious)
    XCTAssertFalse(h.model.canSkipToNext)
    XCTAssertTrue(h.nowPlaying.trackCommands == (false, false))
    h.model.skipToNext()
    h.model.skipToPrevious()
    h.nowPlaying.send(.next)
    XCTAssertEqual(h.model.state, .playing(track))
    XCTAssertEqual(h.engine.events.filter { $0.hasPrefix("load") }.count, 1)
  }

  func testAudioFailuresSayPutioIsUnavailableUnlessRateLimited() {
    XCTAssertEqual(
      PutioVideoPlaybackFailure.playback.audioMessage,
      "put.io is temporarily unavailable. Try again.")
    XCTAssertEqual(
      PutioVideoPlaybackFailure.resolving(PutioRuntimeError.transient)?.audioMessage,
      "put.io is temporarily unavailable. Try again.")
    XCTAssertEqual(
      PutioVideoPlaybackFailure.resolving(PutioRuntimeError.rateLimited)?.audioMessage,
      "put.io is receiving too many requests. Try again shortly.")
  }

  func testRemoteCommandsDriveTheTransport() async {
    let h = makeHarness()
    await h.model.start()
    h.engine.onPositionChanged?(12)

    h.nowPlaying.send(.pause)
    XCTAssertEqual(h.model.state, .paused(track))
    h.nowPlaying.send(.play)
    XCTAssertEqual(h.model.state, .playing(track))
    h.nowPlaying.send(.seek(seconds: 500))
    XCTAssertEqual(h.engine.events.last, "seek:240")
    // A stale pre-seek tick is ignored; the landed position is accepted.
    h.engine.onPositionChanged?(30)
    XCTAssertEqual(h.model.elapsedSeconds, 240)
    h.engine.onPositionChanged?(240)
    h.engine.onPositionChanged?(20)
    XCTAssertEqual(h.model.elapsedSeconds, 20)
    h.nowPlaying.send(.toggle)
    XCTAssertEqual(h.model.state, .paused(track))
  }

  func testStaleEngineFailureDuringTransitionIsIgnored() async {
    let h = makeHarness()
    await h.model.start()
    h.engine.onPositionChanged?(12)
    await waitUntil { h.model.canSkipToNext }

    h.model.skipToNext()
    h.engine.onFailed?()
    let next = PutioAudioTrack(id: successor.id, parentID: .root, title: successor.name)
    await waitUntil { h.model.state == .playing(next) }

    XCTAssertEqual(h.model.state, .playing(next))
  }

  func testSeekIsIgnoredBeforeDurationIsKnownOrWhileNotPlayable() async {
    let h = makeHarness()
    h.engine.durationSeconds = nil
    await h.model.start()

    h.model.seek(to: 500)
    XCTAssertFalse(h.engine.events.contains { $0.hasPrefix("seek") })
    await h.pipeline.waitForPendingReports(fileID: track.id)
    XCTAssertTrue(h.reports.reports.isEmpty)

    let resolving = expectation(description: "audio source resolution started")
    let stalled = makeHarness(resolve: { _ in
      resolving.fulfill()
      try await Task.sleep(for: .seconds(60))
      throw PutioRuntimeError.transient
    })
    let start = Task { await stalled.model.start() }
    defer {
      start.cancel()
      stalled.model.stop()
    }
    await fulfillment(of: [resolving], timeout: 2)
    XCTAssertEqual(stalled.nowPlaying.attachmentCount, 1)
    XCTAssertEqual(stalled.model.state, .loading(track))
    stalled.nowPlaying.send(.seek(seconds: 30))
    start.cancel()
    await start.value
    XCTAssertTrue(stalled.engine.events.isEmpty)
  }

  func testStopReportsFinalPositionClearsNowPlayingAndReleasesTheSession() async {
    let h = makeHarness()
    await h.model.start()
    h.engine.onPositionChanged?(12)
    h.engine.onPositionChanged?(90)

    h.model.stop()
    await h.pipeline.waitForPendingReports(fileID: track.id)

    XCTAssertEqual(h.reports.reports.map(\.1), [90])
    XCTAssertEqual(h.engine.events.last, "stop")
    XCTAssertEqual(h.nowPlaying.clearCount, 1)
    XCTAssertEqual(h.nowPlaying.detachCount, 1)
    XCTAssertEqual(h.session.events, ["activate", "deactivate"])
  }

  func testSessionActivationFailureIsARecoverablePlaybackFailure() async {
    let h = makeHarness()
    h.session.activationError = AudioSessionSpy.Failure.activation

    await h.model.start()
    h.engine.onPositionChanged?(12)

    XCTAssertEqual(h.model.state, .failed(track, .playback))
    XCTAssertTrue(h.engine.events.isEmpty)
  }
}

extension AudioSessionSpy {
  fileprivate enum Failure: Error { case activation }
}
