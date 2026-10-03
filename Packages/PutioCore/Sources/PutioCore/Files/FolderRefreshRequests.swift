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
  private let requests: PutioFolderRefreshRequests
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

  deinit {
    guard isActive else { return }
    let folderID = self.folderID
    let requests = self.requests
    let owner = self.owner
    Task { @MainActor in requests.unregister(folderID: folderID, owner: owner) }
  }
}
