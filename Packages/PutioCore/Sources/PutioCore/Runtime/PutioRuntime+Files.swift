import Foundation
import PutioSDK

extension PutioRuntime {
  public func listFiles(parentID: PutioFileID = .root) async throws -> PutioFolderContents {
    let result = try await performAuthenticatedOperation {
      try await sdk.getFiles(parentID: parentID.rawValue)
    }
    return folderContents(from: result)
  }

  /// Lists only the folders under `parentID`, for picking a move destination.
  /// Continue with `continueFolders`; the cursor keeps the folder filter. The
  /// shared-with-you root is not a destination, so every page drops it.
  public func listFolders(parentID: PutioFileID = .root) async throws -> PutioFolderContents {
    let result = try await performAuthenticatedOperation {
      try await sdk.getFiles(
        parentID: parentID.rawValue, query: PutioFilesListQuery(fileType: .folder))
    }
    return destinations(from: result)
  }

  /// Fetches the page after `cursor` for a listing started by `listFolders`.
  public func continueFolders(cursor: String) async throws -> PutioFolderContents {
    let result = try await performAuthenticatedOperation {
      try await sdk.continueFiles(cursor: cursor)
    }
    if let nextCursor = result.cursor, !nextCursor.isEmpty, nextCursor == cursor {
      throw PutioRuntimeError.invalidResponse
    }
    return destinations(from: result)
  }

  private func destinations(from result: PutioFilesListResult) -> PutioFolderContents {
    let contents = folderContents(from: result)
    let sharedRootIDs = Set(
      result.children.filter(\.isSharedRoot).map { PutioFileID(rawValue: $0.id) })
    guard !sharedRootIDs.isEmpty else { return contents }
    return PutioFolderContents(
      folder: contents.folder,
      items: contents.items.filter { !sharedRootIDs.contains($0.id) },
      nextCursor: contents.nextCursor,
      sort: contents.sort
    )
  }

  /// Fetches the page after `cursor` for a listing started by `listFiles`.
  public func continueFiles(cursor: String) async throws -> PutioFolderContents {
    let result = try await performAuthenticatedOperation {
      try await sdk.continueFiles(cursor: cursor)
    }
    if let nextCursor = result.cursor, !nextCursor.isEmpty, nextCursor == cursor {
      throw PutioRuntimeError.invalidResponse
    }
    return folderContents(from: result)
  }

  public func searchFiles(query: String) async throws -> PutioFileSearchPage {
    let result = try await performAuthenticatedOperation {
      try await sdk.searchFiles(query: PutioFileSearchQuery(keyword: query))
    }
    return try searchPage(from: result)
  }

  public func continueFileSearch(cursor: String) async throws -> PutioFileSearchPage {
    let result = try await performAuthenticatedOperation {
      try await sdk.continueFileSearch(cursor: cursor)
    }
    if let nextCursor = result.cursor, !nextCursor.isEmpty, nextCursor == cursor {
      throw PutioRuntimeError.invalidResponse
    }
    return try searchPage(from: result)
  }

  private func searchPage(from result: PutioFileSearchResponse) throws -> PutioFileSearchPage {
    guard result.total >= 0 else { throw PutioRuntimeError.invalidResponse }
    return PutioFileSearchPage(
      items: result.files.map(snapshot),
      nextCursor: result.cursor?.isEmpty == false ? result.cursor : nil,
      totalCount: result.total
    )
  }

  /// Persists the folder's sort on the server. Callers reload the folder to see
  /// the new order.
  public func setFolderSort(folderID: PutioFileID, sort: PutioFolderSort) async throws {
    _ = try await performAuthenticatedOperation(commits: true) {
      try await sdk.setSortBy(fileId: folderID.rawValue, sortBy: sort.rawValue)
    }
  }

  /// Marks a video watched or unwatched as put.io's watch-status action does:
  /// watched stores a one-second resume position, unwatched deletes it. Only
  /// unwatched videos are offered "watched", so no real position is lost.
  public func setFileWatched(fileID: PutioFileID, watched: Bool) async throws {
    let response = try await performAuthenticatedOperation(commits: true) {
      if watched {
        try await sdk.setStartFrom(fileID: fileID.rawValue, time: 1)
      } else {
        try await sdk.resetStartFrom(fileID: fileID.rawValue)
      }
    }
    guard response.status == "OK" else { throw PutioRuntimeError.invalidResponse }
  }

  private func folderContents(from result: PutioFilesListResult) -> PutioFolderContents {
    PutioFolderContents(
      folder: result.parent.map(snapshot),
      items: result.children.map(snapshot),
      nextCursor: result.cursor?.isEmpty == false ? result.cursor : nil,
      sort: result.parent.flatMap { PutioFolderSort(rawValue: $0.sortBy) }
    )
  }

