import Foundation
import PutioCore

typealias PutioCastAudioResolve = @MainActor @Sendable (PutioFileID) async throws -> PutioCastMedia

@MainActor
final class PutioCastAudioEngine: PutioAudioEngine {
  var onReady: (@MainActor (_ startSeconds: Int) -> Void)?
  var onEnded: (@MainActor () -> Void)?
  var onFailed: (@MainActor () -> Void)?
  var onPositionChanged: (@MainActor (Int) -> Void)?

  private let controller: PutioCastControlling
  private let resolveMedia: PutioCastAudioResolve
  private let tickInterval: Duration
  private var resolved: PutioCastMedia?
  private var pending: PutioCastMedia?
  private var loaded: PutioCastMedia?
  private var status: PutioCastMediaStatus?
  private var statusReceivedAt: ContinuousClock.Instant?
  private var wantsPlay = false
  private var generation: UInt64 = 0
  private var loadTask: Task<Void, Never>?
  private var ticker: Task<Void, Never>?

  init(
    controller: PutioCastControlling, tickInterval: Duration = .milliseconds(500),
    resolve: @escaping PutioCastAudioResolve
  ) {
    self.controller = controller
    self.tickInterval = tickInterval
    self.resolveMedia = resolve
  }

  isolated deinit {
    loadTask?.cancel()
    ticker?.cancel()
  }

  var playsAtRate: Bool { false }

  var durationSeconds: Int? {
    let reported = status?.durationSeconds ?? 0
    let duration = reported > 0 ? reported : (loaded ?? pending ?? resolved)?.durationSeconds ?? 0
    guard duration.isFinite, duration > 0 else { return nil }
    return Int(duration.rounded(.down))
  }

  func resolve(_ fileID: PutioFileID) async throws -> PutioPlaybackSource {
    let media = try await resolveMedia(fileID)
    resolved = media
    return PutioPlaybackSource(url: media.url, startFromSeconds: media.startFromSeconds)
  }

  func load(url: URL, startFromSeconds: Int) {
    generation &+= 1
    let request = generation
    loadTask?.cancel()
    stopTicker()
    loaded = nil
    status = nil
    wantsPlay = false
    guard let media = resolved, media.url == url else {
      pending = nil
      Task { @MainActor [weak self] in
        guard let self, request == generation else { return }
        onFailed?()
      }
      return
    }
    pending = media
    loadTask = Task { @MainActor [weak self] in
      await Task.yield()
      guard let self, request == generation else { return }
      do {
        try await controller.load(media, startSeconds: startFromSeconds, autoplay: wantsPlay)
        guard request == generation else { return }
        pending = nil
        loaded = media
        let autoplayed = wantsPlay
        onReady?(startFromSeconds)
        if autoplayed { startTicker() }
      } catch {
        guard request == generation, !(error is CancellationError) else { return }
        pending = nil
        onFailed?()
      }
    }
  }

  func play(rate: Float) {
    wantsPlay = true
    guard loaded != nil else { return }
    command { try await $0.play() }
    startTicker()
  }

  func pause() {
    wantsPlay = false
    stopTicker()
    guard loaded != nil else { return }
    command { try await $0.pause() }
  }

  func seek(to seconds: Int) {
    guard loaded != nil else { return }
    command { try await $0.seek(toSeconds: Double(seconds)) }
  }

  func setRate(_ rate: Float) {}

  func stop() {
    generation &+= 1
    loadTask?.cancel()
    loadTask = nil
    stopTicker()
    let hadMedia = loaded != nil || pending != nil
    loaded = nil
    pending = nil
    resolved = nil
    status = nil
    wantsPlay = false
    guard hadMedia else { return }
    let controller = controller
    Task { @MainActor in try? await controller.stop() }
  }

  func receive(_ next: PutioCastMediaStatus?) {
    guard let loaded else { return }
    guard let next, next.fileID == loaded.id, next.playerState != .idle else {
      finish()
      return
    }
    status = next
    statusReceivedAt = .now
    switch next.playerState {
    case .playing, .buffering:
      if wantsPlay { startTicker() }
    case .paused, .loading, .idle:
      break
    }
    if let seconds = currentPosition() { onPositionChanged?(seconds) }
  }

  private func finish() {
    let position = currentPositionSeconds() ?? 0
    let duration = Double(durationSeconds ?? 0)
    generation &+= 1
    stopTicker()
    loaded = nil
    status = nil
    if PutioVideoPositionReporter.isAtEnd(positionSeconds: position, durationSeconds: duration) {
      onEnded?()
    } else {
      onFailed?()
    }
  }

  private func command(_ send: @escaping @MainActor (PutioCastControlling) async throws -> Void) {
    let request = generation
    let controller = controller
    Task { @MainActor [weak self] in
      do {
        try await send(controller)
      } catch {
        guard let self, request == generation, loaded != nil else { return }
        stopTicker()
        loaded = nil
        onFailed?()
      }
    }
  }

  private func startTicker() {
    guard ticker == nil else { return }
    let interval = tickInterval
    ticker = Task { @MainActor [weak self] in
      while !Task.isCancelled {
        try? await Task.sleep(for: interval)
        guard let self, !Task.isCancelled else { return }
        if let seconds = currentPosition() { onPositionChanged?(seconds) }
      }
    }
  }

  private func stopTicker() {
    ticker?.cancel()
    ticker = nil
  }

  private func currentPosition() -> Int? {
    currentPositionSeconds().map { Int($0.rounded(.down)) }
  }

  private func currentPositionSeconds() -> Double? {
    if let approximate = controller.approximatePositionSeconds, loaded != nil {
      return approximate
    }
    guard let status else { return nil }
    guard status.playerState == .playing, let statusReceivedAt else {
      return status.positionSeconds
    }
    let elapsed = statusReceivedAt.duration(to: .now)
    let seconds =
      status.positionSeconds + Double(elapsed.components.seconds)
      + Double(elapsed.components.attoseconds) / 1e18
    return durationSeconds.map { min(seconds, Double($0)) } ?? seconds
  }
}
