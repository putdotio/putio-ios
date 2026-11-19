import Foundation
import Observation
import PutioSDK

public typealias PutioPlaybackResolve =
  @MainActor @Sendable (PutioFileID) async throws -> PutioPlaybackResolution
public typealias PutioPlaybackPositionReport =
  @MainActor @Sendable (PutioFileID, Int) async throws -> Void
public typealias PutioVideoConversionStart =
  @MainActor @Sendable (PutioFileID) async throws -> Void
public typealias PutioVideoConversionStatusLoad =
  @MainActor @Sendable (PutioFileID) async throws -> PutioVideoConversionStatus
public typealias PutioVideoConversionSleep =
  @MainActor @Sendable (Duration) async throws -> Void
public typealias PutioVideoStartChoice =
  @MainActor @Sendable (PutioPlaybackSource, _ afterConversion: Bool) async -> PutioPlaybackSource

public struct PutioVideoTrackChoice: Equatable, Sendable {
  public let audioLanguage: String?
  public let subtitle: PutioRememberedSubtitle?

  public init(audioLanguage: String?, subtitle: PutioRememberedSubtitle?) {
    self.audioLanguage = audioLanguage.flatMap {
      PutioSubtitleLanguage.key($0) == "und" ? nil : $0
    }
    self.subtitle = subtitle
  }
}

public struct PutioVideoConvertedHandOff: Sendable {
  public let connection: @MainActor @Sendable () -> Int?
  public let handOff:
    @MainActor @Sendable (_ startOverride: Int?, _ tracks: PutioVideoTrackChoice?) -> Bool

  public init(
    connection: @escaping @MainActor @Sendable () -> Int?,
    handOff:
      @escaping @MainActor @Sendable (_ startOverride: Int?, _ tracks: PutioVideoTrackChoice?) ->
      Bool
  ) {
    self.connection = connection
    self.handOff = handOff
  }
}

public enum PutioVideoPlaybackState: Equatable {
  case loading
  case ready(PutioPlaybackSource)
  case conversionRequired
  case conversionQueued
  case converting(progress: Double)
  case conversionCompleted
  case failed(PutioVideoPlaybackFailure)
}

extension PutioVideoPlaybackState {
  /// app.put.io's explanation of why a video waits for its conversion.
  public static let conversionExplanation =
    String(
      localized:
        "This video is not in a format that can be played in this app yet. But since you're here, we'll start transcoding.",
      bundle: .module)
}

public struct PutioVideoPlaybackFailure: Equatable, Sendable {
  public enum Kind: Equatable, Sendable {
    case notFound
    case rateLimited
    case transient
    case invalidResponse
    case playback
    case accessExpired
    case connectionLost
    case conversion
    case conversionStatus
    case conversionUnavailable
    case unsupported
    case unknown
  }

  public let kind: Kind
  public let title: String
  public let message: String

  public static func resolving(_ error: Error) -> PutioVideoPlaybackFailure? {
    if error is PutioPlaybackUnplayable { return unsupported }
    switch error as? PutioRuntimeError {
    case .authenticationRequired, .sessionExpired:
      return nil
    case .notFound:
      return PutioVideoPlaybackFailure(
        kind: .notFound,
        title: String(localized: "Video not found", bundle: .module),
        message: String(localized: "It may have been moved or deleted.", bundle: .module)
      )
    case .rateLimited:
      return PutioVideoPlaybackFailure(
        kind: .rateLimited,
        title: String(localized: "Could not open video", bundle: .module),
        message: String(
          localized: "put.io is receiving too many requests. Try again shortly.", bundle: .module)
      )
    case .transient:
      return PutioVideoPlaybackFailure(
        kind: .transient,
        title: String(localized: "Could not open video", bundle: .module),
        message: String(localized: "Check your connection and try again.", bundle: .module)
      )
    case .invalidResponse:
      return PutioVideoPlaybackFailure(
        kind: .invalidResponse,
        title: String(localized: "Could not open video", bundle: .module),
        message: String(
          localized: "put.io returned an invalid response. Try again.", bundle: .module)
      )
    case .unknown, nil:
      return PutioVideoPlaybackFailure(
        kind: .unknown,
        title: String(localized: "Could not open video", bundle: .module),
        message: String(
          localized: "put.io could not prepare this video. Try again.", bundle: .module)
      )
    }
  }

