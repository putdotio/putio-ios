import AVFoundation
import AVKit
import MediaPlayer
import OSLog
import Observation
import PutioCore
import SwiftUI

typealias PutioAudioResolve =
  @MainActor @Sendable (PutioFileID) async throws -> PutioPlaybackSource
typealias PutioAudioNeighboursLoad =
  @MainActor @Sendable (PutioAudioTrack) async throws -> PutioAudioNeighbours
/// The account's current remember-position setting. Players outlive any one
/// account snapshot, so they ask again at every load and report.
typealias PutioPlaybackPositionSetting = @MainActor @Sendable () -> Bool

struct PutioAudioTrack: Equatable, Sendable {
  let id: PutioFileID
  let parentID: PutioFileID
  let title: String
}

enum PutioAudioPlayerState: Equatable {
  case loading(PutioAudioTrack)
  case playing(PutioAudioTrack)
  case paused(PutioAudioTrack)
  case interrupted(PutioAudioTrack)
  case failed(PutioAudioTrack, PutioVideoPlaybackFailure)
  case ended(PutioAudioTrack)

  var track: PutioAudioTrack {
    switch self {
    case .loading(let track), .playing(let track), .paused(let track),
      .interrupted(let track), .ended(let track), .failed(let track, _):
      track
    }
  }
}

/// Speeds the current app exposes. The chosen rate persists across launches
/// and applies to every track without asking again.
enum PutioAudioSpeed: Float, CaseIterable, Sendable {
  case quarter = 0.25
  case half = 0.5
  case slower = 0.75
  case normal = 1
  case faster = 1.25
  case fast = 1.5
  case double = 2
  case doubleAndHalf = 2.5
  case triple = 3
  case tripleAndHalf = 3.5
  case quadruple = 4

  /// Locale-independent so the label, identifier, and persisted value agree.
  var title: String {
    "\(identifier)×"
  }

  var identifier: String {
    let value = Double(rawValue)
    return value == value.rounded() ? String(Int(value)) : String(value)
  }
}

@MainActor
final class PutioAudioSpeedStore {
  private static let key = "putio.audio.playback-speed"
  private let defaults: UserDefaults

  init(defaults: UserDefaults = .standard) {
    self.defaults = defaults
  }

  func load() -> PutioAudioSpeed {
    guard defaults.object(forKey: Self.key) != nil else { return .normal }
    return PutioAudioSpeed(rawValue: defaults.float(forKey: Self.key)) ?? .normal
  }

  func save(_ speed: PutioAudioSpeed) {
    defaults.set(speed.rawValue, forKey: Self.key)
  }
}

struct PutioNowPlayingInfo: Equatable, Sendable {
  let title: String
  let elapsedSeconds: Int
  let durationSeconds: Int?
  let rate: Float
}

enum PutioRemoteAudioCommand: Equatable, Sendable {
  case play
  case pause
  case toggle
  case next
  case previous
  case seek(seconds: Int)
  case skip(seconds: Int)
}

/// The platform surface that shows what is playing and relays lock-screen
/// commands. The system implementation writes `MPNowPlayingInfoCenter`.
@MainActor
protocol PutioNowPlayingSurface: AnyObject {
  func publish(_ info: PutioNowPlayingInfo)
  func clear()
  func setCommandHandler(_ handler: @escaping @MainActor (PutioRemoteAudioCommand) -> Void)
  func setTrackCommands(previous: Bool, next: Bool)
  func detachCommands()
}

/// The audio transport. The system implementation wraps `AVPlayer`; tests
/// drive the model with a spy.
@MainActor
protocol PutioAudioEngine: AnyObject {
  var onReady: (@MainActor (_ startSeconds: Int) -> Void)? { get set }
  var onEnded: (@MainActor () -> Void)? { get set }
  var onFailed: (@MainActor () -> Void)? { get set }
  var onPositionChanged: (@MainActor (Int) -> Void)? { get set }
  var durationSeconds: Int? { get }

  func load(url: URL, startFromSeconds: Int)
  func play(rate: Float)
  func pause()
  func seek(to seconds: Int)
  func setRate(_ rate: Float)
  func stop()
}

@MainActor
protocol PutioAudioSessioning: AnyObject {
  func activate() throws
  func deactivate()
}

