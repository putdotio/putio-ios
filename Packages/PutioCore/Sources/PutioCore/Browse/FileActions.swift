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
typealias PutioFileWatchedUpdate =
  @MainActor @Sendable (PutioFileID, Bool) async throws -> Void
/// Deletes a batch in one request. A throw fails every item in the batch;
/// returned entries fail only those items.
typealias PutioFileBatchDelete =
  @MainActor @Sendable ([PutioFileID]) async throws -> [PutioFileID: Error]
/// Moves a batch into a folder in one request, with the same failure shape.
typealias PutioFileBatchMove =
  @MainActor @Sendable ([PutioFileID], PutioFileID) async throws -> [PutioFileID: Error]

public struct PutioFileActions: Sendable {
  /// Items per bulk request, well under the server's per-request file limit.
  static let defaultBatchSize = 100

  let createFolder: PutioFolderCreate
  let renameFile: PutioFileRename
  let deleteFile: PutioFileDelete
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
    createFolder = { name, parentID in
      try await runtime.createFolder(name: name, parentID: parentID)
    }
    renameFile = { fileID, name in
      try await runtime.renameFile(fileID: fileID, name: name)
    }
    deleteFile = { fileID in
      try await runtime.deleteFile(fileID: fileID)
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
    moveFile: @escaping PutioFileMove = { _, _ in throw PutioRuntimeError.unknown },
    deleteFiles: PutioFileBatchDelete? = nil,
    moveFiles: PutioFileBatchMove? = nil,
    batchSize: Int = PutioFileActions.defaultBatchSize,
    loadFolders: PutioFolderLoad? = nil,
    continueFolders: PutioFolderContinue? = nil,
    setSort: @escaping PutioFolderSortUpdate = { _, _ in throw PutioRuntimeError.unknown },
    setWatched: @escaping PutioFileWatchedUpdate = { _, _ in throw PutioRuntimeError.unknown },
    canDelete: @escaping @MainActor @Sendable () -> Bool = { true }
  ) {
    self.createFolder = createFolder
    self.renameFile = renameFile
    self.deleteFile = deleteFile
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
    self.canDelete = canDelete
  }
}

public struct PutioMovePickerPolicy: Sendable {
  let items: [PutioFileItem]

  init(item: PutioFileItem) {
    items = [item]
  }

  public init(items: [PutioFileItem]) {
    self.items = items
  }

  public func canMove(to destination: PutioFolderRoute) -> Bool {
    !items.isEmpty
      && items.allSatisfy { item in
        destination.id != item.parentID
          && !(item.kind == .folder && destination.id == item.id)
      }
  }

  public func folders(in contents: PutioFolderContents) -> [PutioFileItem] {
    let selectedFolderIDs = Set(
      items.lazy.filter { $0.kind == .folder }.map(\.id)
    )
    return contents.items.filter { candidate in
      candidate.kind == .folder && !selectedFolderIDs.contains(candidate.id)
    }
  }
}
