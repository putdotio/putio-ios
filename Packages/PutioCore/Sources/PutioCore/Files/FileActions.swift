import Foundation

public typealias PutioFolderLoad =
  @MainActor @Sendable (PutioFileID) async throws -> PutioFolderContents
public typealias PutioFolderContinue =
  @MainActor @Sendable (String) async throws -> PutioFolderContents
typealias PutioFolderSortUpdate =
  @MainActor @Sendable (PutioFileID, PutioFolderSort) async throws -> Void
typealias PutioFolderCreate =
  @MainActor @Sendable (String, PutioFileID) async throws -> PutioFileItem
typealias PutioFileRename =
  @MainActor @Sendable (PutioFileID, String) async throws -> Void
typealias PutioFileDelete =
  @MainActor @Sendable (PutioFileID) async throws -> Void
typealias PutioFileMove =
  @MainActor @Sendable (PutioFileID, PutioFileID) async throws -> Void
typealias PutioFileRestore =
  @MainActor @Sendable ([PutioFileID]) async throws -> Void
typealias PutioFileWatchedUpdate =
  @MainActor @Sendable (PutioFileID, Bool) async throws -> Void
/// Deletes a batch in one request. A throw fails every item in the batch;
/// returned entries fail only those items.
typealias PutioFileBatchDelete =
  @MainActor @Sendable ([PutioFileID]) async throws -> [PutioFileID: Error]
/// Moves a batch into a folder in one request, with the same failure shape.
typealias PutioFileBatchMove =
  @MainActor @Sendable ([PutioFileID], PutioFileID) async throws -> [PutioFileID: Error]
typealias PutioSharedFileCopyStart =
  @MainActor @Sendable (PutioFileID, PutioFileID) async throws -> Int
typealias PutioSharedFileCopyCheck =
  @MainActor @Sendable (Int) async throws -> PutioSharedFileCopyProgress

public struct PutioFileActions: Sendable {
  /// Items per bulk request, well under the server's per-request file limit.
  static let defaultBatchSize = 100

  let createFolder: PutioFolderCreate
  let renameFile: PutioFileRename
  let deleteFile: PutioFileDelete
  let deleteFilePermanently: PutioFileDelete
  let restoreFiles: PutioFileRestore
  let moveFile: PutioFileMove
  let deleteFiles: PutioFileBatchDelete
  let moveFiles: PutioFileBatchMove
  let batchSize: Int
  /// Folders-only listing for the move picker; `nil` reuses the screen's load.
  public let loadFolders: PutioFolderLoad?
  /// Continues a `loadFolders` listing; `nil` reuses the screen's continuation.
  public let continueFolders: PutioFolderContinue?
  let setSort: PutioFolderSortUpdate
  let setWatched: PutioFileWatchedUpdate
  let copySharedFile: PutioSharedFileCopyStart
  let sharedFileCopyProgress: PutioSharedFileCopyCheck
  let canDelete: @MainActor @Sendable () -> Bool

  public init(runtime: PutioRuntime) {
    canDelete = {
      !runtime.session.isAccountPreferencesStale && !runtime.session.isUpdatingAccountPreferences
    }
    setSort = { folderID, sort in
      try await runtime.setFolderSort(folderID: folderID, sort: sort)
    }
    setWatched = { fileID, watched in
      try await runtime.setFileWatched(fileID: fileID, watched: watched)
    }
    copySharedFile = { fileID, parentID in
      try await runtime.copySharedFile(fileID: fileID, to: parentID)
    }
    sharedFileCopyProgress = { copyID in
      try await runtime.sharedFileCopyProgress(copyID: copyID)
    }
    createFolder = { name, parentID in
      try await runtime.createFolder(name: name, parentID: parentID)
    }
    renameFile = { fileID, name in
      try await runtime.renameFile(fileID: fileID, name: name)
    }
    deleteFile = { fileID in
      try await runtime.deleteFile(fileID: fileID)
    }
    deleteFilePermanently = { fileID in
      try await runtime.deleteFile(fileID: fileID, permanently: true)
    }
    restoreFiles = { fileIDs in
      try await runtime.restoreTrashItems(fileIDs: fileIDs)
    }
    moveFile = { fileID, parentID in
      try await runtime.moveFile(fileID: fileID, to: parentID)
    }
    deleteFiles = { fileIDs in
      try await runtime.deleteFiles(fileIDs: fileIDs)
      return [:]
    }
    moveFiles = { fileIDs, parentID in
      try await runtime.moveFiles(fileIDs: fileIDs, to: parentID)
    }
    batchSize = Self.defaultBatchSize
    loadFolders = { parentID in
      try await runtime.listFolders(parentID: parentID)
    }
    continueFolders = { cursor in
      try await runtime.continueFolders(cursor: cursor)
    }
  }