@MainActor
@Observable
final class PutioAudioPlayerModel {
  static let skipInterval = 10

  private(set) var state: PutioAudioPlayerState
  private(set) var speed: PutioAudioSpeed
  private(set) var elapsedSeconds = 0
  private(set) var durationSeconds: Int?
  /// The files beside the current track; `nil` until its folder is read.
  private(set) var neighbours: PutioAudioNeighbours?

  @ObservationIgnored private let engine: any PutioAudioEngine
  @ObservationIgnored private let nowPlaying: any PutioNowPlayingSurface
  @ObservationIgnored private let audioSession: any PutioAudioSessioning
  @ObservationIgnored private let speedStore: PutioAudioSpeedStore
  @ObservationIgnored private let positionPipeline: PutioPlaybackPositionPipeline
  @ObservationIgnored private let remembersPlaybackPosition: PutioPlaybackPositionSetting
  @ObservationIgnored private let reportPosition: PutioPlaybackPositionReport
  @ObservationIgnored private let schedulePositionReports: PutioVideoPositionReporter.Scheduler
  @ObservationIgnored private var positionReporter: PutioVideoPositionReporter?
  @ObservationIgnored private let resolve: PutioAudioResolve
  @ObservationIgnored private let loadNeighbours: PutioAudioNeighboursLoad
  @ObservationIgnored private var neighboursTask: Task<PutioAudioNeighbours?, Never>?
  @ObservationIgnored private var neighboursTrackID: PutioFileID?
  @ObservationIgnored private let notificationCenter: NotificationCenter
  @ObservationIgnored private var generation: UInt64 = 0
  @ObservationIgnored private var observers: [NSObjectProtocol] = []
  @ObservationIgnored private var resumesAfterInterruption = false
  @ObservationIgnored private var sessionIsActive = false
  @ObservationIgnored private var isStarted = false
  @ObservationIgnored private var transitionTask: Task<Void, Never>?
  /// Observer ticks are ignored until the engine confirms this position, so a
  /// stale sample cannot undo a seek, a start position, or the end-of-track reset.
  @ObservationIgnored private var awaitedSeconds: Int?
  @ObservationIgnored private var loadStartSeconds: Int?
  /// True between end or skip and the next load; the finished track no longer
  /// accepts positions.
  @ObservationIgnored private var isTransitioning = false

  init(
    track: PutioAudioTrack,
    engine: any PutioAudioEngine,
    nowPlaying: any PutioNowPlayingSurface,
    audioSession: any PutioAudioSessioning,
    speedStore: PutioAudioSpeedStore,
    positionPipeline: PutioPlaybackPositionPipeline,
    remembersPlaybackPosition: @escaping PutioPlaybackPositionSetting = { true },
    notificationCenter: NotificationCenter = .default,
    schedulePositionReports: @escaping PutioVideoPositionReporter.Scheduler = {
      interval, callback in
      PutioMonotonicPositionReportSchedule(interval: interval, callback: callback)
    },
    reportPosition: @escaping PutioPlaybackPositionReport,
    resolve: @escaping PutioAudioResolve,
    loadNeighbours: @escaping PutioAudioNeighboursLoad
  ) {
    self.state = .loading(track)
    self.speed = speedStore.load()
    self.engine = engine
    self.nowPlaying = nowPlaying
    self.audioSession = audioSession
    self.speedStore = speedStore
    self.positionPipeline = positionPipeline
    self.remembersPlaybackPosition = remembersPlaybackPosition
    self.notificationCenter = notificationCenter
    self.schedulePositionReports = schedulePositionReports
    // Queued reports check the setting again when the pipeline sends them.
    self.reportPosition = { fileID, seconds in
      guard remembersPlaybackPosition() else { throw CancellationError() }
      try await reportPosition(fileID, seconds)
    }
    self.resolve = resolve
    self.loadNeighbours = loadNeighbours
    bindEngine()
  }

  var track: PutioAudioTrack { state.track }

  var isPlaying: Bool {
    if case .playing = state { return true }
    return false
  }

  func start() async {
    guard !isStarted, !Task.isCancelled else { return }
    isStarted = true
    observeSession()
    nowPlaying.setCommandHandler { [weak self] command in
      self?.handle(command)
    }
    await load(track: track)
  }

  func retry() async {
    await load(track: track)
  }

