import Foundation
import Observation

public typealias PutioAudioResolve =
  @MainActor @Sendable (PutioFileID) async throws -> PutioPlaybackSource
public typealias PutioAudioNeighboursLoad =
  @MainActor @Sendable (PutioAudioTrack) async throws -> PutioAudioNeighbours
/// The account's current remember-position setting. Players outlive any one
/// account snapshot, so they ask again at every load and report.
public typealias PutioPlaybackPositionSetting = @MainActor @Sendable () -> Bool

public struct PutioAudioTrack: Equatable, Sendable {
  public let id: PutioFileID
  public let parentID: PutioFileID
  public let title: String

  public init(id: PutioFileID, parentID: PutioFileID, title: String) {
    self.id = id
    self.parentID = parentID
    self.title = title
  }
}

public enum PutioAudioPlayerState: Equatable {
  case loading(PutioAudioTrack)
  case playing(PutioAudioTrack)
  case paused(PutioAudioTrack)
  case interrupted(PutioAudioTrack)
  case failed(PutioAudioTrack, PutioVideoPlaybackFailure)
  case ended(PutioAudioTrack)

  public var track: PutioAudioTrack {
    switch self {
    case .loading(let track), .playing(let track), .paused(let track),
      .interrupted(let track), .ended(let track), .failed(let track, _):
      track
    }
  }
}

public struct PutioNowPlayingInfo: Equatable, Sendable {
  public let title: String
  public let elapsedSeconds: Int
  public let durationSeconds: Int?
  public let rate: Float

  public init(title: String, elapsedSeconds: Int, durationSeconds: Int?, rate: Float) {
    self.title = title
    self.elapsedSeconds = elapsedSeconds
    self.durationSeconds = durationSeconds
    self.rate = rate
  }
}

public enum PutioRemoteAudioCommand: Equatable, Sendable {
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
public protocol PutioNowPlayingSurface: AnyObject {
  func publish(_ info: PutioNowPlayingInfo)
  func clear()
  func setCommandHandler(_ handler: @escaping @MainActor (PutioRemoteAudioCommand) -> Void)
  func setTrackCommands(previous: Bool, next: Bool)
  func detachCommands()
}

/// The audio transport. The system implementation wraps `AVPlayer`; tests
/// drive the model with a spy.
@MainActor
public protocol PutioAudioEngine: AnyObject {
  var onReady: (@MainActor (_ startSeconds: Int) -> Void)? { get set }
  var onEnded: (@MainActor () -> Void)? { get set }
  var onFailed: (@MainActor () -> Void)? { get set }
  var onPositionChanged: (@MainActor (Int) -> Void)? { get set }
  var onPlayingChanged: (@MainActor (Bool) -> Void)? { get set }
  var durationSeconds: Int? { get }

  func load(url: URL, startFromSeconds: Int)
  func play(rate: Float)
  func pause()
  func seek(to seconds: Int)
  func setRate(_ rate: Float)
  func stop()
  var playsAtRate: Bool { get }
}

extension PutioAudioEngine {
  public var playsAtRate: Bool { true }

  public func load(url: URL, exactlyAt seconds: Int) {
    load(url: url, startFromSeconds: seconds)
  }
}

@MainActor
public protocol PutioAudioSessioning: AnyObject {
  func activate() throws
  func deactivate()
}

/// What the system tells a player about its audio session and app.
public enum PutioAudioSessionEvent: Hashable, Sendable {
  case interruptionBegan
  case interruptionEnded(shouldResume: Bool)
  /// The output in use went away, such as unplugged headphones.
  case outputLost
  case enteredBackground
}

/// Delivers `PutioAudioSessionEvent`s while a player runs. The system
/// implementation observes `AVAudioSession` and the app lifecycle.
@MainActor
public protocol PutioAudioSessionEvents: AnyObject {
  func start(_ handler: @escaping @MainActor (PutioAudioSessionEvent) -> Void)
  func stop()
}

@MainActor
@Observable
public final class PutioAudioPlayerModel {
  public static let skipInterval = 10

