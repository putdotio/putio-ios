import Foundation
import PutioSDK

extension PutioRuntime {
  public func listTrash(cursor: String? = nil) async throws -> PutioTrashPage {
    let result = try await performAuthenticatedOperation {
      if let cursor {
        return try await sdk.continueListTrash(cursor: cursor)
      }
      return try await sdk.listTrash()
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
    let response = try await performAuthenticatedOperation(commits: true) {
      try await sdk.restoreTrashFiles(fileIDs: [fileID.rawValue], cursor: nil)
    }
    guard response.status == "OK" else { throw PutioRuntimeError.invalidResponse }
    do {
      let restoredFile = try await performAuthenticatedOperation {
        try await sdk.getFile(fileID: fileID.rawValue)
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