  func togglePlayPause() {
    switch state {
    case .playing:
      pause()
    case .paused, .interrupted:
      resume()
    case .ended(let track):
      transitionTask?.cancel()
      transitionTask = Task { [weak self] in
        await self?.load(track: track, startFromSeconds: 0)
      }
    case .loading, .failed:
      break
    }
  }

  func pause() {
    guard case .playing(let track) = state, !isTransitioning else { return }
    engine.pause()
    state = .paused(track)
    positionReporter?.savePosition()
    publishNowPlaying()
  }

  func resume() {
    switch state {
    case .paused(let track), .interrupted(let track):
      guard activateSession() else { return }
      engine.play(rate: speed.rawValue)
      state = .playing(track)
      publishNowPlaying()
    default:
      break
    }
  }

  /// Seeks only while a track is loaded and its length is known, so a remote
  /// scrub during loading or before metadata cannot persist a bogus position.
  func seek(to seconds: Int) {
    switch state {
    case .playing, .paused, .interrupted, .ended: break
    case .loading, .failed: return
    }
    guard !isTransitioning, let duration = durationSeconds else { return }
    let bounded = max(0, min(seconds, duration))
    awaitedSeconds = bounded
    engine.seek(to: bounded)
    elapsedSeconds = bounded
    positionReporter?.savePosition()
    publishNowPlaying()
  }

  /// Moves by `seconds` from the current position, within the track.
  func skip(by seconds: Int) {
    seek(to: elapsedSeconds + seconds)
  }

  func setSpeed(_ speed: PutioAudioSpeed) {
    self.speed = speed
    speedStore.save(speed)
    if isPlaying { engine.setRate(speed.rawValue) }
    publishNowPlaying()
  }

  var canSkipToPrevious: Bool { neighbours?.previous != nil && !isTransitioning }
  var canSkipToNext: Bool { neighbours?.next != nil && !isTransitioning }

  func skipToNext() {
    guard canSkipToNext, let next = neighbours?.next else { return }
    switchTo(next)
  }

  func skipToPrevious() {
    guard canSkipToPrevious, let previous = neighbours?.previous else { return }
    switchTo(previous)
  }

  private func switchTo(_ target: PutioQueuedAudio) {
    let current = track
    positionReporter?.stop()
    beginTransition()
    transitionTask = Task { [weak self] in await self?.advance(from: current, to: target) }
  }

  /// Freezes the current track: the engine stops, its generation is retired so
  /// a late end or failure cannot start a second advance, and the reset holds.
  private func beginTransition() {
    generation &+= 1
    transitionTask?.cancel()
    engine.pause()
    awaitedSeconds = nil
    isTransitioning = true
    state = .loading(track)
    publishNowPlaying()
  }

  func stop() {
    guard isStarted else { return }
    isStarted = false
    generation &+= 1
    transitionTask?.cancel()
    transitionTask = nil
    neighboursTask?.cancel()
    neighboursTask = nil
    positionReporter?.stop()
    positionReporter = nil
    engine.stop()
    nowPlaying.clear()
    nowPlaying.detachCommands()
    deactivateSession()
    for observer in observers { notificationCenter.removeObserver(observer) }
    observers = []
  }

  // MARK: - Loading

  private func load(track: PutioAudioTrack, startFromSeconds override: Int? = nil) async {
    generation &+= 1
    let requestGeneration = generation
    isTransitioning = false
    state = .loading(track)
    elapsedSeconds = override ?? 0
    durationSeconds = nil
    positionReporter?.cancel()
    positionReporter = nil
    loadStartSeconds = nil
    readNeighbours(of: track)
    await positionPipeline.waitForPendingReports(fileID: track.id)
    do {
      try Task.checkCancellation()
      guard requestGeneration == generation else { return }
      let source = try await resolve(track.id)
      try Task.checkCancellation()
      guard requestGeneration == generation else { return }
      guard activateSession() else {
        state = .failed(track, .playback)
        publishNowPlaying()
        return
      }
      let remembers = remembersPlaybackPosition()
      let startFrom = override ?? (remembers ? source.startFromSeconds : 0)
      elapsedSeconds = startFrom
      awaitedSeconds = startFrom > 0 ? startFrom : nil
      loadStartSeconds = awaitedSeconds
      engine.load(url: source.url, startFromSeconds: startFrom)
      durationSeconds = engine.durationSeconds
      engine.play(rate: speed.rawValue)
      state = .playing(track)
      startReporting(track: track, remembers: remembers, savedSeconds: source.startFromSeconds)
      publishNowPlaying()
    } catch {
      guard requestGeneration == generation, !Task.isCancelled else { return }
      state = .failed(track, PutioVideoPlaybackFailure.resolving(error) ?? .playback)
      publishNowPlaying()
    }
  }