  public static let playback = PutioVideoPlaybackFailure(
    kind: .playback,
    title: String(localized: "Could not play video", bundle: .module),
    message: String(localized: "The video could not be played. Try again.", bundle: .module)
  )

  public static let accessExpired = PutioVideoPlaybackFailure(
    kind: .accessExpired,
    title: String(localized: "Couldn’t play this video", bundle: .module),
    message: String(localized: "Playback access expired. Retry to refresh it.", bundle: .module)
  )

  public static let connectionLost = PutioVideoPlaybackFailure(
    kind: .connectionLost,
    title: String(localized: "Connection lost", bundle: .module),
    message: String(localized: "Check your connection and try again.", bundle: .module)
  )

  static func player(_ fault: PutioVideoPlayerFault) -> PutioVideoPlaybackFailure {
    switch fault {
    case .accessExpired: accessExpired
    case .connectionLost: connectionLost
    case .playback: playback
    }
  }

  public static let conversion = PutioVideoPlaybackFailure(
    kind: .conversion,
    title: String(localized: "Conversion failed", bundle: .module),
    message: String(localized: "Try again later.", bundle: .module)
  )

  public static let unsupported = PutioVideoPlaybackFailure(
    kind: .unsupported,
    title: String(localized: "Can’t play this file", bundle: .module),
    message: String(
      localized: "This device can’t play the original file, and it has no converted version.",
      bundle: .module)
  )

  public static let conversionUnavailable = PutioVideoPlaybackFailure(
    kind: .conversionUnavailable,
    title: String(localized: "Can’t play this file", bundle: .module),
    message: String(localized: "This video cannot be converted.", bundle: .module)
  )

  static func checkingConversion(_ error: Error) -> PutioVideoPlaybackFailure? {
    guard let failure = resolving(error) else { return nil }
    guard failure.kind == .transient else { return converting(error) }
    return PutioVideoPlaybackFailure(
      kind: .conversionStatus,
      title: String(localized: "Can’t check conversion status", bundle: .module),
      message: failure.message
    )
  }

  static func converting(_ error: Error) -> PutioVideoPlaybackFailure? {
    guard let failure = resolving(error) else { return nil }
    guard failure.kind != .notFound else { return failure }
    return PutioVideoPlaybackFailure(
      kind: failure.kind,
      title: String(localized: "Could not convert video", bundle: .module),
      message: failure.message
    )
  }
}

@MainActor
@Observable
public final class PutioVideoPlaybackModel {
  private enum Recovery {
    case resolve
    case startConversion
    case pollConversion
    case resolveConvertedSource
  }

  private enum AccessRefresh {
    case unused
    case used
    case usedThenReady
  }

  public private(set) var state: PutioVideoPlaybackState = .loading
  public private(set) var playerAttempt: UInt64 = 0
  public private(set) var playsConvertedFallback = false

  @ObservationIgnored private let fileID: PutioFileID
  @ObservationIgnored private let resolve: PutioPlaybackResolve
  @ObservationIgnored private let resolveConverted: PutioPlaybackResolve?
  @ObservationIgnored private var resolvesConverted = false
  @ObservationIgnored private let startConversion: PutioVideoConversionStart
  @ObservationIgnored private let loadConversionStatus: PutioVideoConversionStatusLoad
  @ObservationIgnored private let conversionPollInterval: Duration
  @ObservationIgnored private let sleep: PutioVideoConversionSleep
  @ObservationIgnored private let chooseStart: PutioVideoStartChoice
  @ObservationIgnored private let handOffConverted: PutioVideoConvertedHandOff?
  @ObservationIgnored private var keptConnection: Int?
  @ObservationIgnored private var chosenStart: (saved: Int, start: Int)?
  @ObservationIgnored private var playingStartOverride: Int?
  @ObservationIgnored private var awaitsFirstPlay = false
  @ObservationIgnored private var initialResolution: PutioPlaybackResolution?
  @ObservationIgnored private let storedResolution: PutioPlaybackResolution?
  @ObservationIgnored private var generation: UInt64 = 0
  @ObservationIgnored private var attemptedLoad = false
  @ObservationIgnored private var recovery: Recovery = .resolve
  @ObservationIgnored private var heldSeconds: Int?
  @ObservationIgnored private var accessRefresh = AccessRefresh.unused