  public func createFolder(name: String, parentID: PutioFileID) async throws -> PutioFileItem {
    let folder = try await performAuthenticatedOperation {
      try await sdk.createFolder(name: name, parentID: parentID.rawValue)
    }
    return snapshot(folder)
  }

  public func renameFile(fileID: PutioFileID, name: String) async throws {
    _ = try await performAuthenticatedOperation {
      try await sdk.renameFile(fileID: fileID.rawValue, name: name)
    }
  }

  public func moveFile(fileID: PutioFileID, to parentID: PutioFileID) async throws {
    let response = try await performAuthenticatedOperation {
      try await sdk.moveFiles(fileIDs: [fileID.rawValue], parentID: parentID.rawValue)
    }

    guard response.status == "OK" else {
      throw PutioRuntimeError.invalidResponse
    }
    guard !response.errors.isEmpty else { return }
    guard response.errors.count == 1, response.errors[0].id == fileID.rawValue else {
      throw PutioRuntimeError.invalidResponse
    }

    throw runtimeError(forStructuredStatusCode: response.errors[0].statusCode)
  }

  /// Moves every file in one request. Returns the items the server reported
  /// as failed; a thrown error means none of them moved.
  public func moveFiles(
    fileIDs: [PutioFileID], to parentID: PutioFileID
  ) async throws -> [PutioFileID: PutioRuntimeError] {
    guard !fileIDs.isEmpty else { return [:] }
    let response = try await performAuthenticatedOperation {
      try await sdk.moveFiles(fileIDs: fileIDs.map(\.rawValue), parentID: parentID.rawValue)
    }
    guard response.status == "OK" else { throw PutioRuntimeError.invalidResponse }
    let requested = Set(fileIDs)
    var failures: [PutioFileID: PutioRuntimeError] = [:]
    for error in response.errors {
      let id = PutioFileID(rawValue: error.id)
      guard requested.contains(id), failures[id] == nil else {
        throw PutioRuntimeError.invalidResponse
      }
      failures[id] = runtimeError(forStructuredStatusCode: error.statusCode)
    }
    return failures
  }

  /// Deletes every file in one request; the server applies it to all or none.
  public func deleteFiles(fileIDs: [PutioFileID]) async throws {
    guard !fileIDs.isEmpty else { return }
    guard !session.isAccountPreferencesStale, !session.isUpdatingAccountPreferences else {
      throw PutioRuntimeError.transient
    }
    // The SDK throws only for HTTP errors; a 2xx body can still report failure.
    let response = try await performAuthenticatedOperation {
      try await sdk.deleteFiles(fileIDs: fileIDs.map(\.rawValue))
    }
    guard response.status == "OK" else { throw PutioRuntimeError.invalidResponse }
  }

  public func deleteFile(fileID: PutioFileID) async throws {
    guard !session.isAccountPreferencesStale, !session.isUpdatingAccountPreferences else {
      throw PutioRuntimeError.transient
    }
    _ = try await performAuthenticatedOperation {
      try await sdk.deleteFiles(fileIDs: [fileID.rawValue])
    }
  }

  public func getFile(fileID: PutioFileID) async throws -> PutioFileItem {
    guard fileID.rawValue > 0 else { throw PutioRuntimeError.invalidResponse }
    let file = try await performAuthenticatedOperation {
      try await sdk.getFile(fileID: fileID.rawValue)
    }
    guard file.id == fileID.rawValue else { throw PutioRuntimeError.invalidResponse }
    return snapshot(file)
  }

  /// Resolves the download-token URL for previews and external players.
  /// Folders have no download representation and resolve as invalid.
  public func resolveFileDownloadSource(fileID: PutioFileID) async throws
    -> PutioFileDownloadSource
  {
    guard fileID.rawValue > 0 else { throw PutioRuntimeError.invalidResponse }
    let (file, downloadToken) = try await performAuthenticatedOperation {
      (try await sdk.getFile(fileID: fileID.rawValue), session.downloadToken)
    }
    guard file.id == fileID.rawValue else { throw PutioRuntimeError.invalidResponse }
    let token = try requireDownloadToken(downloadToken)
    let item = snapshot(file)
    guard item.kind != .folder else { throw PutioRuntimeError.invalidResponse }
    return PutioFileDownloadSource(
      id: item.id, kind: item.kind, name: item.name, url: file.getDownloadURL(downloadToken: token))
  }

  private func runtimeError(forStructuredStatusCode statusCode: Int) -> PutioRuntimeError {
    switch statusCode {
    case 404:
      return .notFound
    case 429:
      return .rateLimited
    case 408, 500...599:
      return .transient
    default:
      return .unknown
    }
  }
}
