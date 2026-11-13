import Foundation
import Observation

public enum PutioSharedFileCopyOutcome: Equatable, Sendable {
  case copied
  case failed
  case unconfirmed
  case concurrentLimit
  case tooManyFiles
}

public struct PutioSharedFileCopyResult: Equatable, Sendable {
  public let name: String
  public let destination: PutioFolderRoute
  public let outcome: PutioSharedFileCopyOutcome

  public var mayHaveLanded: Bool {
    outcome == .copied || outcome == .unconfirmed
  }
}

@MainActor
@Observable
public final class PutioSharedFileCopyModel {
  public static let checkInterval = Duration.milliseconds(1_500)
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