  public init(
    fileID: PutioFileID,
    initialResolution: PutioPlaybackResolution? = nil,
    conversionPollInterval: Duration = PutioVideoPlaybackModel.conversionPollInterval,
    startConversion: @escaping PutioVideoConversionStart = { _ in
      throw PutioRuntimeError.unknown
    },
    loadConversionStatus: @escaping PutioVideoConversionStatusLoad = { _ in
      throw PutioRuntimeError.unknown
    },
    sleep: @escaping PutioVideoConversionSleep = { try await Task.sleep(for: $0) },
    chooseStart: @escaping PutioVideoStartChoice = { source, _ in source },
    handOffConverted: PutioVideoConvertedHandOff? = nil,
    resolveConverted: PutioPlaybackResolve? = nil,
    resolve: @escaping PutioPlaybackResolve
  ) {
    self.fileID = fileID
    self.initialResolution = initialResolution
    if case .ready(let source) = initialResolution, source.isStoredOriginal {
      storedResolution = initialResolution
    } else {
      storedResolution = nil
    }
    self.conversionPollInterval = conversionPollInterval
    self.startConversion = startConversion
    self.loadConversionStatus = loadConversionStatus
    self.sleep = sleep
    self.chooseStart = chooseStart
    self.handOffConverted = handOffConverted
    self.resolveConverted = resolveConverted
    self.resolve = resolve
    keptConnection = handOffConverted?.connection()
  }

  public func loadIfNeeded() async {
    guard !attemptedLoad else { return }
    attemptedLoad = true
    await recover()
  }

  public func retry() async {
    attemptedLoad = true
    accessRefresh = .unused
    await recover()
  }

  private func recover() async {
    switch recovery {
    case .resolve:
      await resolveSource()
    case .startConversion:
      await beginConversion()
    case .pollConversion:
      await pollConversion(afterStart: true)
    case .resolveConvertedSource:
      await resolveConvertedSource()
    }
  }

  public func receiverConnected(
    preparing: Bool, playingAtSeconds: Int?, tracks: PutioVideoTrackChoice? = nil
  ) {
    guard case .ready = state, let handOffConverted else { return }
    if preparing, awaitsFirstPlay {
      if handOffConverted.handOff(playingStartOverride, tracks) { return }
    } else if let playingAtSeconds {
      if handOffConverted.handOff(playingAtSeconds, tracks) { return }
    }
    keptConnection = handOffConverted.connection()
  }

  public func playbackStarted() {
    awaitsFirstPlay = false
  }

  public func playerReady() {
    guard case .ready = state, accessRefresh == .used else { return }
    accessRefresh = .usedThenReady
  }

  public func playerFailed(_ fault: PutioVideoPlayerFault = .playback) {
    guard case .ready = state else { return }
    generation &+= 1
    state = .failed(.player(fault))
  }

  public func fallsBack(after fault: PutioVideoPlayerFault, beforeFirstFrame: Bool) -> Bool {
    guard case .ready(let source) = state, source.original != nil, !source.isStored else {
      return false
    }
    let refusedAfterRefresh = fault == .accessExpired && accessRefresh != .unused
    return (fault == .playback || refusedAfterRefresh) && beforeFirstFrame
      && resolveConverted != nil && !resolvesConverted
  }

  /// The report for a player failure, before `playerFailed` acts on it: a
  /// rescue when the converted copy takes over, `nil` when a refreshed
  /// source retries silently, otherwise a terminal failure.
  public func failureReport(
    _ error: PutioPlayerError, beforeFirstFrame: Bool,
    platform: PutioPlaybackFailureReport.Platform
  ) -> PutioPlaybackFailureReport? {
    guard case .ready(let source) = state else { return nil }
    let outcome: PutioPlaybackFailureReport.Outcome
    if fallsBack(after: error.fault, beforeFirstFrame: beforeFirstFrame) {
      outcome = .rescued(reason: PutioPlaybackReason.decoderError.rawValue, to: .converted)
    } else if refreshesAccess(after: error.fault, beforeFirstFrame: beforeFirstFrame) {
      return nil
    } else {
      outcome = .failed
    }
    return PutioPlaybackFailureReport(
      platform: platform, fileID: fileID, source: source, error: error,
      playbackStarted: !beforeFirstFrame, outcome: outcome)
  }