  private func readNeighbours(of track: PutioAudioTrack) {
    if neighboursTrackID == track.id, neighbours != nil { return }
    neighboursTask?.cancel()
    neighboursTrackID = track.id
    neighbours = nil
    publishTrackCommands()
    let load = loadNeighbours
    neighboursTask = Task { [weak self] in
      let found = try? await load(track)
      guard let self, !Task.isCancelled, neighboursTrackID == track.id else { return nil }
      neighbours = found
      publishTrackCommands()
      return found
    }
  }

  private func advance(from completed: PutioAudioTrack, to target: PutioQueuedAudio?) async {
    let requestGeneration = generation
    await positionPipeline.waitForPendingReports(fileID: completed.id)
    guard requestGeneration == generation, !Task.isCancelled else { return }
    positionReporter?.stop()
    await positionPipeline.waitForPendingReports(fileID: completed.id)
    guard requestGeneration == generation, !Task.isCancelled else { return }
    var next = target
    if next == nil, neighboursTrackID == completed.id {
      next = await neighboursTask?.value?.next
    }
    guard requestGeneration == generation, !Task.isCancelled else { return }
    guard let next else {
      isTransitioning = false
      elapsedSeconds = 0
      state = .ended(completed)
      publishNowPlaying()
      publishTrackCommands()
      return
    }
    await load(track: PutioAudioTrack(id: next.id, parentID: next.parentID, title: next.name))
  }

  // MARK: - Engine and system events

  private func bindEngine() {
    engine.onReady = { [weak self] startSeconds in
      guard let self else { return }
      durationSeconds = engine.durationSeconds
      if let requested = loadStartSeconds, awaitedSeconds == requested,
        requested != startSeconds, !isTransitioning
      {
        awaitedSeconds = startSeconds > 0 ? startSeconds : nil
        elapsedSeconds = startSeconds
      }
      loadStartSeconds = nil
      publishNowPlaying()
    }
    engine.onPositionChanged = { [weak self] seconds in
      guard let self, self.isPlaying, !self.isTransitioning else { return }
      if let awaited = self.awaitedSeconds {
        // Samples before the seek lands describe the old position.
        guard abs(seconds - awaited) <= 1 else { return }
        self.awaitedSeconds = nil
      }
      self.elapsedSeconds = seconds
      if self.durationSeconds == nil { self.durationSeconds = self.engine.durationSeconds }
    }
    engine.onEnded = { [weak self] in
      guard let self, case .playing(let track) = state else { return }
      if let durationSeconds { elapsedSeconds = durationSeconds }
      _ = positionReporter?.playbackEnded()
      beginTransition()
      elapsedSeconds = 0
      publishNowPlaying()
      transitionTask = Task { [weak self] in await self?.advance(from: track, to: nil) }
    }
    engine.onFailed = { [weak self] in
      // A failure from the retired item during a transition is stale.
      guard let self, !isTransitioning else { return }
      positionReporter?.playbackFailed()
      state = .failed(track, .playback)
      publishNowPlaying()
    }
  }

  private func observeSession() {
    observers.append(
      notificationCenter.addObserver(
        forName: AVAudioSession.interruptionNotification, object: nil, queue: .main
      ) { [weak self] notification in
        Task { @MainActor [weak self] in self?.handleInterruption(notification) }
      })
    observers.append(
      notificationCenter.addObserver(
        forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main
      ) { [weak self] notification in
        Task { @MainActor [weak self] in self?.handleRouteChange(notification) }
      })
    observers.append(
      notificationCenter.addObserver(
        forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main
      ) { [weak self] _ in
        MainActor.assumeIsolated { self?.positionReporter?.savePosition() }
      })
  }

