import Foundation
import Observation

@MainActor
@Observable
public final class PutioFolderRefreshRequests {
  public private(set) var revision: UInt64 = 0
  public struct Sequence: Equatable, Sendable {
    let folder: UInt64
    let allFolders: UInt64
  }

  private var sequences: [PutioFileID: UInt64] = [:]
  private var allFoldersSequence: UInt64 = 0
  private struct Registration {
    var broadcastSequence: UInt64 = 0
    var folderSequence: UInt64 = 0
    var consumed: Sequence?
  }

  private var registrations: [PutioFileID: [UUID: Registration]] = [:]

  // Views build one as a default argument, which is evaluated nonisolated.
  nonisolated public init() {}

  func register(folderID: PutioFileID, owner: UUID) {
    guard registrations[folderID]?[owner] == nil else { return }
    registrations[folderID, default: [:]][owner] = Registration()
  }

  func unregister(folderID: PutioFileID, owner: UUID) {
    registrations[folderID]?[owner] = nil
    if registrations[folderID]?.isEmpty == true {
      registrations[folderID] = nil
      sequences[folderID] = nil
    }
  }

  public func request(folderID: PutioFileID, excludingOwner: UUID? = nil) {
    revision &+= 1
    sequences[folderID, default: 0] &+= 1
    let owners = registrations[folderID].map { Array($0.keys) } ?? []
    for owner in owners {
      guard owner != excludingOwner else { continue }
      registrations[folderID]?[owner]?.folderSequence = sequences[folderID, default: 0]
    }
  }

  public func requestAllLoadedFolders(excludingOwner: UUID? = nil) {
    revision &+= 1
    allFoldersSequence &+= 1
    for folderID in Array(registrations.keys) {
      let owners = registrations[folderID].map { Array($0.keys) } ?? []
      for owner in owners {
        guard owner != excludingOwner else { continue }
        registrations[folderID]?[owner]?.broadcastSequence = allFoldersSequence
      }
    }
  }

  /// Each mounted screen consumes its own refresh, including when Files and
  /// Search both display the same folder.
  public func sequence(for folderID: PutioFileID, owner: UUID) -> Sequence? {
    guard let registration = registrations[folderID]?[owner] else { return nil }
    let current = Sequence(
      folder: registration.folderSequence,
      allFolders: registration.broadcastSequence)
    guard current.folder > 0 || current.allFolders > 0 else { return nil }
    guard registration.consumed != current else { return nil }
    return current
  }

  public func markConsumed(_ sequence: Sequence, for folderID: PutioFileID, owner: UUID) {
    registrations[folderID]?[owner]?.consumed = sequence
  }

  public func requestRefreshes(
    after outcome: PutioFileActionOutcome, in folderID: PutioFileID, owner: UUID
  ) {
    let excludedOwner: UUID? =
      switch outcome {
      case .failed(.delete, _), .failed(.restore, _), .failed(.setWatched, _): nil
      case .succeeded, .failed: owner
      }
    switch outcome.action {
    case .delete, .restore:
      requestAllLoadedFolders(excludingOwner: excludedOwner)
    default:
      request(folderID: folderID, excludingOwner: excludedOwner)
    }
    switch outcome.action {
    case .rename(let fileID, _, _):
      request(folderID: fileID)
    case .move(let fileID, _, _, let destinationID, _):
      request(folderID: fileID)
      request(folderID: destinationID)
    default:
      break
    }
  }

  func requestRefreshes(
    after outcome: PutioBulkFileOutcome, in folderID: PutioFileID, owner: UUID
  ) {
    switch outcome.action {
    case .delete:
      requestAllLoadedFolders(excludingOwner: owner)
    case .setWatched:
      request(folderID: folderID, excludingOwner: owner)
    case .move(let destination):
      request(folderID: folderID, excludingOwner: owner)
      request(folderID: destination.id)
      let movedIDs = Set(outcome.succeeded.map(\.id) + outcome.failures.map(\.item.id))
      for id in movedIDs {
        request(folderID: id)
      }
    }
  }
}

/// Lives in a folder screen's `@State`. SwiftUI releases that state only when
/// the screen is discarded (a pop, not a tab switch), which is exactly when
/// the folder's refresh registration should go.
///
/// The view struct's initializer runs on every parent re-render and builds a
/// throwaway instance each time; only the instance SwiftUI retains ever calls
/// `activate()`, so only that one registers and unregisters.
@MainActor
public final class PutioFolderRefreshRegistration {
  private let folderID: PutioFileID
  let requests: PutioFolderRefreshRequests
  public let owner = UUID()
  private var isActive = false

  public init(folderID: PutioFileID, requests: PutioFolderRefreshRequests) {
    self.folderID = folderID
    self.requests = requests
  }

  public func activate() {
    guard !isActive else { return }
    isActive = true
    requests.register(folderID: folderID, owner: owner)
  }

  public var pendingSequence: PutioFolderRefreshRequests.Sequence? {
    requests.sequence(for: folderID, owner: owner)
  }

  /// Activates the registration and runs the folder's first load. A fresh
  /// load already reflects any request that predates it.
  @discardableResult
  public func loadIfNeeded(_ model: PutioFolderModel) async -> Bool {
    activate()
    return await consuming { await model.loadIfNeeded() }
  }

  @discardableResult
  public func refresh(_ model: PutioFolderModel) async -> Bool {
    await consuming { await model.refresh() }
  }

  /// Serves a pending request once the folder is loaded. A request stays
  /// pending until a refresh ran; one queued behind a mutation is awaited so
  /// its success consumes the request too.
  @discardableResult
  public func refreshPending(_ model: PutioFolderModel) async -> Bool {
    guard model.isLoaded, pendingSequence != nil else { return false }
    return await consuming { await model.refreshWhenIdle() }
  }

  @discardableResult
  public func retry(_ model: PutioFolderModel) async -> Bool {
    await consuming {
      await model.retry()
      return model.isLoaded
    }
  }

  @discardableResult
  public func retryKeepingFailure(_ model: PutioFolderModel) async -> Bool {
    await consuming { await model.retryKeepingFailure() }
  }

  /// Runs a mutation, then asks the other mounted screens to refresh. The
  /// request follows the mutation, not the screen, so it is sent even if the
  /// screen closed meanwhile. A failed mutation may still have reached the
  /// server and the model only rolls back, so this screen refreshes too.
  public func mutate(
    _ scope: PutioFolderMutationScope, operation: @MainActor () async -> Bool
  ) async {
    let committed = await operation()
    let excluded = committed ? owner : nil
    switch scope {
    case .allFolders: requests.requestAllLoadedFolders(excludingOwner: excluded)
    case .folder(let id): requests.request(folderID: id, excludingOwner: excluded)
    }
  }

  private func consuming(_ operation: @MainActor () async -> Bool) async -> Bool {
    let pending = pendingSequence
    let succeeded = await operation()
    if succeeded, let pending, !Task.isCancelled {
      requests.markConsumed(pending, for: folderID, owner: owner)
    }
    return succeeded
  }

  deinit {
    guard isActive else { return }
    let folderID = self.folderID
    let requests = self.requests
    let owner = self.owner
    Task { @MainActor in requests.unregister(folderID: folderID, owner: owner) }
  }
}

public enum PutioFolderMutationScope: Equatable, Sendable {
  /// A deleted folder can contain any other mounted folder.
  case allFolders
  case folder(PutioFileID)
}