  public private(set) var state: PutioAudioPlayerState
  public private(set) var speed: PutioAudioSpeed
  public private(set) var elapsedSeconds = 0
  public private(set) var durationSeconds: Int?
  public private(set) var neighbours: PutioAudioNeighbours?

  public private(set) var isOnReceiver = false

  @ObservationIgnored private var engine: any PutioAudioEngine
  @ObservationIgnored private let localEngine: any PutioAudioEngine
  @ObservationIgnored private let nowPlaying: any PutioNowPlayingSurface
  @ObservationIgnored private let audioSession: any PutioAudioSessioning
  @ObservationIgnored private let speedStore: PutioAudioSpeedStore
  @ObservationIgnored private let positionPipeline: PutioPlaybackPositionPipeline
  @ObservationIgnored private let remembersPlaybackPosition: PutioPlaybackPositionSetting
  @ObservationIgnored private let reportPosition: PutioPlaybackPositionReport
  @ObservationIgnored private let schedulePositionReports: PutioVideoPositionReporter.Scheduler
  @ObservationIgnored private var positionReporter: PutioVideoPositionReporter?
  @ObservationIgnored private var resolve: PutioAudioResolve
  @ObservationIgnored private let localResolve: PutioAudioResolve
  @ObservationIgnored private let loadNeighbours: PutioAudioNeighboursLoad
  @ObservationIgnored private var neighboursTask: Task<PutioAudioNeighbours?, Never>?
  @ObservationIgnored private var neighboursTrackID: PutioFileID?
  @ObservationIgnored private let sessionEvents: any PutioAudioSessionEvents
  @ObservationIgnored private var generation: UInt64 = 0
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
  @ObservationIgnored private var holdsNextStart = false
  @ObservationIgnored private var requestedStartSeconds: Int?

  public init(
    track: PutioAudioTrack,
    engine: any PutioAudioEngine,
    nowPlaying: any PutioNowPlayingSurface,
    audioSession: any PutioAudioSessioning,
    sessionEvents: any PutioAudioSessionEvents,
    speedStore: PutioAudioSpeedStore,
    positionPipeline: PutioPlaybackPositionPipeline,
    remembersPlaybackPosition: @escaping PutioPlaybackPositionSetting = { true },
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
    self.localEngine = engine
    self.nowPlaying = nowPlaying
    self.audioSession = audioSession
    self.speedStore = speedStore
    self.positionPipeline = positionPipeline
    self.remembersPlaybackPosition = remembersPlaybackPosition
    self.sessionEvents = sessionEvents
    self.schedulePositionReports = schedulePositionReports
    // Queued reports check the setting again when the pipeline sends them.
    self.reportPosition = { fileID, seconds in
      guard remembersPlaybackPosition() else { throw CancellationError() }
      try await reportPosition(fileID, seconds)
    }
    self.resolve = resolve
    self.localResolve = resolve
    self.loadNeighbours = loadNeighbours
    bindEngine()
  }

  public var track: PutioAudioTrack { state.track }

  public var isPlaying: Bool {
    if case .playing = state { return true }
    return false
  }

  public func start() async {
    guard !isStarted, !Task.isCancelled else { return }
    isStarted = true
    sessionEvents.start { [weak self] event in self?.handle(event) }
    nowPlaying.setCommandHandler { [weak self] command in
      self?.handle(command)
    }
    await load(track: track)
  }

  public func retry() async {
    holdsNextStart = false
    await load(track: track)
  }

  public func togglePlayPause() {
    switch state {
    case .playing:
      pause()
    case .paused, .interrupted:
      resume()
    case .ended(let track):
      holdsNextStart = false
      transitionTask?.cancel()
      transitionTask = Task { [weak self] in
        await self?.load(track: track, startFromSeconds: 0)
      }
    case .loading, .failed:
      break
    }
  }

  public func pause() {
    guard case .playing(let track) = state, !isTransitioning else { return }
    engine.pause()
    state = .paused(track)
    positionReporter?.savePosition()
    publishNowPlaying()
  }