  private func handleInterruption(_ notification: Notification) {
    guard let raw = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
      let type = AVAudioSession.InterruptionType(rawValue: raw)
    else { return }
    switch type {
    case .began:
      guard case .playing(let track) = state else { return }
      resumesAfterInterruption = true
      // The system deactivated the session; resume must activate it again.
      sessionIsActive = false
      engine.pause()
      state = .interrupted(track)
      positionReporter?.savePosition()
      publishNowPlaying()
    case .ended:
      guard case .interrupted = state else { return }
      let options =
        (notification.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt)
        .map(AVAudioSession.InterruptionOptions.init(rawValue:)) ?? []
      if resumesAfterInterruption, options.contains(.shouldResume) {
        resume()
      } else if case .interrupted(let track) = state {
        state = .paused(track)
        publishNowPlaying()
      }
      resumesAfterInterruption = false
    @unknown default:
      break
    }
  }

  private func handleRouteChange(_ notification: Notification) {
    guard let raw = notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt,
      let reason = AVAudioSession.RouteChangeReason(rawValue: raw),
      reason == .oldDeviceUnavailable
    else { return }
    // Unplugging headphones pauses rather than playing out loud.
    pause()
  }

  private func handle(_ command: PutioRemoteAudioCommand) {
    switch command {
    case .play:
      if case .ended = state { togglePlayPause() } else { resume() }
    case .pause: pause()
    case .toggle: togglePlayPause()
    case .next: skipToNext()
    case .previous: skipToPrevious()
    case .seek(let seconds): seek(to: seconds)
    case .skip(let seconds): skip(by: seconds)
    }
  }

  // MARK: - Session, reporting, Now Playing

  private func activateSession() -> Bool {
    if sessionIsActive { return true }
    do {
      try audioSession.activate()
      sessionIsActive = true
      return true
    } catch {
      return false
    }
  }

  private func deactivateSession() {
    guard sessionIsActive else { return }
    audioSession.deactivate()
    sessionIsActive = false
  }

  private func startReporting(track: PutioAudioTrack, remembers: Bool, savedSeconds: Int) {
    let reporter = PutioVideoPositionReporter(
      fileID: track.id,
      remembersPosition: true,
      pipeline: positionPipeline,
      report: reportPosition,
      currentPosition: { [weak self] in self?.reportablePosition },
      savedPosition: remembers ? savedSeconds : 0,
      endOfPlayback: .keepsPosition,
      schedule: schedulePositionReports
    )
    positionReporter = reporter
    reporter.positionEstablished()
    reporter.ready()
  }

  private var reportablePosition: Int? {
    guard !isTransitioning else { return nil }
    switch state {
    case .playing, .paused, .interrupted: return elapsedSeconds
    case .loading, .failed, .ended: return nil
    }
  }

  private func publishTrackCommands() {
    nowPlaying.setTrackCommands(
      previous: neighbours?.previous != nil, next: neighbours?.next != nil)
  }

  private func publishNowPlaying() {
    switch state {
    case .failed:
      nowPlaying.clear()
    default:
      nowPlaying.publish(
        PutioNowPlayingInfo(
          title: track.title,
          elapsedSeconds: elapsedSeconds,
          durationSeconds: durationSeconds,
          rate: isPlaying ? speed.rawValue : 0
        ))
    }
  }
}

// MARK: - System implementations

@MainActor
final class PutioSystemAudioEngine: PutioAudioEngine {
  private static let logger = Logger(subsystem: "io.put", category: "AudioPlayback")
  var onReady: (@MainActor (_ startSeconds: Int) -> Void)?
  var onEnded: (@MainActor () -> Void)?
  var onFailed: (@MainActor () -> Void)?
  var onPositionChanged: (@MainActor (Int) -> Void)?

  let player = AVPlayer()
  private var statusObservation: NSKeyValueObservation?
  private var timeObserver: Any?
  private var endObserver: NSObjectProtocol?
  private var failObserver: NSObjectProtocol?
  private var itemIsReady = false
  private var pendingStartSeconds = 0
  private var pendingRate: Float?

  init() {
    player.automaticallyWaitsToMinimizeStalling = true
  }

  var durationSeconds: Int? {
    guard let duration = player.currentItem?.duration else { return nil }
    return Self.seconds(duration)
  }

