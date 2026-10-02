import Observation

public typealias PutioNextVideoResetWait =
  @MainActor @Sendable (PutioFileID) async -> Void
public typealias PutioNextVideoLoad =
  @MainActor @Sendable (PutioFileID) async throws -> PutioPlayableNextVideo?
public typealias PutioNextVideoSleep =
  @MainActor @Sendable (Duration) async throws -> Void
public typealias PutioNextVideoAutoplayPolicy = @MainActor @Sendable () async -> Bool

public struct PutioPlayableNextVideo: Equatable, Sendable {
  public let video: PutioNextVideo
  public let initialResolution: PutioPlaybackResolution
}

public enum PutioNextVideoState: Equatable {
  case idle
  case loading
  case available(PutioPlayableNextVideo)
  case playing(PutioPlayableNextVideo)
  case cancelled
  case unavailable
}

@MainActor
@Observable
public final class PutioNextVideoModel {
  public nonisolated static let defaultAutoplayDelay = Duration.seconds(5)
  nonisolated static let maximumAutoplayDelay = Duration.seconds(10)

  public private(set) var state: PutioNextVideoState = .idle
  /// Whole seconds left before the suggestion plays itself; nil while no
  /// autoplay countdown runs.
  public private(set) var autoplaySecondsRemaining: Int?

  @ObservationIgnored private let suggestionsEnabled: Bool
  /// Awaited when the suggestion appears, so the config document that owns
  /// `autoplay_next_video` can finish loading after the player opens; the
  /// suggestion stays actionable while the policy settles.
  @ObservationIgnored private let autoplayEnabled: PutioNextVideoAutoplayPolicy
  @ObservationIgnored private let autoplayDelay: Duration
  @ObservationIgnored private let waitForReset: PutioNextVideoResetWait
  @ObservationIgnored private let loadNext: PutioNextVideoLoad
  @ObservationIgnored private let sleep: PutioNextVideoSleep
  @ObservationIgnored private var generation: UInt64 = 0

  public init(
    suggestionsEnabled: Bool = true,
    autoplayEnabled: @escaping PutioNextVideoAutoplayPolicy,
    autoplayDelay: Duration = PutioNextVideoModel.defaultAutoplayDelay,
    waitForReset: @escaping PutioNextVideoResetWait,
    loadNext: @escaping PutioNextVideoLoad,
    sleep: @escaping PutioNextVideoSleep = { try await Task.sleep(for: $0) }
  ) {
    self.suggestionsEnabled = suggestionsEnabled
    self.autoplayEnabled = autoplayEnabled
    self.autoplayDelay = Self.bounded(delay: autoplayDelay)
    self.waitForReset = waitForReset
    self.loadNext = loadNext
    self.sleep = sleep
  }

  convenience init(
    suggestionsEnabled: Bool = true,
    autoplayEnabled: Bool,
    autoplayDelay: Duration = PutioNextVideoModel.defaultAutoplayDelay,
    waitForReset: @escaping PutioNextVideoResetWait,
    loadNext: @escaping PutioNextVideoLoad,
    sleep: @escaping PutioNextVideoSleep = { try await Task.sleep(for: $0) }
  ) {
    self.init(
      suggestionsEnabled: suggestionsEnabled,
      autoplayEnabled: { autoplayEnabled },
      autoplayDelay: autoplayDelay,
      waitForReset: waitForReset,
      loadNext: loadNext,
      sleep: sleep
    )
  }

  public func playbackEnded(completedFileID: PutioFileID) async {
    let requestGeneration = nextGeneration()
    state = .loading

    await waitForReset(completedFileID)
    guard isCurrent(requestGeneration) else { return }
    guard suggestionsEnabled else {
      state = .unavailable
      return
    }

    do {
      try Task.checkCancellation()
      let nextVideo = try await loadNext(completedFileID)
      try Task.checkCancellation()
      guard isCurrent(requestGeneration) else { return }
      guard let nextVideo else {
        state = .unavailable
        return
      }

      state = .available(nextVideo)
      let autoplay = await autoplayEnabled()
      try Task.checkCancellation()
      guard isCurrent(requestGeneration), autoplay else { return }

      do {
        try await countDown(requestGeneration)
      } catch {
        guard isCurrent(requestGeneration) else { return }
        autoplaySecondsRemaining = nil
        if Task.isCancelled || error is CancellationError {
          state = .cancelled
        }
        return
      }

      guard isCurrent(requestGeneration) else { return }
      autoplaySecondsRemaining = nil
      state = .playing(nextVideo)
    } catch {
      guard isCurrent(requestGeneration) else { return }
      state = Task.isCancelled || error is CancellationError ? .cancelled : .unavailable
    }
  }

  public func playNext() {
    guard case .available(let nextVideo) = state else { return }
    _ = nextGeneration()
    state = .playing(nextVideo)
  }

  public func cancel() {
    switch state {
    case .loading, .available, .playing:
      _ = nextGeneration()
      state = .cancelled
    case .idle, .cancelled, .unavailable:
      break
    }
  }

  /// Sleeps the autoplay delay in steps of at most a second so the overlay
  /// can show the remaining time.
  private func countDown(_ requestGeneration: UInt64) async throws {
    var remaining = autoplayDelay
    while remaining > .zero {
      autoplaySecondsRemaining = Self.wholeSeconds(remaining)
      let step = min(remaining, .seconds(1))
      try await sleep(step)
      try Task.checkCancellation()
      guard isCurrent(requestGeneration) else { return }
      remaining -= step
    }
  }

  private func nextGeneration() -> UInt64 {
    generation &+= 1
    autoplaySecondsRemaining = nil
    return generation
  }

  private func isCurrent(_ requestGeneration: UInt64) -> Bool {
    requestGeneration == generation
  }

  private static func bounded(delay: Duration) -> Duration {
    min(max(delay, .zero), maximumAutoplayDelay)
  }

  private static func wholeSeconds(_ duration: Duration) -> Int {
    let (seconds, attoseconds) = duration.components
    return Int(seconds) + (attoseconds > 0 ? 1 : 0)
  }
}

/// A downloaded successor plays from its local file, so it keeps working
/// offline and its locally recorded position wins over the server's.
@MainActor
public func resolveSuccessorSource(
  fileID: PutioFileID,
  localSource: @MainActor (PutioFileID) -> PutioPlaybackSource?,
  resolve: PutioPlaybackResolve
) async throws -> PutioPlaybackResolution {
  if let local = localSource(fileID) { return .ready(local) }
  return try await resolve(fileID)
}

/// The server owns the successor order. When it cannot answer, a downloaded
/// successor from the offline queue keeps a finished download advancing
/// offline; a server answer of "none" is final and never consults the queue.
@MainActor
public func prepareNextVideo(
  after fileID: PutioFileID,
  findNext: @MainActor @Sendable (PutioFileID) async throws -> PutioNextVideo?,
  findOfflineNext: @MainActor (PutioFileID) -> PutioNextVideo? = { _ in nil },
  waitForPendingReports: PutioNextVideoResetWait,
  resolve: PutioPlaybackResolve
) async throws -> PutioPlayableNextVideo? {
  let found: PutioNextVideo?
  do {
    found = try await findNext(fileID)
  } catch {
    guard !(error is CancellationError), let offline = findOfflineNext(fileID) else { throw error }
    found = offline
  }
  guard let video = found else { return nil }
  await waitForPendingReports(video.id)
  try Task.checkCancellation()
  let resolution = try await resolve(video.id)
  return PutioPlayableNextVideo(video: video, initialResolution: resolution)
}
