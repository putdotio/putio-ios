/// One playback's position saves: every 10 seconds once the player is ready
/// at its established position, at once on pause, seek, background and
/// error, and a final save when playback stops. A position the server already
/// holds is not sent again; a failed save is sent again on the next tick.
/// Nothing is saved while the account does not remember positions. Saves go
/// through the shared pipeline, which keeps them bounded and ordered per file.
@MainActor
public final class PutioVideoPositionReporter {
  public typealias Scheduler =
    @MainActor (
      Duration,
      @escaping @MainActor @Sendable () -> Void
    ) -> any PutioPositionReportSchedule

  public enum EndOfPlayback: Sendable {
    case resetsPosition
    case keepsPosition
  }

  public static let interval = Duration.seconds(10)

  public private(set) var isReady = false
  public private(set) var isPositionEstablished = false
  /// Set by the end save or the final sample; no later sample is reported
  /// until playback moves back into the item.
  public private(set) var hasReportedFinalPosition = false

  private let fileID: PutioFileID
  private let remembersPosition: Bool
  private let pipeline: PutioPlaybackPositionPipeline
  private let report: PutioPlaybackPositionReport
  private let currentPosition: @MainActor () -> Int?
  private let endOfPlayback: EndOfPlayback
  private let schedule: Scheduler
  private var activeSchedule: (any PutioPositionReportSchedule)?
  private var isStopped = false
  private var requestedPosition: Int?

  public init(
    fileID: PutioFileID,
    remembersPosition: Bool,
    pipeline: PutioPlaybackPositionPipeline,
    report: @escaping PutioPlaybackPositionReport,
    currentPosition: @escaping @MainActor () -> Int?,
    savedPosition: Int? = nil,
    endOfPlayback: EndOfPlayback = .resetsPosition,
    schedule: @escaping Scheduler = { interval, callback in
      PutioMonotonicPositionReportSchedule(interval: interval, callback: callback)
    }
  ) {
    self.fileID = fileID
    self.remembersPosition = remembersPosition
    self.pipeline = pipeline
    self.report = report
    self.currentPosition = currentPosition
    self.requestedPosition = savedPosition
    self.endOfPlayback = endOfPlayback
    self.schedule = schedule
  }

  /// The player is at the position it started from: after the resume seek
  /// finished, or at once when there is nothing to seek to.
  public func positionEstablished() {
    isPositionEstablished = true
  }

  public func ready() {
    guard !isStopped else { return }
    isReady = true
    startReporting()
  }

  /// Starts the cadence. Samples taken before readiness are skipped.
  public func startReporting() {
    guard !isStopped, remembersPosition, isPositionEstablished, activeSchedule == nil else {
      return
    }
    activeSchedule = schedule(Self.interval) { [weak self] in
      self?.savePosition()
    }
  }

  public func savePosition() {
    guard !isStopped, isReady, isPositionEstablished, !hasReportedFinalPosition,
      let position = currentPosition()
    else { return }
    enqueue(position)
  }

  public func playbackFailed() {
    savePosition()
    cancel()
  }

  /// Returns whether this end counts: only a ready player that reached its
  /// start position and has not ended already.
  public func playbackEnded() -> Bool {
    guard !isStopped, isReady, isPositionEstablished, !hasReportedFinalPosition else {
      return false
    }
    hasReportedFinalPosition = true
    guard remembersPosition else { return true }
    switch endOfPlayback {
    case .resetsPosition:
      enqueue(0, preservesOrdering: true)
    case .keepsPosition:
      if let position = currentPosition() {
        enqueue(position, preservesOrdering: true)
      }
    }
    return true
  }

  /// Returns whether playback moved back into the item after it ended, so
  /// samples and the final position count again.
  public func playbackRestarted() -> Bool {
    guard !isStopped, hasReportedFinalPosition else { return false }
    hasReportedFinalPosition = false
    return true
  }

  /// Takes the final sample, then ends the cadence. Call before the player
  /// lets go of its item.
  public func stop() {
    guard !isStopped else { return }
    if !hasReportedFinalPosition, isReady, isPositionEstablished,
      let position = currentPosition()
    {
      hasReportedFinalPosition = true
      enqueue(position)
    }
    cancel()
  }

  /// Ends the cadence without a final sample.
  public func cancel() {
    isStopped = true
    activeSchedule?.invalidate()
    activeSchedule = nil
  }

  private func enqueue(_ position: Int, preservesOrdering: Bool = false) {
    guard remembersPosition, preservesOrdering || position != requestedPosition else { return }
    requestedPosition = position
    let report = report
    pipeline.enqueue(
      fileID: fileID, position: position, preservesOrdering: preservesOrdering
    ) { [weak self] fileID, seconds in
      do {
        try await report(fileID, seconds)
      } catch {
        self?.saveFailed(seconds)
        throw error
      }
    }
  }

  private func saveFailed(_ position: Int) {
    if requestedPosition == position { requestedPosition = nil }
  }

  /// Whole seconds from a player clock reading; `nil` for readings that are
  /// not a real position.
  public nonisolated static func normalizedPosition(seconds: Double) -> Int? {
    guard seconds.isFinite, seconds >= 0, seconds < Double(Int.max) else { return nil }
    return Int(seconds.rounded(.down))
  }

  /// A reading within the last second counts as the end. HLS discontinuities
  /// at the end jump to the duration, which is not a restart.
  public nonisolated static func isAtEnd(positionSeconds: Double, durationSeconds: Double) -> Bool {
    guard positionSeconds.isFinite, durationSeconds.isFinite, durationSeconds > 0 else {
      return false
    }
    return positionSeconds >= durationSeconds - 1
  }
}

public enum PutioPlaybackProgress {
  public static let watchedFraction = 0.95

  public static func isWatched(positionSeconds: Int, durationSeconds: Double?) -> Bool {
    guard let durationSeconds, durationSeconds.isFinite, durationSeconds > 0 else { return false }
    return Double(positionSeconds) >= durationSeconds * watchedFraction
  }

  public static func startSeconds(savedSeconds: Int, durationSeconds: Double?) -> Int {
    guard savedSeconds > 0 else { return 0 }
    return isWatched(positionSeconds: savedSeconds, durationSeconds: durationSeconds)
      ? 0 : savedSeconds
  }
}
