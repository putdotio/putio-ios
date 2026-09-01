import Observation
import PutioCore

typealias PutioNextVideoResetWait =
  @MainActor @Sendable (PutioFileID) async -> Void
typealias PutioNextVideoLoad =
  @MainActor @Sendable (PutioFileID) async throws -> PutioPlayableNextVideo?
typealias PutioNextVideoSleep =
  @MainActor @Sendable (Duration) async throws -> Void

struct PutioPlayableNextVideo: Equatable, Sendable {
  let video: PutioNextVideo
  let initialResolution: PutioPlaybackResolution
}

enum PutioNextVideoState: Equatable {
  case idle
  case loading
  case available(PutioPlayableNextVideo)
  case playing(PutioPlayableNextVideo)
  case cancelled
  case unavailable
}

@MainActor
@Observable
final class PutioNextVideoModel {
  nonisolated static let defaultAutoplayDelay = Duration.seconds(5)
  nonisolated static let maximumAutoplayDelay = Duration.seconds(10)

  private(set) var state: PutioNextVideoState = .idle

  @ObservationIgnored private let suggestionsEnabled: Bool
  @ObservationIgnored private let autoplayEnabled: Bool
  @ObservationIgnored private let autoplayDelay: Duration
  @ObservationIgnored private let waitForReset: PutioNextVideoResetWait
  @ObservationIgnored private let loadNext: PutioNextVideoLoad
  @ObservationIgnored private let sleep: PutioNextVideoSleep
  @ObservationIgnored private var generation: UInt64 = 0

  init(
    suggestionsEnabled: Bool = true,
    autoplayEnabled: Bool,
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

  func playbackEnded(completedFileID: PutioFileID) async {
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
      guard autoplayEnabled else { return }

      do {
        try await sleep(autoplayDelay)
        try Task.checkCancellation()
      } catch {
        guard isCurrent(requestGeneration) else { return }
        if Task.isCancelled || error is CancellationError {
          state = .cancelled
        }
        return
      }

      guard isCurrent(requestGeneration) else { return }
      state = .playing(nextVideo)
    } catch {
      guard isCurrent(requestGeneration) else { return }
      state = Task.isCancelled || error is CancellationError ? .cancelled : .unavailable
    }
  }

  func playNext() {
    guard case .available(let nextVideo) = state else { return }
    _ = nextGeneration()
    state = .playing(nextVideo)
  }

  func cancel() {
    switch state {
    case .loading, .available:
      _ = nextGeneration()
      state = .cancelled
    case .idle, .playing, .cancelled, .unavailable:
      break
    }
  }

  private func nextGeneration() -> UInt64 {
    generation &+= 1
    return generation
  }

  private func isCurrent(_ requestGeneration: UInt64) -> Bool {
    requestGeneration == generation
  }

  private static func bounded(delay: Duration) -> Duration {
    min(max(delay, .zero), maximumAutoplayDelay)
  }
}

@MainActor
func prepareNextVideo(
  after fileID: PutioFileID,
  findNext: @MainActor @Sendable (PutioFileID) async throws -> PutioNextVideo?,
  waitForPendingReports: PutioNextVideoResetWait,
  resolve: PutioPlaybackResolve
) async throws -> PutioPlayableNextVideo? {
  guard let video = try await findNext(fileID) else { return nil }
  await waitForPendingReports(video.id)
  try Task.checkCancellation()
  let resolution = try await resolve(video.id)
  return PutioPlayableNextVideo(video: video, initialResolution: resolution)
}