  private func refreshesAccess(after fault: PutioVideoPlayerFault, beforeFirstFrame: Bool) -> Bool {
    let refresh: AccessRefresh =
      accessRefresh == .usedThenReady ? (beforeFirstFrame ? .used : .unused) : accessRefresh
    return fault == .accessExpired && refresh == .unused && storedResolution == nil
  }

  public func playerFailed(
    _ fault: PutioVideoPlayerFault, heldSeconds: Int?, beforeFirstFrame: Bool = false
  ) async {
    guard case .ready = state else { return }
    if accessRefresh == .usedThenReady {
      accessRefresh = beforeFirstFrame ? .used : .unused
    }
    let fallsBack = fallsBack(after: fault, beforeFirstFrame: beforeFirstFrame)
    if let heldSeconds { self.heldSeconds = heldSeconds }
    recovery = .resolve
    if fallsBack {
      resolvesConverted = true
      await resolveSource()
      return
    }
    guard refreshesAccess(after: fault, beforeFirstFrame: beforeFirstFrame) else {
      generation &+= 1
      state = .failed(.player(fault))
      return
    }
    accessRefresh = .used
    await resolveSource(showsLoading: false)
  }

  private func resolveSource(showsLoading: Bool = true) async {
    generation &+= 1
    let requestGeneration = generation
    recovery = .resolve
    if showsLoading { state = .loading }

    do {
      try Task.checkCancellation()
      let resolution: PutioPlaybackResolution
      if let initialResolution {
        self.initialResolution = nil
        resolution = initialResolution
      } else if let storedResolution {
        resolution = storedResolution
      } else {
        resolution = try await resolveCurrent()
      }
      try Task.checkCancellation()
      guard requestGeneration == generation else { return }

      switch resolution {
      case .ready(let source):
        let start = await startSource(source, afterConversion: false)
        try Task.checkCancellation()
        guard requestGeneration == generation else { return }
        if showsLoading, handsOff(start, from: source) { return }
        play(start, from: source)
      case .conversionRequired:
        state = .conversionRequired
        await beginConversion(generation: requestGeneration)
      }
    } catch {
      guard requestGeneration == generation else { return }
      let failure = Task.isCancelled ? nil : PutioVideoPlaybackFailure.resolving(error)
      guard let failure else {
        attemptedLoad = false
        if !showsLoading { state = .failed(.accessExpired) }
        return
      }
      state = .failed(failure)
    }
  }

  private func beginConversion(generation existingGeneration: UInt64? = nil) async {
    let requestGeneration = existingGeneration ?? nextGeneration()
    recovery = .startConversion
    state = .conversionRequired

    do {
      try Task.checkCancellation()
      try await startConversion(fileID)
      // The server accepted the request. A cancellation from here on resumes
      // by polling instead of re-posting a second conversion.
      recovery = .pollConversion
      try Task.checkCancellation()
      guard requestGeneration == generation else { return }
      state = .conversionQueued
      await pollConversion(generation: requestGeneration, afterStart: true)
    } catch {
      handleConversionError(error, generation: requestGeneration, recovery: recovery)
    }
  }

  private func pollConversion(
    generation existingGeneration: UInt64? = nil, afterStart: Bool = false
  ) async {
    let requestGeneration = existingGeneration ?? nextGeneration()
    recovery = .pollConversion
    var startMayBePending = afterStart

    do {
      while requestGeneration == generation {
        try Task.checkCancellation()
        let status = try await loadConversionStatus(fileID)
        try Task.checkCancellation()
        guard requestGeneration == generation else { return }

        switch status {
        case .queued:
          state = .conversionQueued
        case .converting(let progress):
          state = .converting(progress: progress)
        case .completed:
          state = .conversionCompleted
          await resolveConvertedSource(generation: requestGeneration)
          return
        case .failed:
          recovery = .startConversion
          state = .failed(.conversion)
          return
        case .unavailable where startMayBePending:
          state = .conversionQueued
        case .unavailable:
          recovery = .startConversion
          state = .failed(.conversionUnavailable)
          return
        }
        startMayBePending = false
        try await sleep(conversionPollInterval)
      }
    } catch {
      handleConversionError(
        error, generation: requestGeneration, recovery: .pollConversion,
        failure: PutioVideoPlaybackFailure.checkingConversion)
    }
  }