  /// Batch closures default to one single-item call per id, so tests that
  /// only stub the single-item boundary still exercise bulk actions.
  init(
    createFolder: @escaping PutioFolderCreate,
    renameFile: @escaping PutioFileRename,
    deleteFile: @escaping PutioFileDelete,
    deleteFilePermanently: PutioFileDelete? = nil,
    restoreFiles: @escaping PutioFileRestore = { _ in throw PutioRuntimeError.unknown },
    moveFile: @escaping PutioFileMove = { _, _ in throw PutioRuntimeError.unknown },
    deleteFiles: PutioFileBatchDelete? = nil,
    moveFiles: PutioFileBatchMove? = nil,
    batchSize: Int = PutioFileActions.defaultBatchSize,
    loadFolders: PutioFolderLoad? = nil,
    continueFolders: PutioFolderContinue? = nil,
    setSort: @escaping PutioFolderSortUpdate = { _, _ in throw PutioRuntimeError.unknown },
    setWatched: @escaping PutioFileWatchedUpdate = { _, _ in throw PutioRuntimeError.unknown },
    copySharedFile: @escaping PutioSharedFileCopyStart = { _, _ in
      throw PutioRuntimeError.unknown
    },
    sharedFileCopyProgress: @escaping PutioSharedFileCopyCheck = { _ in
      throw PutioRuntimeError.unknown
    },
    canDelete: @escaping @MainActor @Sendable () -> Bool = { true }
  ) {
    self.createFolder = createFolder
    self.renameFile = renameFile
    self.deleteFile = deleteFile
    self.deleteFilePermanently = deleteFilePermanently ?? deleteFile
    self.restoreFiles = restoreFiles
    self.moveFile = moveFile
    self.deleteFiles =
      deleteFiles ?? { fileIDs in
        var failures: [PutioFileID: Error] = [:]
        for fileID in fileIDs {
          do { try await deleteFile(fileID) } catch { failures[fileID] = error }
        }
        return failures
      }
    self.moveFiles =
      moveFiles ?? { fileIDs, parentID in
        var failures: [PutioFileID: Error] = [:]
        for fileID in fileIDs {
          do { try await moveFile(fileID, parentID) } catch { failures[fileID] = error }
        }
        return failures
      }
    self.batchSize = max(1, batchSize)
    self.loadFolders = loadFolders
    self.continueFolders = continueFolders
    self.setSort = setSort
    self.setWatched = setWatched
    self.copySharedFile = copySharedFile
    self.sharedFileCopyProgress = sharedFileCopyProgress
    self.canDelete = canDelete
  }
}

public enum PutioMoveDestinationState: Equatable, Sendable {
  case available
  case currentFolder
  case intoItself
}

public struct PutioMovePickerPolicy: Sendable {
  let items: [PutioFileItem]

  public init(items: [PutioFileItem]) {
    self.items = items
  }

  /// Where the items would land after opening `path` from the root. Moved
  /// folders stay listed, so a path through one is the into-itself case.
  public func state(along path: [PutioFolderRoute]) -> PutioMoveDestinationState {
    let movedFolderIDs = Set(items.lazy.filter { $0.kind == .folder }.map(\.id))
    if path.contains(where: { movedFolderIDs.contains($0.id) }) { return .intoItself }
    let destination = path.last ?? .root
    if items.isEmpty || items.contains(where: { $0.parentID == destination.id }) {
      return .currentFolder
    }
    return .available
  }

  public static func folders(in contents: PutioFolderContents) -> [PutioFileItem] {
    contents.items.filter { $0.kind == .folder }
  }
}

/// A name the server refused, or a name action that never settled.
public struct PutioNameActionFailure: Error, Equatable, Sendable {
  public init() {}
}

/// How a single-item move ends: the destination already holds the name, so
/// the picker stays open, or it settled with an outcome to report.
public enum PutioMoveSettlement: Equatable, Sendable {
  case nameTaken(String)
  case settled(PutioFileActionOutcome?)
}

extension PutioFolderModel {
  /// Consumes the outcome of a create or rename the text field submitted,
  /// throwing when it failed or never settled. `alreadyApplied` accepts a
  /// listing that already shows the change.
  public func settleNameAction(
    matching isNameAction: (PutioFileAction) -> Bool,
    alreadyApplied: () -> Bool = { false }
  ) throws {
    guard let outcome = actionOutcome, isNameAction(outcome.action) else {
      if alreadyApplied() { return }
      throw PutioNameActionFailure()
    }
    clearActionOutcome()
    if case .failed = outcome { throw PutioNameActionFailure() }
  }

  public func settleRename(of item: PutioFileItem, to name: String) throws {
    try settleNameAction { action in
      guard case .rename(let fileID, _, _) = action else { return false }
      return fileID == item.id
    } alreadyApplied: {
      guard case .loaded(let contents) = state else { return false }
      return contents.items.contains { $0.id == item.id && $0.name == name }
    }
  }

  /// `nil` outcome when the move did not belong to `item`.
  public func settleMove(of item: PutioFileItem) -> PutioMoveSettlement {
    guard let outcome = actionOutcome,
      case .move(let fileID, _, _, _, _) = outcome.action, fileID == item.id
    else { return .settled(nil) }
    if outcome.isNameTaken(movingFileID: item.id) {
      clearActionOutcome()
      return .nameTaken(item.name)
    }
    return .settled(outcome)
  }
}

extension PutioFileItemActionModel {
  public func settleRename(of item: PutioFileItem) throws {
    guard case .succeeded(.rename) = outcome else {
      if case .failed(.rename, _) = outcome { clearOutcome() }
      throw PutioNameActionFailure()
    }
    clearOutcome()
  }

  public func settleMove(of item: PutioFileItem) -> PutioMoveSettlement {
    if outcome?.isNameTaken(movingFileID: item.id) == true {
      clearOutcome()
      return .nameTaken(item.name)
    }
    return .settled(outcome)
  }
}
