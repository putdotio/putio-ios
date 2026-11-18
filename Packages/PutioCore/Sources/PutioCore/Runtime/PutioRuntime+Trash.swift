import Foundation
import PutioSDK

extension PutioRuntime {
  public func listTrash(cursor: String? = nil) async throws -> PutioTrashPage {
    let result = try await performAuthenticatedOperation {
      do {
        if let cursor {
          return try await sdk.continueListTrash(cursor: cursor)
        }
        return try await sdk.listTrash()
      } catch let error as PutioSDKError where Self.folderLoadError(error) == .offline {
        throw PutioFolderLoadError.offline
      }
    }
    if let cursor, let nextCursor = result.cursor, !nextCursor.isEmpty, nextCursor == cursor {
      throw PutioRuntimeError.invalidResponse
    }

    return PutioTrashPage(
      items: result.files.map(trashSnapshot),
      nextCursor: result.cursor?.isEmpty == false ? result.cursor : nil,
      totalCount: result.total,
      sizeBytes: result.trashSize
    )
  }

  public func restoreTrashItem(fileID: PutioFileID) async throws -> PutioTrashRestoreResult {
    try await sendTrashRestore(fileIDs: [fileID])
    return await locateRestoredTrashItem(fileID: fileID)
  }

  func locateRestoredTrashItem(fileID: PutioFileID) async -> PutioTrashRestoreResult {
    do {
      let restoredFile = try await performAuthenticatedOperation {
        try await sdk.getFile(fileID: fileID.rawValue, query: Self.fileMetadataQuery)
      }
      return .restored(destinationID: snapshot(restoredFile).parentID)
    } catch is CancellationError {
      // The restore is committed. Reporting that as a distinct result lets
      // the caller reconcile without mistaking it for a pre-commit cancel.
      return .restoredLookupCancelled
    } catch {
      return .restoredDestinationUnknown
    }
  }

  /// Deletes one trashed file. The deletion is committed once this returns;
  /// the result only reports whether the account storage snapshot followed.
  public func permanentlyDeleteTrashItem(
    fileID: PutioFileID
  ) async throws -> PutioTrashMutationResult {
    let response = try await performAuthenticatedOperation(commits: true) {
      try await sdk.deleteTrashFiles(fileIDs: [fileID.rawValue], cursor: nil)
    }
    guard response.status == "OK" else { throw PutioRuntimeError.invalidResponse }
    return PutioTrashMutationResult(
      storageRefreshed: await session.refreshAccountAfterStorageMutation())
  }

  /// Restores the given trashed files in one request.
  public func restoreTrashItems(fileIDs: [PutioFileID]) async throws {
    guard !fileIDs.isEmpty else { return }
    try await sendTrashRestore(fileIDs: fileIDs)
  }

  func sendTrashRestore(fileIDs: [PutioFileID]) async throws {
    try await sendTrashRestore {
      try await sdk.restoreTrashFiles(fileIDs: fileIDs.map(\.rawValue), cursor: nil)
    }
  }

  private func sendTrashRestore(
    _ request: () async throws -> PutioOKResponse
  ) async throws {
    let response = try await performAuthenticatedOperation(commits: true) {
      () async throws -> PutioOKResponse? in
      do {
        return try await request()
      } catch let error as PutioSDKError
        where error.matches(statusCode: 400, errorType: "TRASH_INCOMPLETE_TRASH")
      {
        return nil
      }
    }
    guard let response else { throw PutioTrashStillMoving() }
    guard response.status == "OK" else { throw PutioRuntimeError.invalidResponse }
  }

  /// Restores everything in Trash, including pages never loaded. With a
  /// listing cursor the server selects the whole listing; without one the
  /// first page was the whole Trash, so its ids are the selection.
  public func restoreAllTrash(cursor: String?, loadedFileIDs: [PutioFileID]) async throws {
    guard let cursor, !cursor.isEmpty else {
      try await restoreTrashItems(fileIDs: loadedFileIDs)
      return
    }
    try await sendTrashRestore { try await sdk.restoreTrashFiles(cursor: cursor) }
  }

  /// Permanently deletes the given trashed files in one request.
  public func permanentlyDeleteTrashItems(
    fileIDs: [PutioFileID]
  ) async throws -> PutioTrashMutationResult {
    guard !fileIDs.isEmpty else { return PutioTrashMutationResult(storageRefreshed: true) }
    let response = try await performAuthenticatedOperation(commits: true) {
      try await sdk.deleteTrashFiles(fileIDs: fileIDs.map(\.rawValue), cursor: nil)
    }
    guard response.status == "OK" else { throw PutioRuntimeError.invalidResponse }
    return PutioTrashMutationResult(
      storageRefreshed: await session.refreshAccountAfterStorageMutation())
  }

  public func emptyTrash() async throws -> PutioTrashMutationResult {
    let response = try await performAuthenticatedOperation(commits: true) {
      try await sdk.emptyTrash()
    }
    guard response.status == "OK" else { throw PutioRuntimeError.invalidResponse }
    return PutioTrashMutationResult(
      storageRefreshed: await session.refreshAccountAfterStorageMutation())
  }

  private func trashSnapshot(_ file: PutioTrashFile) -> PutioTrashItem {
    PutioTrashItem(
      id: PutioFileID(rawValue: file.id),
      parentID: PutioFileID(rawValue: file.parentID),
      name: file.name,
      kind: kind(for: file.type),
      sizeBytes: file.size,
      deletedAt: file.deletedAt,
      expiresAt: file.expiresOn
    )
  }
}