  /// A completed conversion should resolve immediately. Each miss re-checks
  /// the conversion so a `COMPLETED → ERROR` flip fails instead of spinning,
  /// and the loop gives up after a bounded number of attempts.
  private func resolveConvertedSource(generation existingGeneration: UInt64? = nil) async {
    let requestGeneration = existingGeneration ?? nextGeneration()
    recovery = .resolveConvertedSource
    state = .conversionCompleted

    do {
      var attempts = 0
      while requestGeneration == generation {
        try Task.checkCancellation()
        let resolution = try await resolveCurrent()
        try Task.checkCancellation()
        guard requestGeneration == generation else { return }
        switch resolution {
        case .ready(let source):
          let start = await startSource(source, afterConversion: true)
          try Task.checkCancellation()
          guard requestGeneration == generation else { return }
          if handsOff(start, from: source) { return }
          play(start, from: source)
          return
        case .conversionRequired:
          attempts += 1
          guard attempts < Self.maximumConvertedSourceAttempts else {
            recovery = .startConversion
            state = .failed(.conversion)
            return
          }
          let status: PutioVideoConversionStatus
          do {
            status = try await loadConversionStatus(fileID)
          } catch {
            handleConversionError(
              error, generation: requestGeneration, recovery: .resolveConvertedSource,
              failure: PutioVideoPlaybackFailure.checkingConversion)
            return
          }
          try Task.checkCancellation()
          guard requestGeneration == generation else { return }
          switch status {
          case .completed:
            try await sleep(conversionPollInterval)
          case .queued, .converting:
            await pollConversion(generation: requestGeneration)
            return
          case .failed:
            recovery = .startConversion
            state = .failed(.conversion)
            return
          case .unavailable:
            recovery = .startConversion
            state = .failed(.conversionUnavailable)
            return
          }
        }
      }
    } catch {
      handleConversionError(
        error,
        generation: requestGeneration,
        recovery: .resolveConvertedSource
      )
    }
  }

  private func resolveCurrent() async throws -> PutioPlaybackResolution {
    guard resolvesConverted, let resolveConverted else { return try await resolve(fileID) }
    return try await resolveConverted(fileID)
  }

  private func play(_ start: PutioPlaybackSource, from source: PutioPlaybackSource) {
    playsConvertedFallback = resolvesConverted
    playingStartOverride = Self.startOverride(of: start, from: source)
    awaitsFirstPlay = true
    playerAttempt &+= 1
    state = .ready(start)
  }

  private func handsOff(_ start: PutioPlaybackSource, from source: PutioPlaybackSource) -> Bool {
    guard connectedDuringWait, let handOffConverted else { return false }
    return handOffConverted.handOff(Self.startOverride(of: start, from: source), nil)
  }

  private static func startOverride(
    of start: PutioPlaybackSource, from source: PutioPlaybackSource
  ) -> Int? {
    let choseStart =
      start.resumesAfterFailure || start.startFromSeconds != source.startFromSeconds
    return choseStart ? start.startFromSeconds : nil
  }

  private var connectedDuringWait: Bool {
    guard let connection = handOffConverted?.connection() else { return false }
    return connection != keptConnection
  }

  private func startSource(_ source: PutioPlaybackSource, afterConversion: Bool) async
    -> PutioPlaybackSource
  {
    if let heldSeconds {
      return source.resuming(at: heldSeconds)
    }
    if let chosenStart {
      guard source.startFromSeconds == chosenStart.saved else { return source }
      return source.starting(at: chosenStart.start)
    }
    let start = await chooseStart(source, afterConversion)
    if !Task.isCancelled {
      chosenStart = (source.startFromSeconds, start.startFromSeconds)
    }
    return start
  }

  public static let conversionPollInterval: Duration = .seconds(5)

  /// Resolution attempts after a completed conversion before giving up.
  static let maximumConvertedSourceAttempts = 10

  private func nextGeneration() -> UInt64 {
    generation &+= 1
    return generation
  }

  private func handleConversionError(
    _ error: Error,
    generation requestGeneration: UInt64,
    recovery: Recovery,
    failure classify: (Error) -> PutioVideoPlaybackFailure? = PutioVideoPlaybackFailure.converting
  ) {
    guard requestGeneration == generation else { return }
    if Task.isCancelled {
      attemptedLoad = false
      return
    }
    guard let failure = classify(error) else {
      attemptedLoad = false
      return
    }
    self.recovery = recovery
    state = .failed(failure)
  }
}

@MainActor
public final class PutioPlaybackPositionPipeline {
  private struct QueuedReport {
    let position: Int
    let preservesOrdering: Bool
    let report: PutioPlaybackPositionReport
  }

