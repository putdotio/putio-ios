import Foundation
import Observation

public enum PutioSharedFileCopyOutcome: Equatable, Sendable {
  case copied
  case failed
  /// The copy may have started, but no answer said it finished.
  case unconfirmed
  case concurrentLimit
  case tooManyFiles
}

public struct PutioSharedFileCopyResult: Equatable, Sendable {
  public let name: String
  public let destination: PutioFolderRoute
  public let outcome: PutioSharedFileCopyOutcome

  /// The copy may have landed, so the destination's listing is stale.
  public var mayHaveLanded: Bool {
    outcome == .copied || outcome == .unconfirmed
  }
}

/// Copies one shared file into the user's own folder, then checks put.io
/// until the copy settles, as the Android app does. One copy runs at a time.
/// Cancelling the caller stops the checks; a started copy keeps running on
/// put.io.
@MainActor
@Observable
public final class PutioSharedFileCopyModel {
  public static let checkInterval = Duration.milliseconds(1_500)
  /// About five minutes of checks, as on Android.
  public static let maxChecks = 200

  public private(set) var isRunning = false

  @ObservationIgnored private let actions: PutioFileActions
  @ObservationIgnored private let sleep: @Sendable (Duration) async throws -> Void

  public convenience init(actions: PutioFileActions) {
    self.init(actions: actions) { try await Task.sleep(for: $0) }
  }

  init(actions: PutioFileActions, sleep: @escaping @Sendable (Duration) async throws -> Void) {
    self.actions = actions
    self.sleep = sleep
  }

  /// Returns `nil` when a copy is already running or the caller went away
  /// before the copy settled.
  public func copy(
    _ item: PutioFileItem, to destination: PutioFolderRoute
  ) async -> PutioSharedFileCopyResult? {
    guard !isRunning, item.isShared, !item.isSharedRoot, item.kind != .folder else { return nil }
    isRunning = true
    defer { isRunning = false }
    let outcome = await settle(item, in: destination)
    return outcome.map {
      PutioSharedFileCopyResult(name: item.name, destination: destination, outcome: $0)
    }
  }

  private func settle(
    _ item: PutioFileItem, in destination: PutioFolderRoute
  ) async -> PutioSharedFileCopyOutcome? {
    let start = actions.copySharedFile
    // Unstructured, so leaving the screen never abandons a request put.io
    // may already be applying.
    let started = await Task { @MainActor in
      try await start(item.id, destination.id)
    }.result
    let copyID: Int
    switch started {
    case .success(let id):
      copyID = id
    case .failure(let error):
      return Self.startFailure(error)
    }
    for _ in 0..<Self.maxChecks {
      do {
        try await sleep(Self.checkInterval)
      } catch {
        return nil
      }
      do {
        switch try await actions.sharedFileCopyProgress(copyID) {
        case .done: return .copied
        case .failed: return .failed
        case .running: continue
        }
      } catch {
        return Task.isCancelled || error is CancellationError ? nil : .unconfirmed
      }
    }
    return .unconfirmed
  }

  private static func startFailure(_ error: Error) -> PutioSharedFileCopyOutcome {
    switch error {
    case PutioSharedFileCopyRefusal.concurrentLimit: .concurrentLimit
    case PutioSharedFileCopyRefusal.tooManyFiles: .tooManyFiles
    case PutioSharedFileCopyRefusal.rejected: .failed
    case let error as PutioRuntimeError:
      switch error {
      case .transient, .invalidResponse, .unknown: .unconfirmed
      case .authenticationRequired, .sessionExpired, .notFound, .rateLimited: .failed
      }
    default: .unconfirmed
    }
  }
}
