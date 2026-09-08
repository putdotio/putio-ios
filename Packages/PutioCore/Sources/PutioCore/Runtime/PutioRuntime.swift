import Foundation
import PutioSDK

@MainActor
public final class PutioRuntime {
  public let session: PutioSessionStore

  private let sdk: PutioSDK

  public init(
    clientID: String,
    clientName: String,
    callbackScheme: String = "putio",
    tokenStore: PutioTokenStore = PutioKeychainTokenStore(),
    urlSession: URLSession = .shared
  ) {
    let sdk = PutioSDK(
      config: PutioSDKConfig(clientID: clientID, clientName: clientName),
      urlSession: urlSession
    )
    self.sdk = sdk
    self.session = PutioSessionStore(
      sdk: sdk,
      tokenStore: tokenStore,
      callbackScheme: callbackScheme
    )
  }

  public func listFiles(parentID: PutioFileID = .root) async throws -> PutioFolderContents {
    let result = try await performAuthenticatedOperation {
      try await sdk.getFiles(parentID: parentID.rawValue)
    }
    return folderContents(from: result)
  }

  /// Fetches the page after `cursor` for a listing started by `listFiles`.
  public func continueFiles(cursor: String) async throws -> PutioFolderContents {
    let result = try await performAuthenticatedOperation {
      try await sdk.continueFiles(cursor: cursor)
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

  public func deleteFile(fileID: PutioFileID) async throws {
    guard !session.isAccountPreferencesStale, !session.isUpdatingAccountPreferences else {
      throw PutioRuntimeError.transient
    }
    _ = try await performAuthenticatedOperation {
      try await sdk.deleteFiles(fileIDs: [fileID.rawValue])
    }
  }

  public func setDefaultFolderSort(_ sort: PutioFolderSort) async throws
    -> PutioAccountPreferencesMutationResult
  {
    try await savePreferences(.init(sortBy: sort.rawValue), defaultSort: sort)
  }

  public func setTrashEnabled(_ enabled: Bool) async throws
    -> PutioAccountPreferencesMutationResult
  {
    try await savePreferences(.init(trashEnabled: enabled), storageChanged: !enabled)
  }

  public func setHistoryEnabled(_ enabled: Bool) async throws
    -> PutioAccountPreferencesMutationResult
  {
    try await savePreferences(.init(historyEnabled: enabled))
  }

  public func resetFolderSorts() async throws -> PutioAccountPreferencesMutationResult {
    let response = try await performAuthenticatedOperation(commits: true) {
      try await sdk.resetFileSpecificSortSettings()
    }
    guard response.status == "OK" else { throw PutioRuntimeError.invalidResponse }
    return await preferencesMutationResult(storageChanged: false)
  }

  public func refreshAccountPreferences() async -> Bool {
    await session.refreshAccount()
  }

  private func savePreferences(
    _ patch: PutioAccountSettingsPatch, storageChanged: Bool = false,
    defaultSort: PutioFolderSort? = nil
  ) async throws -> PutioAccountPreferencesMutationResult {
    guard case .signedIn = session.state else { throw currentSessionError }
    guard !session.isUpdatingAccountPreferences else { throw PutioRuntimeError.transient }
    let generation = session.authenticationGeneration
    session.beginAccountPreferencesUpdate()
    defer { session.endAccountPreferencesUpdate(generation: generation) }
    do {
      let response = try await performAuthenticatedOperation(commits: true) {
        try await sdk.saveAccountSettings(.patch(patch))
      }
      guard response.status == "OK" else { throw PutioRuntimeError.invalidResponse }
    } catch {
      guard generation == session.authenticationGeneration, case .signedIn = session.state else {
        throw error
      }
      // A lost response does not establish whether the server committed the
      // write. Reconcile before offering another potentially destructive save.
      let refreshed = await session.refreshAccountAfterPreferencesMutation(
        storageChanged: storageChanged)
      if refreshed, case .signedIn(let account) = session.state,
        generation == session.authenticationGeneration,
        defaultSort.map({ account.defaultSort == $0 }) ?? true,
        patch.trashEnabled.map({ account.trashEnabled == $0 }) ?? true,
        patch.historyEnabled.map({ account.historyEnabled == $0 }) ?? true
      {
        return PutioAccountPreferencesMutationResult(accountRefreshed: true)
      }
      throw error
    }
    // These values are acknowledged by the write, even if the following account
    // reload fails. In particular, stale Trash copy must not promise recovery.
    session.applyAcknowledgedPreferences(
      defaultSort: defaultSort, trashEnabled: patch.trashEnabled,
      historyEnabled: patch.historyEnabled)
    return await preferencesMutationResult(storageChanged: storageChanged)
  }

  private func preferencesMutationResult(storageChanged: Bool) async
    -> PutioAccountPreferencesMutationResult
  {
    PutioAccountPreferencesMutationResult(
      accountRefreshed: await session.refreshAccountAfterPreferencesMutation(
        storageChanged: storageChanged))
  }

  public func getFile(fileID: PutioFileID) async throws -> PutioFileItem {
    guard fileID.rawValue > 0 else { throw PutioRuntimeError.invalidResponse }
    let file = try await performAuthenticatedOperation {
      try await sdk.getFile(fileID: fileID.rawValue)
    }
    guard file.id == fileID.rawValue else { throw PutioRuntimeError.invalidResponse }
    return snapshot(file)
  }

  public func listHistory(before: Int? = nil) async throws -> PutioHistoryPage {
    if let before, before <= 0 { throw PutioRuntimeError.invalidResponse }
    let response = try await performAuthenticatedOperation {
      try await sdk.getHistoryEvents(query: PutioHistoryEventsQuery(perPage: 50, before: before))
    }
    guard response.status == "OK", response.events.allSatisfy({ $0.id > 0 }) else {
      throw PutioRuntimeError.invalidResponse
    }
    var nextBefore: Int?
    if response.hasMore {
      guard let lastID = response.events.last?.id, before.map({ lastID < $0 }) ?? true else {
        throw PutioRuntimeError.invalidResponse
      }
      nextBefore = lastID
    }
    return PutioHistoryPage(
      items: response.events.compactMap(historySnapshot), nextBefore: nextBefore)
  }

  public func deleteHistoryEvent(id: Int) async throws {
    guard id > 0 else { throw PutioRuntimeError.invalidResponse }
    let response = try await performAuthenticatedOperation(commits: true) {
      try await sdk.deleteHistoryEvent(eventID: id)
    }
    guard response.status == "OK" else { throw PutioRuntimeError.invalidResponse }
  }

  public func clearHistory() async throws {
    let response = try await performAuthenticatedOperation(commits: true) {
      try await sdk.clearHistoryEvents()
    }
    guard response.status == "OK" else { throw PutioRuntimeError.invalidResponse }
  }

  private func historySnapshot(_ event: PutioHistoryEvent) -> PutioHistoryEventItem? {
    let kind: PutioHistoryEventKind
    switch event {
    case let event as PutioUploadEvent:
      kind = .upload(
        name: event.fileName, sizeBytes: event.fileSize, fileID: historyFileID(event.fileID))
    case let event as PutioFileSharedEvent:
      kind = .fileShared(
        name: event.fileName, sharingUserName: event.sharingUserName,
        fileID: historyFileID(event.fileID))
    case let event as PutioTransferCompletedEvent:
      kind = .transferCompleted(
        name: event.transferName, sizeBytes: event.transferSize, fileID: historyFileID(event.fileID)
      )
    case let event as PutioTransferErrorEvent:
      kind = .transferError(name: event.transferName)
    case let event as PutioFileFromRSSDeletedErrorEvent:
      kind = .fileFromRSSDeleted(name: event.fileName, sizeBytes: event.fileSize)
    case let event as PutioRSSFilterPausedEvent:
      kind = .rssFilterPaused(title: event.rssFilterTitle)
    case let event as PutioTransferFromRSSErrorEvent:
      kind = .transferFromRSSError(name: event.transferName)
    case let event as PutioTransferCallbackErrorEvent:
      kind = .transferCallbackError(name: event.transferName)
    default:
      return nil
    }
    return PutioHistoryEventItem(id: event.id, createdAt: event.createdAt, kind: kind)
  }

  private func historyFileID(_ value: Int) -> PutioFileID? {
    value > 0 ? PutioFileID(rawValue: value) : nil
  }

  public func listTrash(cursor: String? = nil) async throws -> PutioTrashPage {
    let result = try await performAuthenticatedOperation {
      if let cursor {
        return try await sdk.continueListTrash(cursor: cursor)
      }
      return try await sdk.listTrash()
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

  /// Retries only the account storage snapshot after a committed Trash
  /// mutation whose refresh failed. See `PutioSessionStore.isAccountStorageStale`.
  public func refreshAccountStorage() async -> Bool {
    await session.refreshAccount()
  }

  public func findNextVideo(after fileID: PutioFileID) async throws -> PutioNextVideo? {
    let nextFile = try await performAuthenticatedOperation {
      try await sdk.findNextFileIfAvailable(fileID: fileID.rawValue, fileType: .video)
    }
    guard let nextFile else { return nil }

    return PutioNextVideo(
      id: PutioFileID(rawValue: nextFile.id),
      parentID: PutioFileID(rawValue: nextFile.parentID),
      name: nextFile.name
    )
  }

  public func resolveVideoPlaybackSource(fileID: PutioFileID) async throws
    -> PutioPlaybackResolution
  {
    let resolution = try await performAuthenticatedOperation {
      try await sdk.resolveVideoPlaybackSource(fileID: fileID.rawValue)
    }

    switch resolution {
    case .ready(let source):
      return .ready(
        PutioPlaybackSource(url: source.url, startFromSeconds: source.startFrom)
      )
    case .conversionRequired:
      return .conversionRequired
    }
  }

  public func reportVideoPlaybackPosition(fileID: PutioFileID, seconds: Int) async throws {
    _ = try await performAuthenticatedOperation {
      try await sdk.setStartFrom(fileID: fileID.rawValue, time: seconds)
    }
  }

  public func startVideoConversion(fileID: PutioFileID) async throws {
    _ = try await performAuthenticatedOperation {
      try await sdk.startMp4Conversion(fileID: fileID.rawValue)
    }
  }

  public func videoConversionStatus(fileID: PutioFileID) async throws
    -> PutioVideoConversionStatus
  {
    let conversion = try await performAuthenticatedOperation {
      try await sdk.getMp4ConversionStatus(fileID: fileID.rawValue)
    }
    let progress = Double(conversion.percentDone)
    guard progress.isFinite, (0...1).contains(progress) else {
      throw PutioRuntimeError.invalidResponse
    }

    switch conversion.status {
    case .queued:
      return .queued
    case .converting:
      return .converting(progress: progress)
    case .completed:
      return .completed
    case .error, .notAvailable:
      return .failed
    default:
      throw PutioRuntimeError.invalidResponse
    }
  }

  /// A committing operation keeps a decoded success even if the task was
  /// cancelled while the response was in flight: the server already applied
  /// it, and callers must reconcile rather than treat it as never sent.
  private func performAuthenticatedOperation<Value>(
    commits: Bool = false,
    _ operation: () async throws -> Value
  ) async throws -> Value {
    guard case .signedIn = session.state else {
      throw currentSessionError
    }
    let authenticationGeneration = session.authenticationGeneration

    do {
      try Task.checkCancellation()
      let result = try await operation()
      if !commits { try Task.checkCancellation() }

      guard
        authenticationGeneration == session.authenticationGeneration,
        case .signedIn = session.state
      else {
        throw currentSessionError
      }
      return result
    } catch {
      if Task.isCancelled || isCancellation(error) {
        throw CancellationError()
      }

      guard
        authenticationGeneration == session.authenticationGeneration,
        case .signedIn = session.state
      else {
        throw currentSessionError
      }

      guard let sdkError = error as? PutioSDKError else {
        throw PutioRuntimeError.unknown
      }
      if sdkError.isAuthenticationFailure {
        session.expireSession()
        throw PutioRuntimeError.sessionExpired
      }
      if sdkError.isNotFound {
        throw PutioRuntimeError.notFound
      }
      if sdkError.isRateLimited {
        throw PutioRuntimeError.rateLimited
      }
      if sdkError.isRetryable {
        throw PutioRuntimeError.transient
      }
      if sdkError.isDecodingFailure {
        throw PutioRuntimeError.invalidResponse
      }
      throw PutioRuntimeError.unknown
    }
  }

  private var currentSessionError: PutioRuntimeError {
    if case .signedOut(let reason) = session.state, reason == .sessionExpired {
      return .sessionExpired
    }
    return .authenticationRequired
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

  private func snapshot(_ file: PutioFile) -> PutioFileItem {
    PutioFileItem(
      id: PutioFileID(rawValue: file.id),
      parentID: PutioFileID(rawValue: file.parentID),
      name: file.name,
      kind: kind(for: file.type),
      sizeBytes: file.size,
      createdAt: file.createdAt,
      updatedAt: file.updatedAt,
      resumePositionSeconds: file.startFrom
    )
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

  private func kind(for type: PutioFileType) -> PutioFileKind {
    switch type {
    case .folder:
      .folder
    case .video:
      .video
    case .audio:
      .audio
    case .image:
      .image
    case .pdf:
      .pdf
    default:
      .other(type.rawValue)
    }
  }

  private func isCancellation(_ error: Error) -> Bool {
    if error is CancellationError {
      return true
    }
    if let urlError = error as? URLError, urlError.code == .cancelled {
      return true
    }
    if let sdkError = error as? PutioSDKError {
      return isCancellation(sdkError.underlyingError)
    }
    return false
  }
}
