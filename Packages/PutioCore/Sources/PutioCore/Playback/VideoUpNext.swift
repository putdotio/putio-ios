import Observation

public typealias PutioUpNextFind =
  @MainActor @Sendable (PutioFileID) async throws -> PutioNextVideo?
public typealias PutioUpNextPrepare =
  @MainActor @Sendable (PutioNextVideo) async throws -> PutioPlayableNextVideo

public enum PutioUpNextState: Equatable {
  case idle
  case finding
  case countingDown(PutioNextVideo, secondsLeft: Int)
  case playing(PutioPlayableNextVideo)
  case failed
}

@MainActor
@Observable
public final class PutioVideoUpNextModel {
  public nonisolated static let countdown = Duration.seconds(10)

  public private(set) var state: PutioUpNextState = .idle
  public private(set) var upcoming: PutioNextVideo?
  public private(set) var lookupSettled = false
  /// The last successor lookup failed, so an empty `upcoming` is not a
  /// confirmed end of the folder.
  public private(set) var lookupFailed = false
  public var isPlayingChosenVideo: Bool {
    if case .finding = state, lastRequest == .chosen { return true }
    return false
  }

  private enum Lookup {
    case pending
    case found(PutioNextVideo?)
    case failed
  }

  private enum Request {
    case ended
    case chosen
  }

  @ObservationIgnored private let fileID: PutioFileID
  @ObservationIgnored private let suggestionsEnabled: Bool
  @ObservationIgnored private let autoplayEnabled: PutioNextVideoAutoplayPolicy
  @ObservationIgnored private let countdown: Duration
  @ObservationIgnored private let waitForReset: PutioNextVideoResetWait
  @ObservationIgnored private let find: PutioUpNextFind
  @ObservationIgnored private let prepare: PutioUpNextPrepare
  @ObservationIgnored private let sleep: PutioNextVideoSleep
  @ObservationIgnored private var lookup = Lookup.pending
  @ObservationIgnored private var lookupTask: Task<PutioNextVideo?, Error>?
  @ObservationIgnored private var lastRequest: Request?
  @ObservationIgnored private var generation: UInt64 = 0

  public init(
    fileID: PutioFileID,
    suggestionsEnabled: Bool = true,
    autoplayEnabled: @escaping PutioNextVideoAutoplayPolicy,
    countdown: Duration = PutioVideoUpNextModel.countdown,
    waitForReset: @escaping PutioNextVideoResetWait,
    find: @escaping PutioUpNextFind,
    prepare: @escaping PutioUpNextPrepare,
    sleep: @escaping PutioNextVideoSleep = { try await Task.sleep(for: $0) }
  ) {
    self.fileID = fileID
    self.suggestionsEnabled = suggestionsEnabled
    self.autoplayEnabled = autoplayEnabled
    self.countdown = max(countdown, .zero)
    self.waitForReset = waitForReset
    self.find = find
    self.prepare = prepare
    self.sleep = sleep
  }

  public func lookUp() async {
    defer { lookupSettled = true }
    guard suggestionsEnabled, case .pending = lookup else { return }
    _ = try? await successor()
  }

  public func playbackEnded() async {
    let request = begin(.ended)
    state = .finding
    await waitForReset(fileID)
    guard isCurrent(request) else { return }
    guard suggestionsEnabled else {
      settle(request, .idle)
      return
    }
    guard await autoplayEnabled() else {
      if case .failed = lookup { _ = try? await successor() }
      settle(request, .idle)
      return
    }
    guard isCurrent(request) else { return }
    do {
      guard let next = try await successor() else {
        settle(request, .idle)
        return
      }
      guard isCurrent(request) else { return }
      try await countDown(to: next, request)
      guard isCurrent(request) else { return }
      try await play(next, request)
    } catch {
      fail(request, error)
    }
  }

  public func playNext() async {
    let target: PutioNextVideo? =
      if case .countingDown(let next, _) = state { next } else { upcoming }
    let request = begin(.chosen)
    state = .finding
    do {
      let found: PutioNextVideo? = if let target { target } else { try await successor() }
      guard let next = found else {
        settle(request, .idle)
        return
      }
      guard isCurrent(request) else { return }
      try await play(next, request)
    } catch {
      fail(request, error)
    }
  }

  public func retry() async {
    switch lastRequest {
    case .ended?: await playbackEnded()
    case .chosen?: await playNext()
    case nil: break
    }
  }

  public func cancel() {
    switch state {
    case .finding, .countingDown, .failed:
      _ = begin(nil)
      state = .idle
    case .idle, .playing:
      break
    }
  }

  private func successor() async throws -> PutioNextVideo? {
    switch lookup {
    case .found(let next):
      return next
    case .pending, .failed:
      let task = lookupTask ?? startLookup()
      do {
        let next = try await task.value
        lookup = .found(next)
        lookupFailed = false
        upcoming = next
        return next
      } catch {
        if lookupTask == task {
          lookupTask = nil
          lookup = .failed
          lookupFailed = true
        }
        throw error
      }
    }
  }

  private func startLookup() -> Task<PutioNextVideo?, Error> {
    let find = find
    let fileID = fileID
    let task = Task { try await find(fileID) }
    lookupTask = task
    return task
  }

  private func countDown(to next: PutioNextVideo, _ request: UInt64) async throws {
    var remaining = countdown
    while remaining > .zero {
      state = .countingDown(next, secondsLeft: Self.wholeSeconds(remaining))
      let step = min(remaining, .seconds(1))
      try await sleep(step)
      try Task.checkCancellation()
      guard isCurrent(request) else { return }
      remaining -= step
    }
  }

  private func play(_ next: PutioNextVideo, _ request: UInt64) async throws {
    state = .finding
    let playable = try await prepare(next)
    try Task.checkCancellation()
    settle(request, .playing(playable))
  }

  private func begin(_ kind: Request?) -> UInt64 {
    generation &+= 1
    if let kind { lastRequest = kind }
    return generation
  }

  private func settle(_ request: UInt64, _ settled: PutioUpNextState) {
    guard isCurrent(request) else { return }
    state = settled
  }

  private func fail(_ request: UInt64, _ error: Error) {
    guard isCurrent(request) else { return }
    state = error is CancellationError || Task.isCancelled ? .idle : .failed
  }

  private func isCurrent(_ request: UInt64) -> Bool {
    request == generation
  }

  private static func wholeSeconds(_ duration: Duration) -> Int {
    let (seconds, attoseconds) = duration.components
    return Int(seconds) + (attoseconds > 0 ? 1 : 0)
  }
}