  public func sleepTimerExpired() {
    switch state {
    case .playing:
      pause()
    case .interrupted(let track):
      resumesAfterInterruption = false
      state = .paused(track)
      positionReporter?.savePosition()
      publishNowPlaying()
    case .loading:
      holdsNextStart = true
    case .paused, .ended, .failed:
      break
    }
  }

  public func resume() {
    holdsNextStart = false
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
  public func seek(to seconds: Int) {
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
  public func skip(by seconds: Int) {
    seek(to: elapsedSeconds + seconds)
  }

  public func setSpeed(_ speed: PutioAudioSpeed) {
    self.speed = speed
    speedStore.save(speed)
    if isPlaying { engine.setRate(speed.rawValue) }
    publishNowPlaying()
  }

  public func moveToReceiver(
    _ receiver: any PutioAudioEngine, resolve receiverResolve: @escaping PutioAudioResolve
  ) {
    guard !isOnReceiver else { return }
    switchOutput(to: receiver, resolve: receiverResolve, onReceiver: true, keepsPlaying: true)
  }

  public func returnFromReceiver() {
    guard isOnReceiver else { return }
    switchOutput(to: localEngine, resolve: localResolve, onReceiver: false, keepsPlaying: false)
  }

  private func switchOutput(
    to next: any PutioAudioEngine, resolve nextResolve: @escaping PutioAudioResolve,
    onReceiver: Bool, keepsPlaying: Bool
  ) {
    let plays: Bool
    switch state {
    case .playing, .loading: plays = keepsPlaying && !holdsNextStart
    case .paused, .interrupted, .failed, .ended: plays = false
    }
    let seconds: Int?
    switch state {
    case .loading: seconds = requestedStartSeconds
    default: seconds = elapsedSeconds
    }
    let resumes: Bool
    switch state {
    case .ended: resumes = false
    default: resumes = isStarted && !isTransitioning
    }
    if resumes {
      positionReporter?.stop()
      generation &+= 1
      transitionTask?.cancel()
      transitionTask = nil
      awaitedSeconds = nil
      loadStartSeconds = nil
    }
    engine.onReady = nil
    engine.onEnded = nil
    engine.onFailed = nil
    engine.onPositionChanged = nil
    engine.onPlayingChanged = nil
    engine.stop()
    engine = next
    resolve = nextResolve
    isOnReceiver = onReceiver
    bindEngine()
    if isTransitioning, !plays { holdsNextStart = true }
    guard resumes else {
      publishNowPlaying()
      return
    }
    holdsNextStart = !plays
    let track = track
    state = .loading(track)
    transitionTask = Task { [weak self] in
      await self?.load(track: track, startFromSeconds: seconds)
    }
  }

  public var canSkipToPrevious: Bool { neighbours?.previous != nil && !isTransitioning }
  public var canSkipToNext: Bool { neighbours?.next != nil && !isTransitioning }

  public func skipToNext() {
    guard canSkipToNext, let next = neighbours?.next else { return }
    switchTo(next)
  }

  public var queue: [PutioQueuedAudio] { neighbours?.queue ?? [] }

  public func play(_ queued: PutioQueuedAudio) {
    guard !isTransitioning else { return }
    guard queued.id != track.id else {
      switch state {
      case .failed: Task { await retry() }
      case .paused, .interrupted, .ended: togglePlayPause()
      case .loading, .playing: break
      }
      return
    }
    guard queue.contains(where: { $0.id == queued.id }) else { return }
    switchTo(queued)
  }

  public func skipToPrevious() {
    guard canSkipToPrevious, let previous = neighbours?.previous else { return }
    switchTo(previous)
  }

  private func switchTo(_ target: PutioQueuedAudio) {
    let current = track
    holdsNextStart = false
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

  public func stop() {
    guard isStarted else { return }
    isStarted = false
    holdsNextStart = false
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
    sessionEvents.stop()
  }

  // MARK: - Loading

  private func load(track: PutioAudioTrack, startFromSeconds override: Int? = nil) async {
    generation &+= 1
    let requestGeneration = generation
    isTransitioning = false
    state = .loading(track)
    requestedStartSeconds = override
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
        holdsNextStart = false
        state = .failed(track, .playback)
        publishNowPlaying()
        return
      }
      let remembers = remembersPlaybackPosition()
      let startFrom = override ?? (remembers ? source.startFromSeconds : 0)
      elapsedSeconds = startFrom
      awaitedSeconds = startFrom > 0 ? startFrom : nil
      loadStartSeconds = awaitedSeconds
      if override != nil {
        engine.load(url: source.url, exactlyAt: startFrom)
      } else {
        engine.load(url: source.url, startFromSeconds: startFrom)
      }
      durationSeconds = engine.durationSeconds
      if holdsNextStart {
        holdsNextStart = false
        state = .paused(track)
      } else {
        engine.play(rate: speed.rawValue)
        state = .playing(track)
      }
      startReporting(track: track, remembers: remembers, savedSeconds: source.startFromSeconds)
      publishNowPlaying()
    } catch {
      guard requestGeneration == generation, !Task.isCancelled else { return }
      holdsNextStart = false
      state = .failed(track, PutioVideoPlaybackFailure.resolving(error) ?? .playback)
      publishNowPlaying()
    }
  }

  private func readNeighbours(of track: PutioAudioTrack) {
    if neighboursTrackID == track.id, neighbours != nil { return }
    neighboursTask?.cancel()
    neighboursTrackID = track.id
    neighbours = neighbours?.moved(to: track.id)
    publishTrackCommands()
    let load = loadNeighbours
    neighboursTask = Task { [weak self] in
      let found = try? await load(track)
      guard let self, !Task.isCancelled, neighboursTrackID == track.id else { return nil }
      guard let found else { return neighbours }
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
      if neighbours == nil { neighbours = await neighboursTask?.value }
      guard requestGeneration == generation, !Task.isCancelled else { return }
      if neighbours == nil { neighbours = try? await loadNeighbours(completed) }
      next = neighbours?.next
    }
    guard requestGeneration == generation, !Task.isCancelled else { return }
    guard let next else {
      isTransitioning = false
      holdsNextStart = false
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
      guard let self, !self.isTransitioning else { return }
      switch self.state {
      case .playing: break
      case .paused where self.isOnReceiver: break
      default: return
      }
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
    engine.onPlayingChanged = { [weak self] playing in
      guard let self, !isTransitioning else { return }
      switch (state, playing) {
      case (.paused(let track), true), (.interrupted(let track), true):
        state = .playing(track)
        publishNowPlaying()
      case (.playing(let track), false):
        state = .paused(track)
        positionReporter?.savePosition()
        publishNowPlaying()
      default:
        break
      }
    }
    engine.onFailed = { [weak self] in
      // A failure from the retired item during a transition is stale.
      guard let self, !isTransitioning else { return }
      positionReporter?.playbackFailed()
      state = .failed(track, .playback)
      publishNowPlaying()
    }
  }

  private func handle(_ event: PutioAudioSessionEvent) {
    switch event {
    case .interruptionBegan:
      sessionIsActive = false
      guard !isOnReceiver, case .playing(let track) = state else { return }
      resumesAfterInterruption = true
      engine.pause()
      state = .interrupted(track)
      positionReporter?.savePosition()
      publishNowPlaying()
    case .interruptionEnded(let shouldResume):
      guard case .interrupted = state else { return }
      if resumesAfterInterruption, shouldResume {
        resume()
      } else if case .interrupted(let track) = state {
        state = .paused(track)
        publishNowPlaying()
      }
      resumesAfterInterruption = false
    case .outputLost:
      // Unplugging headphones pauses rather than playing out loud.
      guard !isOnReceiver else { return }
      pause()
    case .enteredBackground:
      positionReporter?.savePosition()
    }
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
          rate: isPlaying ? (engine.playsAtRate ? speed.rawValue : 1) : 0
        ))
    }
  }
}

extension PutioVideoPlaybackFailure {
  public var audioMessage: String {
    switch kind {
    case .rateLimited: message
    default: String(localized: "put.io is temporarily unavailable. Try again.", bundle: .module)
    }
  }
}
