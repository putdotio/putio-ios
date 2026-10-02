import Foundation
import Observation

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

public enum PutioVideoPlaybackState: Equatable {
  case loading
  case ready(PutioPlaybackSource)
  case conversionRequired
  case conversionQueued
  case converting(progress: Double)
  case conversionCompleted
  case failed(PutioVideoPlaybackFailure)
}

public struct PutioVideoPlaybackFailure: Equatable, Sendable {
  public enum Kind: Equatable, Sendable {
    case notFound
    case rateLimited
    case transient
    case invalidResponse
    case playback
    case conversion
    case unknown
  }

  public let kind: Kind
  public let title: String
  public let message: String

  public static func resolving(_ error: Error) -> PutioVideoPlaybackFailure? {
    switch error as? PutioRuntimeError {
    case .authenticationRequired, .sessionExpired:
      return nil
    case .notFound:
      return PutioVideoPlaybackFailure(
        kind: .notFound,
        title: "Video not found",
        message: "It may have been moved or deleted."
      )
    case .rateLimited:
      return PutioVideoPlaybackFailure(
        kind: .rateLimited,
        title: "Could not open video",
        message: "put.io is receiving too many requests. Try again shortly."
      )
    case .transient:
      return PutioVideoPlaybackFailure(
        kind: .transient,
        title: "Could not open video",
        message: "Check your connection and try again."
      )
    case .invalidResponse:
      return PutioVideoPlaybackFailure(
        kind: .invalidResponse,
        title: "Could not open video",
        message: "put.io returned an invalid response. Try again."
      )
    case .unknown, nil:
      return PutioVideoPlaybackFailure(
        kind: .unknown,
        title: "Could not open video",
        message: "put.io could not prepare this video. Try again."
      )
    }
  }

  public static let playback = PutioVideoPlaybackFailure(
    kind: .playback,
    title: "Could not play video",
    message: "The video could not be played. Try again."
  )

  static let conversion = PutioVideoPlaybackFailure(
    kind: .conversion,
    title: "Could not convert video",
    message: "The conversion did not finish. Try again."
  )

  static func converting(_ error: Error) -> PutioVideoPlaybackFailure? {
    guard let failure = resolving(error) else { return nil }
    guard failure.kind != .notFound else { return failure }
    return PutioVideoPlaybackFailure(
      kind: failure.kind,
      title: "Could not convert video",
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

  public private(set) var state: PutioVideoPlaybackState = .loading

  @ObservationIgnored private let fileID: PutioFileID
  @ObservationIgnored private let resolve: PutioPlaybackResolve
  @ObservationIgnored private let startConversion: PutioVideoConversionStart
  @ObservationIgnored private let loadConversionStatus: PutioVideoConversionStatusLoad
  @ObservationIgnored private let conversionPollInterval: Duration
  @ObservationIgnored private let sleep: PutioVideoConversionSleep
  @ObservationIgnored private var initialResolution: PutioPlaybackResolution?
  @ObservationIgnored private var generation: UInt64 = 0
  @ObservationIgnored private var attemptedLoad = false
  @ObservationIgnored private var recovery: Recovery = .resolve

  public init(
    fileID: PutioFileID,
    initialResolution: PutioPlaybackResolution? = nil,
    conversionPollInterval: Duration = .seconds(3),
    startConversion: @escaping PutioVideoConversionStart = { _ in
      throw PutioRuntimeError.unknown
    },
    loadConversionStatus: @escaping PutioVideoConversionStatusLoad = { _ in
      throw PutioRuntimeError.unknown
    },
    sleep: @escaping PutioVideoConversionSleep = { try await Task.sleep(for: $0) },
    resolve: @escaping PutioPlaybackResolve
  ) {
    self.fileID = fileID
    self.initialResolution = initialResolution
    self.conversionPollInterval = conversionPollInterval
    self.startConversion = startConversion
    self.loadConversionStatus = loadConversionStatus
    self.sleep = sleep
    self.resolve = resolve
  }

  public func loadIfNeeded() async {
    guard !attemptedLoad else { return }
    attemptedLoad = true
    await recover()
  }

  public func retry() async {
    attemptedLoad = true
    await recover()
  }

  private func recover() async {
    switch recovery {
    case .resolve:
      await resolveSource()
    case .startConversion:
      await beginConversion()
    case .pollConversion:
      await pollConversion()
    case .resolveConvertedSource:
      await resolveConvertedSource()
    }
  }

  public func playerFailed() {
    guard case .ready = state else { return }
    generation &+= 1
    state = .failed(.playback)
  }

  private func resolveSource() async {
    generation &+= 1
    let requestGeneration = generation
    recovery = .resolve
    state = .loading

    do {
      try Task.checkCancellation()
      let resolution: PutioPlaybackResolution
      if let initialResolution {
        self.initialResolution = nil
        resolution = initialResolution
      } else {
        resolution = try await resolve(fileID)
      }
      try Task.checkCancellation()
      guard requestGeneration == generation else { return }

      switch resolution {
      case .ready(let source):
        state = .ready(source)
      case .conversionRequired:
        state = .conversionRequired
        await beginConversion(generation: requestGeneration)
      }
    } catch {
      guard requestGeneration == generation else { return }
      if Task.isCancelled {
        attemptedLoad = false
        return
      }
      guard let failure = PutioVideoPlaybackFailure.resolving(error) else {
        attemptedLoad = false
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
      await pollConversion(generation: requestGeneration)
    } catch {
      handleConversionError(error, generation: requestGeneration, recovery: recovery)
    }
  }

  private func pollConversion(generation existingGeneration: UInt64? = nil) async {
    let requestGeneration = existingGeneration ?? nextGeneration()
    recovery = .pollConversion

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
        }
        try await sleep(conversionPollInterval)
      }
    } catch {
      handleConversionError(error, generation: requestGeneration, recovery: .pollConversion)
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
        let resolution = try await resolve(fileID)
        try Task.checkCancellation()
        guard requestGeneration == generation else { return }
        switch resolution {
        case .ready(let source):
          state = .ready(source)
          return
        case .conversionRequired:
          attempts += 1
          guard attempts < Self.maximumConvertedSourceAttempts else {
            recovery = .startConversion
            state = .failed(.conversion)
            return
          }
          let status = try await loadConversionStatus(fileID)
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

  /// Resolution attempts after a completed conversion before giving up.
  static let maximumConvertedSourceAttempts = 10

  private func nextGeneration() -> UInt64 {
    generation &+= 1
    return generation
  }

  private func handleConversionError(
    _ error: Error,
    generation requestGeneration: UInt64,
    recovery: Recovery
  ) {
    guard requestGeneration == generation else { return }
    if Task.isCancelled {
      attemptedLoad = false
      return
    }
    guard let failure = PutioVideoPlaybackFailure.converting(error) else {
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
  private var task: Task<Void, Never>?

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
    task?.cancel()
    task = nil
  }

  deinit {
    MainActor.assumeIsolated {
      invalidate()
    }
  }
}