  private struct PendingReport {
    let sequence: UInt64
    let task: Task<Void, Never>
    var queued: [QueuedReport]
  }

  private var pendingReports: [PutioFileID: PendingReport] = [:]
  private var nextSequence: UInt64 = 0

  public init() {}

  public func enqueue(
    fileID: PutioFileID,
    position: Int,
    preservesOrdering: Bool = false,
    report: @escaping PutioPlaybackPositionReport
  ) {
    let queuedReport = QueuedReport(
      position: position,
      preservesOrdering: preservesOrdering,
      report: report
    )
    if var pendingReport = pendingReports[fileID] {
      if queuedReport.preservesOrdering || pendingReport.queued.last?.preservesOrdering == true {
        pendingReport.queued.append(queuedReport)
      } else if pendingReport.queued.isEmpty {
        pendingReport.queued = [queuedReport]
      } else {
        pendingReport.queued[pendingReport.queued.count - 1] = queuedReport
      }
      pendingReports[fileID] = pendingReport
      return
    }

    nextSequence &+= 1
    let sequence = nextSequence
    let task = Task { @MainActor [weak self] in
      var currentReport = queuedReport
      while true {
        await self?.send(currentReport, fileID: fileID, sequence: sequence)
        guard let nextReport = self?.takeQueuedReport(fileID: fileID, sequence: sequence) else {
          return
        }
        currentReport = nextReport
      }
    }
    pendingReports[fileID] = PendingReport(sequence: sequence, task: task, queued: [])
  }

  public func waitForPendingReports(fileID: PutioFileID) async {
    while let task = pendingReports[fileID]?.task {
      await task.value
    }
  }

  private func send(_ queuedReport: QueuedReport, fileID: PutioFileID, sequence: UInt64) async {
    do {
      try await queuedReport.report(fileID, queuedReport.position)
    } catch {
      guard Self.isRetryable(error) else {
        return
      }
      let mayYieldToQueuedReport = !queuedReport.preservesOrdering
      guard !mayYieldToQueuedReport || !hasQueuedReport(fileID: fileID, sequence: sequence) else {
        return
      }
      try? await Task.sleep(for: .milliseconds(250))
      guard !mayYieldToQueuedReport || !hasQueuedReport(fileID: fileID, sequence: sequence) else {
        return
      }
      try? await queuedReport.report(fileID, queuedReport.position)
    }
  }

  private func hasQueuedReport(fileID: PutioFileID, sequence: UInt64) -> Bool {
    guard let pendingReport = pendingReports[fileID], pendingReport.sequence == sequence else {
      return false
    }
    return !pendingReport.queued.isEmpty
  }

  private static func isRetryable(_ error: Error) -> Bool {
    switch error as? PutioRuntimeError {
    case .rateLimited, .transient:
      true
    case .authenticationRequired, .sessionExpired, .notFound, .invalidResponse, .unknown, nil:
      false
    }
  }

  private func takeQueuedReport(fileID: PutioFileID, sequence: UInt64) -> QueuedReport? {
    guard var pendingReport = pendingReports[fileID], pendingReport.sequence == sequence else {
      return nil
    }
    guard !pendingReport.queued.isEmpty else {
      pendingReports[fileID] = nil
      return nil
    }
    let queuedReport = pendingReport.queued.removeFirst()
    pendingReports[fileID] = pendingReport
    return queuedReport
  }
}

@MainActor
public protocol PutioPositionReportSchedule: AnyObject {
  func invalidate()
}

@MainActor
public final class PutioMonotonicPositionReportSchedule: PutioPositionReportSchedule {
  // A `let` so the nonisolated deinit can cancel it from whichever thread
  // drops the last reference.
  private let task: Task<Void, Never>

  public init(
    interval: Duration,
    sleep: @escaping @MainActor @Sendable (Duration) async throws -> Void = {
      try await Task.sleep(for: $0)
    },
    callback: @escaping @MainActor @Sendable () -> Void
  ) {
    task = Task { @MainActor in
      while !Task.isCancelled {
        do {
          try await sleep(interval)
        } catch {
          return
        }
        guard !Task.isCancelled else { return }
        callback()
      }
    }
  }

  public func invalidate() {
    task.cancel()
  }

  deinit {
    task.cancel()
  }
}
