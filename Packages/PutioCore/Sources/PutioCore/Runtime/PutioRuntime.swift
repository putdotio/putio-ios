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

  public func listPlaybackRoutes() async throws -> [PutioPlaybackRoute] {
    let routes = try await performAuthenticatedOperation { try await sdk.getRoutes() }
    var names = Set<String>()
    return try routes.map { route in
      guard !route.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
        names.insert(route.name).inserted
      else { throw PutioRuntimeError.invalidResponse }
      return PutioPlaybackRoute(name: route.name, description: route.description)
    }
  }

  public func setPlaybackRoute(name: String) async throws -> PutioAccountPreferencesMutationResult {
    guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      throw PutioRuntimeError.invalidResponse
    }
    return try await savePreferences(.init(tunnelRouteName: name))
  }

  public func setSubtitlesVisible(_ visible: Bool) async throws
    -> PutioAccountPreferencesMutationResult
  {
    try await savePreferences(.init(hideSubtitles: !visible))
  }

  public func setSubtitleAutoSelectionDisabled(_ disabled: Bool) async throws
    -> PutioAccountPreferencesMutationResult
  {
    try await savePreferences(.init(dontAutoSelectSubtitles: disabled))
  }

  public func resetFolderSorts() async throws -> PutioAccountPreferencesMutationResult {
    guard case .signedIn = session.state else { throw currentSessionError }
    guard !session.isUpdatingAccountPreferences else { throw PutioRuntimeError.transient }
    let generation = session.authenticationGeneration
    session.beginAccountPreferencesUpdate()
    defer {
      session.invalidateFolderSorts(generation: generation)
      session.endAccountPreferencesUpdate(generation: generation)
    }
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
        patch.historyEnabled.map({ account.historyEnabled == $0 }) ?? true,
        patch.tunnelRouteName.map({ account.routeName == $0 }) ?? true,
        patch.hideSubtitles.map({ account.hideSubtitles == $0 }) ?? true,
        patch.dontAutoSelectSubtitles.map({ account.dontAutoSelectSubtitles == $0 }) ?? true
      {
        return PutioAccountPreferencesMutationResult(accountRefreshed: true)
      }
      throw error
    }
    // These values are acknowledged by the write, even if the following account
    // reload fails. In particular, stale Trash copy must not promise recovery.
    session.applyAcknowledgedPreferences(
      defaultSort: defaultSort, trashEnabled: patch.trashEnabled,
      historyEnabled: patch.historyEnabled, routeName: patch.tunnelRouteName,
      hideSubtitles: patch.hideSubtitles, dontAutoSelectSubtitles: patch.dontAutoSelectSubtitles)
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

  public func resolveAudioPlaybackSource(fileID: PutioFileID) async throws -> PutioPlaybackSource {
    let source = try await performAuthenticatedOperation {
      try await sdk.resolveAudioPlaybackSource(fileID: fileID.rawValue)
    }
    return PutioPlaybackSource(url: source.url, startFromSeconds: source.startFrom)
  }

  public func findNextAudio(after fileID: PutioFileID) async throws -> PutioNextAudio? {
    let nextFile = try await performAuthenticatedOperation {
      try await sdk.findNextFileIfAvailable(fileID: fileID.rawValue, fileType: .audio)
    }
    guard let nextFile else { return nil }
    return PutioNextAudio(
      id: PutioFileID(rawValue: nextFile.id),
      parentID: PutioFileID(rawValue: nextFile.parentID),
      name: nextFile.name
    )
  }

  /// Resolves the tokened download URL for previews and external players.
  /// Folders have no download representation and resolve as invalid.
  public func resolveFileDownloadSource(fileID: PutioFileID) async throws
    -> PutioFileDownloadSource
  {
    guard fileID.rawValue > 0 else { throw PutioRuntimeError.invalidResponse }
    let (file, token) = try await performAuthenticatedOperation {
      (try await sdk.getFile(fileID: fileID.rawValue), sdk.config.token)
    }
    guard file.id == fileID.rawValue else { throw PutioRuntimeError.invalidResponse }
    let item = snapshot(file)
    guard item.kind != .folder else { throw PutioRuntimeError.invalidResponse }
    return PutioFileDownloadSource(
      id: item.id, kind: item.kind, name: item.name, url: file.getDownloadURL(token: token))
  }

  /// Saves the resume position for any media file; put.io keeps one
  /// `start_from` per file regardless of type.
  public func reportPlaybackPosition(fileID: PutioFileID, seconds: Int) async throws {
    _ = try await performAuthenticatedOperation {
      try await sdk.setStartFrom(fileID: fileID.rawValue, time: seconds)
    }
  }

  public func reportVideoPlaybackPosition(fileID: PutioFileID, seconds: Int) async throws {
    try await reportPlaybackPosition(fileID: fileID, seconds: seconds)
  }

  /// Reads the account's Chromecast playback type. Unknown or missing server
  /// values decode as HLS in the SDK.
  public func castPlaybackType() async throws -> PutioCastPlaybackType {
    let config = try await performAuthenticatedOperation { try await sdk.getConfig() }
    return PutioCastPlaybackType(config.chromecastPlaybackType)
  }

  public func setCastPlaybackType(_ playbackType: PutioCastPlaybackType) async throws {
    let response = try await performAuthenticatedOperation(commits: true) {
      try await sdk.setChromecastPlaybackType(playbackType.sdkValue)
    }
    guard response.status == "OK" else { throw PutioRuntimeError.invalidResponse }
  }

  /// Resolves a video into what a Cast receiver plays. HLS uses the tokened
  /// playlist with server-muxed subtitles; MP4 uses the converted file when
  /// available (or the original when it needs no conversion) and lists the
  /// file's subtitles as WebVTT tracks. Files that still need conversion for
  /// MP4 playback resolve as `conversionRequired`.
  public func resolveCastMedia(fileID: PutioFileID, playbackType: PutioCastPlaybackType)
    async throws -> PutioCastResolution
  {
    guard fileID.rawValue > 0 else { throw PutioRuntimeError.invalidResponse }
    let (file, token) = try await performAuthenticatedOperation {
      (
        try await sdk.getFile(
          fileID: fileID.rawValue,
          query: PutioFileDetailsQuery(
            mp4Size: false, startFrom: true, streamURL: false, mp4StreamURL: false)),
        sdk.config.token
      )
    }
    guard file.id == fileID.rawValue, file.type == .video else {
      throw PutioRuntimeError.invalidResponse
    }
    let artworkURL = URL(string: file.screenshot).flatMap { $0.scheme == "https" ? $0 : nil }
    let duration = file.metaData?.duration ?? 0
    switch playbackType {
    case .hls:
      // Same gate as the local player: put.io serves HLS for any file that
      // needs no conversion or already has its MP4, so the receiver keeps
      // the muxed-subtitle playlist after the gate instead of the MP4.
      guard !file.needConvert || file.hasMp4 else { return .conversionRequired }
      return .ready(
        PutioCastMedia(
          id: fileID, parentID: PutioFileID(rawValue: file.parentID), title: file.name,
          playbackType: .hls, url: file.getHlsStreamURL(token: token), artworkURL: artworkURL,
          durationSeconds: duration, startFromSeconds: file.startFrom, subtitles: [],
          defaultSubtitleKey: nil))
    case .mp4:
      let url: URL
      if file.hasMp4 {
        url = file.getMp4DownloadURL(token: token)
      } else if !file.needConvert {
        url = file.getDownloadURL(token: token)
      } else {
        return .conversionRequired
      }
      let response = try await performAuthenticatedOperation {
        try await sdk.getSubtitles(fileID: fileID.rawValue)
      }
      // The receiver fetches tracks itself, without the app's header, so the
      // token rides on the URL; only the API host may receive it.
      let apiHost = URL(string: sdk.config.baseURL)?.host
      var keys = Set<String>()
      let subtitles = response.subtitles.compactMap { subtitle -> PutioCastSubtitle? in
        guard !subtitle.key.isEmpty, keys.insert(subtitle.key).inserted,
          var components = URLComponents(string: subtitle.url), components.scheme == "https",
          let apiHost, components.host == apiHost
        else { return nil }
        var items = (components.queryItems ?? []).filter {
          $0.name != "oauth_token" && $0.name != "format"
        }
        items.append(URLQueryItem(name: "oauth_token", value: token))
        items.append(URLQueryItem(name: "format", value: "webvtt"))
        components.queryItems = items
        guard let url = components.url else { return nil }
        return PutioCastSubtitle(
          key: subtitle.key, language: subtitle.language, languageCode: subtitle.languageCode,
          name: subtitle.name, url: url)
      }
      let defaultKey = response.defaultKey.flatMap { key in
        subtitles.contains { $0.key == key } ? key : nil
      }
      return .ready(
        PutioCastMedia(
          id: fileID, parentID: PutioFileID(rawValue: file.parentID), title: file.name,
          playbackType: .mp4, url: url, artworkURL: artworkURL, durationSeconds: duration,
          startFromSeconds: file.startFrom, subtitles: subtitles,
          defaultSubtitleKey: defaultKey ?? subtitles.first?.key))
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
    switch conversion.status {
    case .error, .notAvailable:
      return .failed
    case .completed:
      return .completed
    case .queued:
      return .queued
    default:
      // Unknown non-terminal statuses are still in progress. Only progress
      // rows must carry a valid fraction.
      let progress = Double(conversion.percentDone)
      guard progress.isFinite, (0...1).contains(progress) else {
        throw PutioRuntimeError.invalidResponse
      }
      return .converting(progress: progress)
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

      if let rejection = error as? PutioAccountSecurityError { throw rejection }
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

extension PutioCastPlaybackType {
  init(_ value: PutioChromecastPlaybackType) {
    switch value {
    case .hls: self = .hls
    case .mp4: self = .mp4
    }
  }

  var sdkValue: PutioChromecastPlaybackType {
    switch self {
    case .hls: .hls
    case .mp4: .mp4
    }
  }
}

// MARK: - Account security and danger zone

extension PutioRuntime {
  /// Grants the account has issued, with this app's own grant flagged so it
  /// is never offered for revocation.
  public func listAuthorizedApps() async throws -> [PutioAuthorizedApp] {
    let (grants, clientID) = try await performAuthenticatedOperation {
      (try await sdk.getGrants(), sdk.config.clientID)
    }
    var ids = Set<Int>()
    return try grants.map { grant in
      guard grant.id > 0, ids.insert(grant.id).inserted else {
        throw PutioRuntimeError.invalidResponse
      }
      return PutioAuthorizedApp(
        id: grant.id, name: grant.name, description: grant.description,
        isCurrentClient: String(grant.id) == clientID)
    }
  }

  public func revokeAuthorizedApp(id: Int) async throws {
    guard id > 0 else { throw PutioRuntimeError.invalidResponse }
    let response = try await performAuthenticatedOperation(commits: true) {
      try await sdk.revokeGrant(id: id)
    }
    guard response.status == "OK" else { throw PutioRuntimeError.invalidResponse }
  }

  /// Approves a device code shown by a TV or another put.io client.
  public func linkDevice(code: String) async throws -> PutioAuthorizedApp {
    let trimmed = code.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { throw PutioAccountSecurityError.invalidDeviceCode }
    let grant = try await performAuthenticatedOperation(commits: true) {
      do {
        return try await sdk.linkDevice(code: trimmed)
      } catch let error as PutioSDKError where Self.isCodeRejection(error) {
        throw PutioAccountSecurityError.invalidDeviceCode
      }
    }
    return PutioAuthorizedApp(
      id: grant.id, name: grant.name, description: grant.description, isCurrentClient: false)
  }

  /// Starts two-factor enrollment. The returned secret goes into an
  /// authenticator app; enrollment completes with `setTwoFactorEnabled`.
  public func generateTwoFactorSecret() async throws -> String {
    let result = try await performAuthenticatedOperation(commits: true) {
      try await sdk.generateTOTP()
    }
    let secret = result.secret.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !secret.isEmpty else { throw PutioRuntimeError.invalidResponse }
    return secret
  }

  /// Enables or disables two-factor authentication with a current code. The
  /// acknowledged value lands in the snapshot even if the account reload that
  /// follows fails; the result reports whether the reload succeeded.
  public func setTwoFactorEnabled(_ enabled: Bool, code: String) async throws
    -> PutioAccountPreferencesMutationResult
  {
    let trimmed = code.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { throw PutioAccountSecurityError.invalidTwoFactorCode }
    guard case .signedIn = session.state else { throw currentSessionError }
    guard !session.isUpdatingAccountPreferences else { throw PutioRuntimeError.transient }
    let generation = session.authenticationGeneration
    session.beginAccountPreferencesUpdate()
    defer { session.endAccountPreferencesUpdate(generation: generation) }
    do {
      let response = try await performAuthenticatedOperation(commits: true) {
        do {
          return try await sdk.saveAccountSettings(
            .twoFactor(PutioTwoFactorSettings(code: trimmed, enable: enabled)))
        } catch let error as PutioSDKError where Self.isCodeRejection(error) {
          throw PutioAccountSecurityError.invalidTwoFactorCode
        }
      }
      guard response.status == "OK" else { throw PutioRuntimeError.invalidResponse }
    } catch let error as PutioAccountSecurityError {
      throw error
    } catch {
      guard generation == session.authenticationGeneration, case .signedIn = session.state else {
        throw error
      }
      // A lost response does not establish whether the write committed; the
      // account is the only truth before the user is asked for another code.
      let refreshed = await session.refreshAccountAfterPreferencesMutation(storageChanged: false)
      if refreshed, case .signedIn(let account) = session.state,
        generation == session.authenticationGeneration, account.twoFactorEnabled == enabled
      {
        return PutioAccountPreferencesMutationResult(accountRefreshed: true)
      }
      throw error
    }
    session.applyAcknowledgedPreferences(twoFactorEnabled: enabled)
    return PutioAccountPreferencesMutationResult(
      accountRefreshed: await session.refreshAccountAfterPreferencesMutation(
        storageChanged: false))
  }

  public func recoveryCodes() async throws -> [PutioTwoFactorRecoveryCode] {
    let codes = try await performAuthenticatedOperation { try await sdk.getRecoveryCodes() }
    return try Self.recoveryCodes(codes)
  }

  public func regenerateRecoveryCodes() async throws -> [PutioTwoFactorRecoveryCode] {
    let codes = try await performAuthenticatedOperation(commits: true) {
      try await sdk.regenerateRecoveryCodes()
    }
    return try Self.recoveryCodes(codes)
  }

  /// Clears the selected categories server-side, then reloads the account so
  /// storage reflects the change. Returns whether that reload succeeded.
  public func clearAccountData(_ categories: Set<PutioAccountDataCategory>) async throws -> Bool {
    guard !categories.isEmpty else { throw PutioRuntimeError.invalidResponse }
    let generation = session.authenticationGeneration
    let response: PutioOKResponse
    do {
      response = try await performAuthenticatedOperation(commits: true) {
        try await sdk.clearAccountData(
          options: PutioAccountClearOptions(
            files: categories.contains(.files),
            finishedTransfers: categories.contains(.finishedTransfers),
            activeTransfers: categories.contains(.activeTransfers),
            rssFeeds: categories.contains(.rssFeeds),
            rssLogs: categories.contains(.rssLogs),
            history: categories.contains(.history),
            trash: categories.contains(.trash),
            friends: categories.contains(.friends)))
      }
    } catch {
      // A lost response may follow a committed clear; the snapshot is stale
      // either way until it reloads.
      if generation == session.authenticationGeneration, case .signedIn = session.state {
        await session.refreshAccountAfterStorageMutation()
      }
      throw error
    }
    guard response.status == "OK" else { throw PutioRuntimeError.invalidResponse }
    return await session.refreshAccountAfterStorageMutation()
  }

  /// Destroys the account after password confirmation and ends the local
  /// session without a revocation call, since the token dies with the account.
  /// Trimming only detects a blank field; the password itself is sent as
  /// typed, since put.io may accept surrounding whitespace as part of it.
  public func destroyAccount(password: String) async throws {
    guard !password.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      throw PutioAccountSecurityError.invalidPassword
    }
    let generation = session.authenticationGeneration
    let response: PutioOKResponse
    do {
      response = try await performAuthenticatedOperation(commits: true) {
        do {
          return try await sdk.destroyAccount(currentPassword: password)
        } catch let error as PutioSDKError
          where error.apiErrorType == "INVALID_CURRENT_PASSWORD"
        {
          throw PutioAccountSecurityError.invalidPassword
        }
      }
    } catch let error as PutioAccountSecurityError {
      throw error
    } catch {
      // A lost response may follow a committed destroy. A dead credential is
      // the only proof; anything else keeps the session for a retry.
      guard generation == session.authenticationGeneration, case .signedIn = session.state else {
        throw error
      }
      if await Self.credentialIsDead(sdk) {
        session.endDestroyedSession()
        return
      }
      throw error
    }
    guard response.status == "OK" else { throw PutioRuntimeError.invalidResponse }
    session.endDestroyedSession()
  }

  private static func credentialIsDead(_ sdk: PutioSDK) async -> Bool {
    do {
      _ = try await sdk.getAccountInfo()
      return false
    } catch {
      return (error as? PutioSDKError)?.isAuthenticationFailure == true
    }
  }

  private static func recoveryCodes(_ codes: PutioTwoFactorRecoveryCodes) throws
    -> [PutioTwoFactorRecoveryCode]
  {
    guard !codes.codes.isEmpty else { throw PutioRuntimeError.invalidResponse }
    return codes.codes.map {
      PutioTwoFactorRecoveryCode(code: $0.code, isUsed: !($0.usedAt ?? "").isEmpty)
    }
  }

  // put.io reports a wrong or expired code with these types across the 2FA
  // and device-link endpoints.
  private static func isCodeRejection(_ error: PutioSDKError) -> Bool {
    ["invalid_code", "INVALID_VALUE", "code_not_found", "INVALID_CODE"].contains(
      error.apiErrorType ?? "")
  }
}