  func load(url: URL, startFromSeconds: Int) {
    stopObserving()
    let item = AVPlayerItem(url: url)
    itemIsReady = false
    pendingStartSeconds = startFromSeconds
    pendingRate = nil
    player.replaceCurrentItem(with: item)
    statusObservation = item.observe(\.status, options: [.initial, .new]) { [weak self] item, _ in
      Task { @MainActor [weak self] in
        guard let self, self.player.currentItem === item else { return }
        switch item.status {
        case .readyToPlay: self.handleReady()
        case .failed:
          self.reportFailure(item.error)
        default: break
        }
      }
    }
    endObserver = NotificationCenter.default.addObserver(
      forName: AVPlayerItem.didPlayToEndTimeNotification, object: item, queue: .main
    ) { [weak self] _ in
      Task { @MainActor [weak self] in
        guard let self, self.player.currentItem === item else { return }
        self.onEnded?()
      }
    }
    failObserver = NotificationCenter.default.addObserver(
      forName: AVPlayerItem.failedToPlayToEndTimeNotification, object: item, queue: .main
    ) { [weak self] notification in
      let error = notification.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? Error
      Task { @MainActor [weak self] in
        guard let self, self.player.currentItem === item else { return }
        self.reportFailure(error ?? item.error)
      }
    }
    timeObserver = player.addPeriodicTimeObserver(
      forInterval: CMTime(seconds: 0.5, preferredTimescale: 600), queue: .main
    ) { [weak self] time in
      Task { @MainActor [weak self] in
        guard let self, self.player.currentItem === item, let seconds = Self.seconds(time) else {
          return
        }
        self.onPositionChanged?(seconds)
      }
    }
  }

  /// Playback starts once the item is ready and any saved position has been
  /// sought, so the first audible frame is the resumed one.
  func play(rate: Float) {
    guard itemIsReady else {
      pendingRate = rate
      return
    }
    player.playImmediately(atRate: rate)
  }

  func pause() {
    pendingRate = nil
    player.pause()
  }

  func seek(to seconds: Int) {
    player.seek(
      to: CMTime(seconds: Double(seconds), preferredTimescale: 600),
      toleranceBefore: .zero, toleranceAfter: .zero)
  }

  func setRate(_ rate: Float) {
    guard itemIsReady else {
      pendingRate = rate
      return
    }
    player.rate = rate
  }

  private func handleReady() {
    guard !itemIsReady else { return }
    itemIsReady = true
    let start = PutioPlaybackProgress.startSeconds(
      savedSeconds: pendingStartSeconds,
      durationSeconds: player.currentItem.map { CMTimeGetSeconds($0.duration) })
    pendingStartSeconds = 0
    let begin: @MainActor () -> Void = { [weak self] in
      guard let self else { return }
      if let rate = self.pendingRate {
        self.pendingRate = nil
        self.player.playImmediately(atRate: rate)
      }
      self.onReady?(start)
    }
    guard start > 0 else {
      begin()
      return
    }
    let item = player.currentItem
    player.seek(
      to: CMTime(seconds: Double(start), preferredTimescale: 600),
      toleranceBefore: .zero, toleranceAfter: .zero
    ) { [weak self] _ in
      Task { @MainActor [weak self] in
        guard let self, self.player.currentItem === item else { return }
        begin()
      }
    }
  }

  func stop() {
    stopObserving()
    player.pause()
    player.replaceCurrentItem(with: nil)
  }

  private func stopObserving() {
    statusObservation?.invalidate()
    statusObservation = nil
    if let timeObserver {
      player.removeTimeObserver(timeObserver)
      self.timeObserver = nil
    }
    for observer in [endObserver, failObserver].compactMap({ $0 }) {
      NotificationCenter.default.removeObserver(observer)
    }
    endObserver = nil
    failObserver = nil
  }

  private func reportFailure(_ error: Error?) {
    var cause = error.map { $0 as NSError }
    if cause == nil {
      Self.logger.error("Audio playback failed without an underlying error")
    }
    // Error descriptions and userInfo can contain signed media URLs.
    for depth in 0..<4 {
      guard let current = cause else { break }
      Self.logger.error(
        "Audio playback failed: depth=\(depth) domain=\(current.domain, privacy: .public) code=\(current.code)"
      )
      cause = current.userInfo[NSUnderlyingErrorKey] as? NSError
    }
    onFailed?()
  }

