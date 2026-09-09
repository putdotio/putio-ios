import AVFoundation
import AVKit
import MediaPlayer
import Observation
import PutioCore
import SwiftUI

typealias PutioAudioResolve =
  @MainActor @Sendable (PutioFileID) async throws -> PutioPlaybackSource
typealias PutioNextAudioLoad =
  @MainActor @Sendable (PutioFileID) async throws -> PutioNextAudio?

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
  case slower = 0.75
  case normal = 1
  case faster = 1.25
  case fast = 1.5
  case fastest = 2

  /// Locale-independent so the label, identifier, and persisted value agree.
  var title: String {
    switch self {
    case .slower: "0.75×"
    case .normal: "1×"
    case .faster: "1.25×"
    case .fast: "1.5×"
    case .fastest: "2×"
    }
  }

  var identifier: String {
    String(title.dropLast())
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
  case seek(seconds: Int)
}

/// The platform surface that shows what is playing and relays lock-screen
/// commands. The system implementation writes `MPNowPlayingInfoCenter`.
@MainActor
protocol PutioNowPlayingSurface: AnyObject {
  func publish(_ info: PutioNowPlayingInfo)
  func clear()
  func setCommandHandler(_ handler: @escaping @MainActor (PutioRemoteAudioCommand) -> Void)
}

/// The audio transport. The system implementation wraps `AVPlayer`; tests
/// drive the model with a spy.
@MainActor
protocol PutioAudioEngine: AnyObject {
  var onReady: (@MainActor () -> Void)? { get set }
  var onEnded: (@MainActor () -> Void)? { get set }
  var onFailed: (@MainActor () -> Void)? { get set }
  var onPositionChanged: (@MainActor (Int) -> Void)? { get set }
  var elapsedSeconds: Int { get }
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
  private(set) var state: PutioAudioPlayerState
  private(set) var speed: PutioAudioSpeed
  private(set) var elapsedSeconds = 0
  private(set) var durationSeconds: Int?
  /// The successor known to the model once the current track ended, so the
  /// view can show the transition before the next source resolves.
  private(set) var advancingTo: PutioNextAudio?

  @ObservationIgnored private let engine: any PutioAudioEngine
  @ObservationIgnored private let nowPlaying: any PutioNowPlayingSurface
  @ObservationIgnored private let audioSession: any PutioAudioSessioning
  @ObservationIgnored private let speedStore: PutioAudioSpeedStore
  @ObservationIgnored private let positionPipeline: PutioPlaybackPositionPipeline
  @ObservationIgnored private let reportPosition: PutioPlaybackPositionReport
  @ObservationIgnored private let resolve: PutioAudioResolve
  @ObservationIgnored private let loadNext: PutioNextAudioLoad
  @ObservationIgnored private let notificationCenter: NotificationCenter
  @ObservationIgnored private var generation: UInt64 = 0
  @ObservationIgnored private var observers: [NSObjectProtocol] = []
  @ObservationIgnored private var lastReportedSeconds: Int?
  @ObservationIgnored private var resumesAfterInterruption = false
  @ObservationIgnored private var sessionIsActive = false
  @ObservationIgnored private var advanceTask: Task<Void, Never>?

  init(
    track: PutioAudioTrack,
    engine: any PutioAudioEngine,
    nowPlaying: any PutioNowPlayingSurface,
    audioSession: any PutioAudioSessioning,
    speedStore: PutioAudioSpeedStore,
    positionPipeline: PutioPlaybackPositionPipeline,
    notificationCenter: NotificationCenter = .default,
    reportPosition: @escaping PutioPlaybackPositionReport,
    resolve: @escaping PutioAudioResolve,
    loadNext: @escaping PutioNextAudioLoad
  ) {
    self.state = .loading(track)
    self.speed = speedStore.load()
    self.engine = engine
    self.nowPlaying = nowPlaying
    self.audioSession = audioSession
    self.speedStore = speedStore
    self.positionPipeline = positionPipeline
    self.notificationCenter = notificationCenter
    self.reportPosition = reportPosition
    self.resolve = resolve
    self.loadNext = loadNext
    bindEngine()
    observeSession()
    nowPlaying.setCommandHandler { [weak self] command in
      self?.handle(command)
    }
  }

  var track: PutioAudioTrack { state.track }

  var isPlaying: Bool {
    if case .playing = state { return true }
    return false
  }