  private static func seconds(_ time: CMTime) -> Int? {
    guard time.isValid, time.isNumeric else { return nil }
    let seconds = CMTimeGetSeconds(time)
    guard seconds.isFinite, seconds >= 0, seconds < Double(Int.max) else { return nil }
    return Int(seconds.rounded(.down))
  }
}

@MainActor
final class PutioSystemNowPlayingSurface: PutioNowPlayingSurface {
  private var handler: (@MainActor (PutioRemoteAudioCommand) -> Void)?
  private var targets: [(MPRemoteCommand, Any)] = []

  func publish(_ info: PutioNowPlayingInfo) {
    var nowPlaying: [String: Any] = [
      MPMediaItemPropertyTitle: info.title,
      MPNowPlayingInfoPropertyElapsedPlaybackTime: Double(info.elapsedSeconds),
      MPNowPlayingInfoPropertyPlaybackRate: Double(info.rate),
    ]
    if let duration = info.durationSeconds {
      nowPlaying[MPMediaItemPropertyPlaybackDuration] = Double(duration)
    }
    MPNowPlayingInfoCenter.default().nowPlayingInfo = nowPlaying
  }

  func clear() {
    MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
  }

  func detachCommands() {
    handler = nil
    for (command, target) in targets {
      command.removeTarget(target)
      command.isEnabled = false
    }
    targets = []
  }

  func setCommandHandler(_ handler: @escaping @MainActor (PutioRemoteAudioCommand) -> Void) {
    self.handler = handler
    let center = MPRemoteCommandCenter.shared()
    register(center.playCommand) { _ in .play }
    register(center.pauseCommand) { _ in .pause }
    register(center.togglePlayPauseCommand) { _ in .toggle }
    register(center.nextTrackCommand) { _ in .next }
    register(center.previousTrackCommand) { _ in .previous }
    let interval = PutioAudioPlayerModel.skipInterval
    center.skipBackwardCommand.preferredIntervals = [NSNumber(value: interval)]
    center.skipForwardCommand.preferredIntervals = [NSNumber(value: interval)]
    register(center.skipBackwardCommand) { _ in .skip(seconds: -interval) }
    register(center.skipForwardCommand) { _ in .skip(seconds: interval) }
    register(center.changePlaybackPositionCommand) { event in
      guard let event = event as? MPChangePlaybackPositionCommandEvent else { return nil }
      return .seek(seconds: Int(event.positionTime.rounded(.down)))
    }
    setTrackCommands(previous: false, next: false)
  }

  func setTrackCommands(previous: Bool, next: Bool) {
    guard handler != nil else { return }
    let center = MPRemoteCommandCenter.shared()
    center.previousTrackCommand.isEnabled = previous
    center.nextTrackCommand.isEnabled = next
  }

  private func register(
    _ command: MPRemoteCommand,
    map: @escaping @Sendable (MPRemoteCommandEvent) -> PutioRemoteAudioCommand?
  ) {
    // Command events arrive on the media framework's queue; the model is
    // main-actor bound, so the hop is explicit.
    let target = command.addTarget { [weak self] event in
      guard let mapped = map(event) else { return .commandFailed }
      Task { @MainActor [weak self] in self?.handler?(mapped) }
      return .success
    }
    command.isEnabled = true
    targets.append((command, target))
  }
}

@MainActor
final class PutioSystemAudioSession: PutioAudioSessioning {
  func activate() throws {
    let session = AVAudioSession.sharedInstance()
    try session.setCategory(.playback, mode: .default)
    try session.setActive(true)
  }

  func deactivate() {
    try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
  }
}

struct PutioAudioRoutePicker: UIViewRepresentable {
  func makeUIView(context: Context) -> AVRoutePickerView {
    let picker = AVRoutePickerView()
    picker.tintColor = UIColor(PutioTheme.Colors.textPrimary)
    picker.activeTintColor = UIColor(PutioTheme.Colors.accent)
    return picker
  }

  func updateUIView(_ uiView: AVRoutePickerView, context: Context) {}
}

extension PutioVideoPlaybackFailure {
  var audioMessage: String {
    switch kind {
    case .rateLimited: message
    default: String(localized: "put.io is temporarily unavailable. Try again.")
    }
  }
}