  func start() async {
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
      Task { await load(track: track, startFromSeconds: 0) }
    case .loading, .failed:
      break
    }
  }

  func pause() {
    guard case .playing(let track) = state else { return }
    engine.pause()
    state = .paused(track)
    reportCurrentPosition(force: true)
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

  func seek(to seconds: Int) {
    let bounded = max(0, durationSeconds.map { min(seconds, $0) } ?? seconds)
    engine.seek(to: bounded)
    elapsedSeconds = bounded
    reportCurrentPosition(force: true)
    publishNowPlaying()
  }

  func setSpeed(_ speed: PutioAudioSpeed) {
    self.speed = speed
    speedStore.save(speed)
    if isPlaying { engine.setRate(speed.rawValue) }
    publishNowPlaying()
  }

  func skipToNext() {
    let current = track
    advanceTask?.cancel()
    advanceTask = Task { [weak self] in await self?.advance(from: current) }
  }

  func stop() {
    generation &+= 1
    advanceTask?.cancel()
    advanceTask = nil
    if case .playing = state { reportCurrentPosition(force: true) }
    engine.stop()
    nowPlaying.clear()
    deactivateSession()
    for observer in observers { notificationCenter.removeObserver(observer) }
    observers = []
  }

  // MARK: - Loading

  private func load(track: PutioAudioTrack, startFromSeconds override: Int? = nil) async {
    generation &+= 1
    let requestGeneration = generation
    state = .loading(track)
    elapsedSeconds = override ?? 0
    durationSeconds = nil
    lastReportedSeconds = nil
    do {
      try Task.checkCancellation()
      let source = try await resolve(track.id)
      try Task.checkCancellation()
      guard requestGeneration == generation else { return }
      guard activateSession() else {
        advancingTo = nil
        state = .failed(track, .playback)
        publishNowPlaying()
        return
      }
      let startFrom = override ?? source.startFromSeconds
      elapsedSeconds = startFrom
      // The server already holds the start position; report only movement.
      lastReportedSeconds = startFrom
      engine.load(url: source.url, startFromSeconds: startFrom)
      durationSeconds = engine.durationSeconds
      engine.play(rate: speed.rawValue)
      advancingTo = nil
      state = .playing(track)
      publishNowPlaying()
    } catch {
      guard requestGeneration == generation, !Task.isCancelled else { return }
      advancingTo = nil
      state = .failed(track, PutioVideoPlaybackFailure.resolving(error) ?? .playback)
      publishNowPlaying()
    }
  }

  private func advance(from completed: PutioAudioTrack) async {
    let requestGeneration = generation
    await positionPipeline.waitForPendingReports(fileID: completed.id)
    guard requestGeneration == generation, !Task.isCancelled else { return }
    do {
      guard let next = try await loadNext(completed.id) else {
        state = .ended(completed)
        publishNowPlaying()
        return
      }
      guard requestGeneration == generation, !Task.isCancelled else { return }
      advancingTo = next
      await load(track: PutioAudioTrack(id: next.id, parentID: next.parentID, title: next.name))
    } catch {
      guard requestGeneration == generation, !Task.isCancelled else { return }
      state = .ended(completed)
      publishNowPlaying()
    }
  }

  // MARK: - Engine and system events

  private func bindEngine() {
    engine.onReady = { [weak self] in
      guard let self else { return }
      durationSeconds = engine.durationSeconds
      publishNowPlaying()
    }
    engine.onPositionChanged = { [weak self] seconds in
      guard let self, self.isPlaying else { return }
      self.elapsedSeconds = seconds
      if self.durationSeconds == nil { self.durationSeconds = self.engine.durationSeconds }
      self.reportCurrentPosition(force: false)
    }
    engine.onEnded = { [weak self] in
      guard let self, case .playing(let track) = state else { return }
      lastReportedSeconds = 0
      positionPipeline.enqueue(
        fileID: track.id, position: 0, preservesOrdering: true, report: reportPosition)
      advanceTask?.cancel()
      advanceTask = Task { [weak self] in await self?.advance(from: track) }
    }
    engine.onFailed = { [weak self] in
      guard let self else { return }
      state = .failed(track, .playback)
      publishNowPlaying()
    }
  }

  private func observeSession() {
    observers.append(
      notificationCenter.addObserver(
        forName: AVAudioSession.interruptionNotification, object: nil, queue: .main
      ) { [weak self] notification in
        MainActor.assumeIsolated { self?.handleInterruption(notification) }
      })
    observers.append(
      notificationCenter.addObserver(
        forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main
      ) { [weak self] notification in
        MainActor.assumeIsolated { self?.handleRouteChange(notification) }
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
      engine.pause()
      state = .interrupted(track)
      reportCurrentPosition(force: true)
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
    case .play: resume()
    case .pause: pause()
    case .toggle: togglePlayPause()
    case .next: skipToNext()
    case .seek(let seconds): seek(to: seconds)
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

  private static let reportCadence = 15

  /// Reports every `reportCadence` seconds of movement while playing, and the
  /// exact position on pause, seek, and teardown. A position the server already
  /// holds is never sent twice.
  private func reportCurrentPosition(force: Bool) {
    let seconds = elapsedSeconds
    if let last = lastReportedSeconds {
      if seconds == last { return }
      if !force, abs(seconds - last) < Self.reportCadence { return }
    } else if !force, seconds < Self.reportCadence {
      return
    }
    lastReportedSeconds = seconds
    positionPipeline.enqueue(fileID: track.id, position: seconds, report: reportPosition)
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
  var onReady: (@MainActor () -> Void)?
  var onEnded: (@MainActor () -> Void)?
  var onFailed: (@MainActor () -> Void)?
  var onPositionChanged: (@MainActor (Int) -> Void)?

  let player = AVPlayer()
  private var statusObservation: NSKeyValueObservation?
  private var timeObserver: Any?
  private var endObserver: NSObjectProtocol?
  private var failObserver: NSObjectProtocol?

  init() {
    player.automaticallyWaitsToMinimizeStalling = true
  }

  var elapsedSeconds: Int {
    Self.seconds(player.currentTime()) ?? 0
  }

  var durationSeconds: Int? {
    guard let duration = player.currentItem?.duration else { return nil }
    return Self.seconds(duration)
  }

  func load(url: URL, startFromSeconds: Int) {
    stopObserving()
    let item = AVPlayerItem(url: url)
    player.replaceCurrentItem(with: item)
    if startFromSeconds > 0 {
      player.seek(to: CMTime(seconds: Double(startFromSeconds), preferredTimescale: 600))
    }
    statusObservation = item.observe(\.status, options: [.initial, .new]) { [weak self] item, _ in
      Task { @MainActor [weak self] in
        switch item.status {
        case .readyToPlay: self?.onReady?()
        case .failed: self?.onFailed?()
        default: break
        }
      }
    }
    endObserver = NotificationCenter.default.addObserver(
      forName: AVPlayerItem.didPlayToEndTimeNotification, object: item, queue: .main
    ) { [weak self] _ in
      MainActor.assumeIsolated { self?.onEnded?() }
    }
    failObserver = NotificationCenter.default.addObserver(
      forName: AVPlayerItem.failedToPlayToEndTimeNotification, object: item, queue: .main
    ) { [weak self] _ in
      MainActor.assumeIsolated { self?.onFailed?() }
    }
    timeObserver = player.addPeriodicTimeObserver(
      forInterval: CMTime(seconds: 0.5, preferredTimescale: 600), queue: .main
    ) { [weak self] time in
      MainActor.assumeIsolated {
        guard let self, let seconds = Self.seconds(time) else { return }
        self.onPositionChanged?(seconds)
      }
    }
  }

  func play(rate: Float) {
    player.play()
    player.rate = rate
  }

  func pause() {
    player.pause()
  }

  func seek(to seconds: Int) {
    player.seek(
      to: CMTime(seconds: Double(seconds), preferredTimescale: 600),
      toleranceBefore: .zero, toleranceAfter: .zero)
  }

  func setRate(_ rate: Float) {
    player.rate = rate
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
    let center = MPRemoteCommandCenter.shared()
    for (command, target) in targets { command.removeTarget(target) }
    targets = []
    center.nextTrackCommand.isEnabled = false
  }

  func setCommandHandler(_ handler: @escaping @MainActor (PutioRemoteAudioCommand) -> Void) {
    self.handler = handler
    let center = MPRemoteCommandCenter.shared()
    register(center.playCommand) { _ in .play }
    register(center.pauseCommand) { _ in .pause }
    register(center.togglePlayPauseCommand) { _ in .toggle }
    register(center.nextTrackCommand) { _ in .next }
    register(center.changePlaybackPositionCommand) { event in
      guard let event = event as? MPChangePlaybackPositionCommandEvent else { return nil }
      return .seek(seconds: Int(event.positionTime.rounded(.down)))
    }
    center.nextTrackCommand.isEnabled = true
    center.previousTrackCommand.isEnabled = false
  }

  private func register(
    _ command: MPRemoteCommand,
    map: @escaping @Sendable (MPRemoteCommandEvent) -> PutioRemoteAudioCommand?
  ) {
    let target = command.addTarget { [weak self] event in
      guard let mapped = map(event) else { return .commandFailed }
      MainActor.assumeIsolated { self?.handler?(mapped) }
      return .success
    }
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

// MARK: - View

struct PutioAudioPlayerView: View {
  @State private var model: PutioAudioPlayerModel
  @State private var scrubbing = false
  @State private var scrubSeconds: Double = 0
  private let onDismiss: @MainActor () -> Void
  private let showsHarnessReadiness: Bool

  init(
    route: PutioAudioRoute,
    onDismiss: @escaping @MainActor () -> Void,
    showsHarnessReadiness: Bool = false,
    positionPipeline: PutioPlaybackPositionPipeline,
    reportPosition: @escaping PutioPlaybackPositionReport,
    resolve: @escaping PutioAudioResolve,
    loadNext: @escaping PutioNextAudioLoad
  ) {
    self.onDismiss = onDismiss
    self.showsHarnessReadiness = showsHarnessReadiness
    _model = State(
      initialValue: PutioAudioPlayerModel(
        track: PutioAudioTrack(id: route.id, parentID: route.parentID, title: route.title),
        engine: PutioSystemAudioEngine(),
        nowPlaying: PutioSystemNowPlayingSurface(),
        audioSession: PutioSystemAudioSession(),
        speedStore: PutioAudioSpeedStore(),
        positionPipeline: positionPipeline,
        reportPosition: reportPosition,
        resolve: resolve,
        loadNext: loadNext
      ))
  }

  var body: some View {
    NavigationStack {
      VStack(spacing: PutioTheme.Spacing.space6) {
        Spacer(minLength: 0)
        Image(putioIcon: .fileAudio)
          .resizable()
          .scaledToFit()
          .frame(width: 96, height: 96)
          .accessibilityHidden(true)
        Text(model.track.title)
          .putioFont(PutioTheme.Typography.heading)
          .foregroundStyle(PutioTheme.Colors.textPrimary)
          .multilineTextAlignment(.center)
          .lineLimit(2)
          .accessibilityIdentifier("audio.title")
        content
        Spacer(minLength: 0)
      }
      .padding(PutioTheme.Spacing.space5)
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      .putioContentBackground()
      .navigationTitle("Now Playing")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .confirmationAction) {
          Button("Done") { onDismiss() }
            .accessibilityIdentifier("audio.done")
        }
        ToolbarItem(placement: .topBarLeading) {
          PutioAudioRoutePicker()
            .frame(width: 32, height: 32)
            .accessibilityLabel("Audio output")
        }
      }
    }
    .task { await model.start() }
    .onDisappear { model.stop() }
    .overlay { harnessProbes }
  }

  @ViewBuilder
  private var content: some View {
    switch model.state {
    case .loading:
      PutioLoadingStateView(title: model.advancingTo == nil ? "Preparing audio" : "Up next")
        .accessibilityIdentifier("audio.loading")
    case .failed(_, let failure):
      PutioErrorStateView(
        title: failure.title, message: failure.message, retryTitle: "Try again",
        retryIdentifier: "audio.retry"
      ) {
        Task { await model.retry() }
      }
      .accessibilityIdentifier("audio.error")
    case .playing, .paused, .interrupted, .ended:
      transport
    }
  }

  private var transport: some View {
    VStack(spacing: PutioTheme.Spacing.space4) {
      Slider(
        value: Binding(
          get: { scrubbing ? scrubSeconds : Double(model.elapsedSeconds) },
          set: { scrubSeconds = $0 }
        ),
        in: 0...Double(max(model.durationSeconds ?? 0, 1)),
        onEditingChanged: { editing in
          scrubbing = editing
          if !editing { model.seek(to: Int(scrubSeconds.rounded(.down))) }
        }
      )
      .tint(PutioTheme.Colors.accent)
      .disabled(model.durationSeconds == nil)
      .accessibilityLabel("Playback position")
      .accessibilityIdentifier("audio.scrubber")
      HStack {
        Text(Self.clock(model.elapsedSeconds))
          .accessibilityIdentifier("audio.elapsed")
        Spacer()
        Text(model.durationSeconds.map(Self.clock) ?? "--:--")
          .accessibilityIdentifier("audio.duration")
      }
      .putioFont(PutioTheme.Typography.caption)
      .foregroundStyle(PutioTheme.Colors.textSecondary)
      .monospacedDigit()
      HStack(spacing: PutioTheme.Spacing.space5) {
        Menu {
          ForEach(PutioAudioSpeed.allCases, id: \.self) { speed in
            Button {
              model.setSpeed(speed)
            } label: {
              if speed == model.speed {
                Label(speed.title, systemImage: "checkmark")
              } else {
                Text(speed.title)
              }
            }
            .accessibilityIdentifier("audio.speed.\(speed.identifier)")
          }
        } label: {
          Text(model.speed.title)
            .putioFont(PutioTheme.Typography.body)
            .frame(minWidth: 56)
        }
        .buttonStyle(.bordered)
        .accessibilityLabel("Playback speed")
        .accessibilityValue(model.speed.title)
        .accessibilityIdentifier("audio.speed")
        Button {
          model.togglePlayPause()
        } label: {
          Image(systemName: playPauseSymbol)
            .font(.system(size: 36))
            .frame(width: 64, height: 64)
        }
        .buttonStyle(.borderedProminent)
        .clipShape(Circle())
        .disabled(isTransportDisabled)
        .accessibilityLabel(playPauseLabel)
        .accessibilityIdentifier("audio.play-pause")
        Button {
          model.skipToNext()
        } label: {
          Image(systemName: "forward.end.fill")
            .font(.system(size: 22))
            .frame(width: 56, height: 44)
        }
        .buttonStyle(.bordered)
        .disabled(isTransportDisabled)
        .accessibilityLabel("Next track")
        .accessibilityIdentifier("audio.next")
      }
      if case .interrupted = model.state {
        Text("Paused by another app")
          .putioFont(PutioTheme.Typography.caption)
          .foregroundStyle(PutioTheme.Colors.textSecondary)
          .accessibilityIdentifier("audio.interrupted")
      }
      if case .ended = model.state {
        Text("End of folder")
          .putioFont(PutioTheme.Typography.caption)
          .foregroundStyle(PutioTheme.Colors.textSecondary)
          .accessibilityIdentifier("audio.ended")
      }
    }
    .frame(maxWidth: 480)
  }

  private var isTransportDisabled: Bool {
    if case .loading = model.state { return true }
    return false
  }

  private var playPauseSymbol: String {
    switch model.state {
    case .playing: "pause.fill"
    case .ended: "arrow.counterclockwise"
    default: "play.fill"
    }
  }

  private var playPauseLabel: String {
    switch model.state {
    case .playing: "Pause"
    case .ended: "Play again"
    default: "Play"
    }
  }

  @ViewBuilder
  private var harnessProbes: some View {
    if showsHarnessReadiness {
      ZStack {
        Color.clear
          .frame(width: 1, height: 1)
          .accessibilityElement(children: .ignore)
          .accessibilityLabel("Audio player state")
          .accessibilityValue("id=\(model.track.id.rawValue);state=\(stateName)")
          .accessibilityIdentifier("audio.state")
          .allowsHitTesting(false)
      }
    }
  }

  private var stateName: String {
    switch model.state {
    case .loading: "loading"
    case .playing: "playing"
    case .paused: "paused"
    case .interrupted: "interrupted"
    case .failed: "failed"
    case .ended: "ended"
    }
  }

  private static func clock(_ seconds: Int) -> String {
    let minutes = seconds / 60
    let remainder = seconds % 60
    return "\(minutes):\(remainder < 10 ? "0" : "")\(remainder)"
  }
}

private struct PutioAudioRoutePicker: UIViewRepresentable {
  func makeUIView(context: Context) -> AVRoutePickerView {
    let picker = AVRoutePickerView()
    picker.tintColor = UIColor(PutioTheme.Colors.accent)
    picker.activeTintColor = UIColor(PutioTheme.Colors.accent)
    return picker
  }

  func updateUIView(_ uiView: AVRoutePickerView, context: Context) {}
}
