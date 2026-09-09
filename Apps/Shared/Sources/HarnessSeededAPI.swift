import Foundation

#if DEBUG
  final class HarnessResponseDeliveryGate: @unchecked Sendable {
    private let lock = NSLock()
    private var generation: UInt64 = 0

    func begin() -> UInt64 {
      lock.lock()
      generation &+= 1
      let activeGeneration = generation
      lock.unlock()
      return activeGeneration
    }

    func cancel() {
      lock.lock()
      generation &+= 1
      lock.unlock()
    }

    func deliver(generation activeGeneration: UInt64, callbacks: () -> Void) {
      lock.lock()
      guard generation == activeGeneration else {
        lock.unlock()
        return
      }
      callbacks()
      lock.unlock()
    }
  }

  // Deterministic in-process API for signed-in harness scenarios, mirroring
  // the legacy app's E2E mock approach. Anything outside the seeded session
  // and browser surface fails loudly with a named fixture gap.
  final class HarnessSeededAPI: URLProtocol, @unchecked Sendable {
    private struct ActionFolder {
      var name: String
      var parentID: Int
    }

    private struct FilePreferences: Codable {
      var sortBy = "NAME_ASC"
      var historyEnabled = true
      var trashEnabled = true
      var overridesReset = false
      var historyCleared = false
      var routeName = "default"
      var hideSubtitles = false
      var dontAutoSelectSubtitles = false
    }

    private static let preferencesKey = "putio.harness.file-preferences.server"
    private static var usesFilePreferences: Bool {
      ProcessInfo.processInfo.arguments.contains("--putio-harness-file-preferences")
        || ProcessInfo.processInfo.arguments.contains("--putio-harness-playback-preferences")
    }
    nonisolated(unsafe) private static var filePreferences: FilePreferences?
    nonisolated(unsafe) private static var preferencesSaveFailed = false
    nonisolated(unsafe) private static var preferencesRefreshFailed = false
    nonisolated(unsafe) private static var preferencesSortCommitted = false
    nonisolated(unsafe) private static var preferencesRouteCommitted = false
    nonisolated(unsafe) private static var preferencesRoutesFailed = false

    // Caller holds fileActionsLock. The separate namespace represents the fixture server across launches.
    private static func prepareFilePreferencesLocked() {
      guard usesFilePreferences, filePreferences == nil else { return }
      if ProcessInfo.processInfo.arguments.contains("--putio-harness-reset-file-preferences") {
        UserDefaults.standard.removeObject(forKey: preferencesKey)
      }
      let stored = UserDefaults.standard.data(forKey: preferencesKey)
      filePreferences =
        stored.flatMap { try? JSONDecoder().decode(FilePreferences.self, from: $0) }
        ?? FilePreferences()
      trashEnabled = filePreferences?.trashEnabled ?? true
      historyCleared = filePreferences?.historyCleared ?? false
      if !trashEnabled { trashFolders = [:] }
    }

    private static func persistFilePreferencesLocked() {
      guard let filePreferences, let data = try? JSONEncoder().encode(filePreferences) else {
        return
      }
      UserDefaults.standard.set(data, forKey: preferencesKey)
    }

    private static func updateFilePreferences(request: URLRequest) -> (Int, String) {
      fileActionsLock.lock()
      defer { fileActionsLock.unlock() }
      prepareFilePreferencesLocked()
      guard usesFilePreferences, let payload = requestPayload(request),
        !payload.isEmpty,
        Set(payload.keys).isSubset(of: [
          "sort_by", "trash_enabled", "history_enabled", "tunnel_route_name", "hide_subtitles",
          "dont_autoselect_subtitles",
        ])
      else {
        return (
          400,
          fixtureError(
            statusCode: 400, type: "HARNESS_SETTINGS_INPUT",
            message: "Expected a file-preferences patch")
        )
      }
      if !preferencesSaveFailed {
        preferencesSaveFailed = true
        return (
          503,
          fixtureError(
            statusCode: 503, type: "HARNESS_SETTINGS_SAVE", message: "Retry saving preferences")
        )
      }
      if let sort = payload["sort_by"] as? String {
        if preferencesSortCommitted, sort == filePreferences?.sortBy {
          return (
            409,
            fixtureError(
              statusCode: 409, type: "HARNESS_SETTINGS_ALREADY_COMMITTED",
              message: "Refresh the account instead of repeating the committed save")
          )
        }
        filePreferences?.sortBy = sort
        preferencesSortCommitted = true
      }
      if let route = payload["tunnel_route_name"] as? String {
        if preferencesRouteCommitted, route == filePreferences?.routeName {
          return (
            409,
            fixtureError(
              statusCode: 409, type: "HARNESS_SETTINGS_ALREADY_COMMITTED",
              message: "Refresh instead of repeating a committed route write")
          )
        }
        filePreferences?.routeName = route
        preferencesRouteCommitted = true
      }
      if let hidden = payload["hide_subtitles"] as? Bool { filePreferences?.hideSubtitles = hidden }
      if let disabled = payload["dont_autoselect_subtitles"] as? Bool {
        filePreferences?.dontAutoSelectSubtitles = disabled
      }
      if let history = payload["history_enabled"] as? Bool {
        filePreferences?.historyEnabled = history
        if !history {
          historyCleared = true
          filePreferences?.historyCleared = true
        }
      }
      if let trash = payload["trash_enabled"] as? Bool {
        filePreferences?.trashEnabled = trash
        trashEnabled = trash
        if !trash {
          trashFreedBytes += Int64(trashFolders.count) * trashFolderBytes
          trashFolders = [:]
        }
      }
      persistFilePreferencesLocked()
      return (200, #"{"status":"OK"}"#)
    }

    private static func resetFileSorts() -> (Int, String) {
      fileActionsLock.lock()
      defer { fileActionsLock.unlock() }
      guard usesFilePreferences else {
        return (
          400,
          fixtureError(
            statusCode: 400, type: "HARNESS_SETTINGS_MODE",
            message: "File preferences fixture is required")
        )
      }
      prepareFilePreferencesLocked()
      folderSorts = [:]
      filePreferences?.overridesReset = true
      persistFilePreferencesLocked()
      return (200, #"{"status":"OK"}"#)
    }

    nonisolated(unsafe) static var isEnabled = false
    nonisolated(unsafe) static var trashEnabled = true
    nonisolated(unsafe) private static var playbackPositions = [411: 90, 412: 589, 414: 37]
    nonisolated(unsafe) private static var conversionStarted = false
    nonisolated(unsafe) private static var conversionCompleted = false
    nonisolated(unsafe) private static var conversionStartAttempts = 0
    nonisolated(unsafe) private static var conversionStatusLoads = 0
    nonisolated(unsafe) private static var harnessFolderDeleted = false
    nonisolated(unsafe) private static var harnessFolderName = "Harness Folder"
    nonisolated(unsafe) private static var actionFolders: [Int: ActionFolder] = [:]
    nonisolated(unsafe) private static var trashFolders = initialTrashFolders
    nonisolated(unsafe) private static var nextActionFolderID = 415
    nonisolated(unsafe) private static var historyRootLoads = 0
    nonisolated(unsafe) private static var historyPageFailed = false
    nonisolated(unsafe) private static var historyDeleteFailed = false
    nonisolated(unsafe) private static var historyClearFailed = false
    nonisolated(unsafe) private static var historyDeletedIDs: Set<Int> = []
    nonisolated(unsafe) private static var historyCleared = false
    nonisolated(unsafe) private static var deepLinkLookupFailed = false
    nonisolated(unsafe) private static var searchRetryFailed = false
    nonisolated(unsafe) private static var emptySearchLoads = 0
    nonisolated(unsafe) private static var searchContinuationFailed = false
    nonisolated(unsafe) private static var renameAttempts = 0
    nonisolated(unsafe) private static var logoutFailuresRemaining = 0
    nonisolated(unsafe) private static var bulkDeleteFailureDelivered = false
    nonisolated(unsafe) private static var ambiguousMoveFailureDelivered = false
    nonisolated(unsafe) private static var trashDeleteFailureDelivered = false
    nonisolated(unsafe) private static var trashListRequests = 0
    // Server-side sort per folder id; only keys the app can decode are stored.
    nonisolated(unsafe) private static var folderSorts: [Int: String] = [:]
    nonisolated(unsafe) private static var trashEmptyRefreshFailed = false
    // Bytes freed by permanent deletions; account storage reflects them.
    nonisolated(unsafe) private static var trashFreedBytes: Int64 = 0
    // The account refresh right after emptying fails once so the journey
    // proves the stale-storage warning and its retry.
    nonisolated(unsafe) private static var accountRefreshFailuresRemaining = 0
    private static let trashFolderBytes: Int64 = 1_073_741_824
    private static let diskTotalBytes: Int64 = 1_099_511_627_776
    private static let diskUsedBytes: Int64 = 30_617_800_704
    private static let playbackPositionLock = NSLock()
    private static let conversionLock = NSLock()
    private static let fileActionsLock = NSLock()
    private static let logoutLock = NSLock()
    private let deliveryGate = HarnessResponseDeliveryGate()

    static let token = "putio-harness-session-token"
    static let bulkDeleteFailureFolderID = 416
    static let ambiguousMoveFailureFolderID = 418
    static let trashRestoreFolderID = 419
    static let trashDeleteFolderID = 420
    static let trashEmptyFolderID = 421
    private static let bulkDeleteProgressFolderIDs: Set<Int> = [416, 417]

    static func configureSignOutFailure(_ enabled: Bool) {
      logoutLock.withLock { logoutFailuresRemaining = enabled ? 1 : 0 }
    }

    static func resetPlaybackPositions() {
      playbackPositionLock.lock()
      playbackPositions = [411: 90, 412: 589, 414: 37]
      playbackPositionLock.unlock()
    }

    static func resetVideoConversion() {
      conversionLock.lock()
      conversionStarted = false
      conversionCompleted = false
      conversionStartAttempts = 0
      conversionStatusLoads = 0
      conversionLock.unlock()
    }

    static func resetFileActions() {
      fileActionsLock.lock()
      actionFolders = [:]
      harnessFolderDeleted = false
      harnessFolderName = "Harness Folder"
      trashFolders = initialTrashFolders
      nextActionFolderID = 415
      historyRootLoads = 0
      historyPageFailed = false
      historyDeleteFailed = false
      historyClearFailed = false
      historyDeletedIDs = []
      historyCleared = false
      deepLinkLookupFailed = false
      searchRetryFailed = false
      emptySearchLoads = 0
      searchContinuationFailed = false
      renameAttempts = 0
      bulkDeleteFailureDelivered = false
      ambiguousMoveFailureDelivered = false
      trashDeleteFailureDelivered = false
      trashListRequests = 0
      folderSorts = [:]
      trashEmptyRefreshFailed = false
      trashFreedBytes = 0
      accountRefreshFailuresRemaining = 0
      fileActionsLock.unlock()
    }

    override class func canInit(with request: URLRequest) -> Bool {
      isEnabled && request.url?.host == "api.put.io"
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
      request
    }

    override func startLoading() {
      let generation = deliveryGate.begin()
      guard let url = request.url else {
        deliveryGate.deliver(generation: generation) {
          self.client?.urlProtocol(self, didFailWithError: URLError(.badURL))
        }
        return
      }
      let replayableRequest = Self.replayableRequest(request)
      let (statusCode, body) = Self.fixture(for: replayableRequest)
      let response = HTTPURLResponse(
        url: url,
        statusCode: statusCode,
        httpVersion: nil,
        headerFields: ["Content-Type": "application/json"]
      )!
      let deliverResponse: @Sendable () -> Void = { [weak self] in
        self?.deliveryGate.deliver(generation: generation) {
          guard let self else { return }
          self.client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
          self.client?.urlProtocol(self, didLoad: Data(body.utf8))
          self.client?.urlProtocolDidFinishLoading(self)
        }
      }
      if statusCode == 503, url.path == "/v2/files/410" {
        DispatchQueue.global().asyncAfter(deadline: .now() + 5, execute: deliverResponse)
      } else if Self.shouldDelayBulkDeleteResponse(replayableRequest) {
        DispatchQueue.global().asyncAfter(deadline: .now() + 8, execute: deliverResponse)
      } else if url.path == "/v2/trash/restore" {
        // Long enough for the journey to observe the in-flight progress overlay
        // and leave the screen, short enough that the destination refresh has
        // margin inside the journey's wait.
        DispatchQueue.global().asyncAfter(deadline: .now() + 3, execute: deliverResponse)
      } else if statusCode == 503, url.path == "/v2/files/rename" {
        DispatchQueue.global().asyncAfter(deadline: .now() + 5, execute: deliverResponse)
      } else {
        deliverResponse()
      }
    }

    override func stopLoading() {
      deliveryGate.cancel()
    }

    private static func shouldDelayBulkDeleteResponse(_ request: URLRequest) -> Bool {
      guard
        request.url?.path == "/v2/files/delete",
        let payload = requestPayload(request),
        let rawFileIDs = payload["file_ids"] as? String,
        let fileID = Int(rawFileIDs)
      else { return false }
      return bulkDeleteProgressFolderIDs.contains(fileID)
    }

    // The root's second page holds one archive so the browser proves cursor
    // continuation without changing the first-page rows the journeys pin.
    private static func continueFiles(request: URLRequest) -> (Int, String) {
      guard
        let payload = requestPayload(request),
        payload["cursor"] as? String == rootContinuationCursor
      else {
        return (
          400,
          fixtureError(
            statusCode: 400,
            type: "HARNESS_FILES_CURSOR_INVALID",
            message: "The files fixture requires the root continuation cursor"
          )
        )
      }
      return (
        200,
        """
        {
          "files": [
            {
              "id": \(rootContinuationFileID),
              "name": "Season Pack.zip",
              "file_type": "ARCHIVE",
              "parent_id": 0,
              "size": 2147483648,
              "created_at": "2026-08-27T10:00:00Z",
              "updated_at": "2026-08-27T10:00:00Z"
            }
          ]
        }
        """
      )
    }

    private static func historyFailure(_ operation: String) -> (Int, String) {
      (
        503,
        fixtureError(
          statusCode: 503, type: "HARNESS_HISTORY_RETRY", message: "Retry History \(operation)")
      )
    }

    private static func listHistory(url: URL) -> (Int, String) {
      fileActionsLock.lock()
      defer { fileActionsLock.unlock() }
      let before = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?
        .first(where: { $0.name == "before" })?.value
      if historyCleared {
        return (200, #"{"status":"OK","has_more":false,"events":[]}"#)
      }
      if before == nil {
        historyRootLoads += 1
        if historyRootLoads == 2 { return historyFailure("refresh") }
      } else {
        guard before == "807" else {
          return (
            400,
            fixtureError(
              statusCode: 400, type: "HARNESS_HISTORY_CURSOR",
              message: "History must continue after the last raw event")
          )
        }
        if !historyPageFailed {
          historyPageFailed = true
          return historyFailure("continuation")
        }
      }
      let today = Calendar.current.startOfDay(for: Date())
      let formatter = ISO8601DateFormatter()
      func event(_ id: Int, _ type: String, daysAgo: Int = 0, fields: String = "") -> String {
        let date = Calendar.current.date(byAdding: .day, value: -daysAgo, to: today) ?? today
        return
          "{\"id\":\(id),\"user_id\":1,\"type\":\(jsonString(type)),\"created_at\":\(jsonString(formatter.string(from: date)))\(fields.isEmpty ? "" : "," + fields)}"
      }
      let rows: [(Int, String)]
      if before == nil {
        rows = [
          (
            810,
            event(
              810, "upload", fields: #""file_name":"Harness Folder","file_size":0,"file_id":410"#)
          ),
          (
            809,
            event(
              809, "transfer_completed",
              fields:
                #""transfer_name":"Nested Movie.mkv","transfer_size":1073741824,"file_id":411"#)
          ),
          (
            808,
            event(
              808, "file_shared",
              fields:
                #""file_name":"Missing Share.pdf","file_size":1024,"sharing_user_name":"Fixture Friend","file_id":999"#
            )
          ),
          (807, event(807, "future_event")),
        ]
      } else {
        rows = [
          (
            806,
            event(
              806, "transfer_error", daysAgo: 1, fields: #""transfer_name":"Failed Download.zip""#)
          ),
          (
            805,
            event(
              805, "file_from_rss_deleted_for_space", daysAgo: 1,
              fields: #""file_name":"Expired Episode.mkv","file_size":1024"#)
          ),
          (
            804,
            event(
              804, "rss_filter_paused", daysAgo: 1, fields: #""rss_filter_title":"Weekly Episodes""#
            )
          ),
          (
            803,
            event(
              803, "transfer_from_rss_error", daysAgo: 3,
              fields: #""transfer_name":"Missing Episode.mkv""#)
          ),
          (
            802,
            event(
              802, "transfer_callback_error", daysAgo: 3,
              fields: #""transfer_name":"Callback Episode.mkv""#)
          ),
          (
            801,
            event(
              801, "upload", daysAgo: 3,
              fields: #""file_name":"Earlier Upload.txt","file_size":2048,"file_id":0"#)
          ),
        ]
      }
      let events = rows.filter { !historyDeletedIDs.contains($0.0) }.map(\.1).joined(separator: ",")
      return (200, "{\"status\":\"OK\",\"has_more\":\(before == nil),\"events\":[\(events)]}")
    }

    private static func deleteHistory(id: Int) -> (Int, String) {
      fileActionsLock.lock()
      defer { fileActionsLock.unlock() }
      if !historyDeleteFailed {
        historyDeleteFailed = true
        return historyFailure("deletion")
      }
      historyDeletedIDs.insert(id)
      return (200, #"{"status":"OK"}"#)
    }

    private static func clearHistory() -> (Int, String) {
      fileActionsLock.lock()
      defer { fileActionsLock.unlock() }
      if !historyClearFailed {
        historyClearFailed = true
        return historyFailure("clearing")
      }
      historyCleared = true
      return (200, #"{"status":"OK"}"#)
    }

    private static func searchFiles(url: URL) -> (Int, String) {
      guard !fileActionsLock.withLock({ harnessFolderDeleted }) else {
        return (200, #"{"total":0,"files":[]}"#)
      }
      let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?
        .queryItems?.first { $0.name == "query" }?.value?.lowercased()
      if query == "no-matching-file" {
        let shouldFail = fileActionsLock.withLock {
          emptySearchLoads += 1
          return emptySearchLoads == 2
        }
        if shouldFail {
          return (
            503,
            fixtureError(
              statusCode: 503, type: "HARNESS_EMPTY_SEARCH_REFRESH",
              message: "The empty search refresh fails once for retry proof")
          )
        }
      }
      if query == "retry" {
        let shouldFail = fileActionsLock.withLock {
          if searchRetryFailed { return false }
          searchRetryFailed = true
          return true
        }
        if shouldFail {
          return (
            503,
            fixtureError(
              statusCode: 503, type: "HARNESS_SEARCH_RETRY",
              message: "The first search fails for retry proof")
          )
        }
      }
      guard query == "harness" || query == "retry" else {
        return (200, #"{"total":0,"files":[]}"#)
      }
      return (
        200,
        """
        {"total":2,"cursor":"search-harness-page-2","files":[
          \(folderObject(id: 410, name: fileActionsLock.withLock { harnessFolderName }, parentID: 0))
        ]}
        """
      )
    }

    private static func continueSearch(request: URLRequest) -> (Int, String) {
      guard requestPayload(request)?["cursor"] as? String == "search-harness-page-2" else {
        return (
          400,
          fixtureError(
            statusCode: 400, type: "HARNESS_SEARCH_CURSOR_INVALID",
            message: "The search fixture requires its continuation cursor")
        )
      }
      guard !fileActionsLock.withLock({ harnessFolderDeleted }) else {
        return (200, #"{"total":0,"files":[]}"#)
      }
      let shouldFail = fileActionsLock.withLock {
        if searchContinuationFailed { return false }
        searchContinuationFailed = true
        return true
      }
      if shouldFail {
        return (
          503,
          fixtureError(
            statusCode: 503, type: "HARNESS_SEARCH_CONTINUATION_RETRY",
            message: "The first search continuation fails for retry proof")
        )
      }
      return (
        200,
        """
        {"total":2,"files":[{
          "id":411,"name":"Nested Movie.mkv","file_type":"VIDEO","parent_id":410,
          "size":1073741824,"created_at":"2026-08-28T11:00:00Z",
          "updated_at":"2026-08-29T11:00:00Z","start_from":\(playbackPosition(fileID: 411))
        }]}
        """
      )
    }

    private static func setSortBy(request: URLRequest) -> (Int, String) {
      guard
        let payload = requestPayload(request),
        let fileID = payload["file_id"] as? Int,
        let sortBy = payload["sort_by"] as? String,
        !sortBy.isEmpty
      else {
        return (
          400,
          fixtureError(
            statusCode: 400,
            type: "HARNESS_SORT_INPUT_REQUIRED",
            message: "The sort fixture requires file_id and sort_by"
          )
        )
      }
      fileActionsLock.withLock { folderSorts[fileID] = sortBy }
      return (200, #"{"status":"OK"}"#)
    }

    private static func fixture(for request: URLRequest) -> (Int, String) {
      guard let url = request.url else {
        return (
          400,
          fixtureError(statusCode: 400, type: "HARNESS_INVALID_REQUEST", message: "Missing URL")
        )
      }
      let routeKey = "\(request.httpMethod ?? "GET") \(url.path)"
      if request.httpMethod == "GET", let fileID = dynamicFileID(from: url.path),
        let response = actionFolderResponse(fileID: fileID)
      {
        return response
      }
      switch routeKey {
      case "GET /v2/oauth2/validate":
        return (
          200,
          #"{"result": true, "token_id": 1, "token_scope": "default", "user_id": 1001}"#
        )
      case "GET /v2/account/info":
        return fileActionsLock.withLock {
          prepareFilePreferencesLocked()
          if usesFilePreferences, preferencesSortCommitted || preferencesRouteCommitted,
            !preferencesRefreshFailed
          {
            preferencesRefreshFailed = true
            return (
              503,
              fixtureError(
                statusCode: 503, type: "HARNESS_SETTINGS_REFRESH",
                message: "The save committed; retry the account refresh")
            )
          }
          if accountRefreshFailuresRemaining > 0 {
            accountRefreshFailuresRemaining -= 1
            return (
              503,
              fixtureError(
                statusCode: 503, type: "HARNESS_TRANSIENT_ACCOUNT_REFRESH_FAILURE",
                message: "The account refresh after emptying fails once for retry proof")
            )
          }
          return (200, accountInfoLocked)
        }
      case "GET /v2/tunnel/routes":
        return fileActionsLock.withLock {
          if !preferencesRoutesFailed {
            preferencesRoutesFailed = true
            return (
              503,
              fixtureError(
                statusCode: 503, type: "HARNESS_ROUTES_RETRY", message: "Retry loading proxies")
            )
          }
          return (
            200,
            #"{"routes":[{"name":"default","description":"Default proxy"},{"name":"edge","description":"Alternate proxy"}]}"#
          )
        }
      case "POST /v2/account/settings":
        return updateFilePreferences(request: request)
      case "POST /v2/files/remove-sort-by-settings":
        return resetFileSorts()
      case "POST /v2/oauth/grants/logout":
        return logoutLock.withLock {
          if logoutFailuresRemaining > 0 {
            logoutFailuresRemaining -= 1
            return (
              503,
              fixtureError(
                statusCode: 503, type: "HARNESS_LOGOUT_FAILURE",
                message: "Retry the fixture sign-out")
            )
          }
          return (200, #"{"status":"OK"}"#)
        }
      case "GET /v2/events/list":
        return listHistory(url: url)
      case "POST /v2/events/delete":
        return clearHistory()
      case "POST /v2/events/delete/808":
        return deleteHistory(id: 808)
      case "GET /v2/files/410":
        fileActionsLock.lock()
        let failLookup =
          ProcessInfo.processInfo.arguments.contains("--putio-harness-deep-links")
          && !deepLinkLookupFailed
        if failLookup { deepLinkLookupFailed = true }
        fileActionsLock.unlock()
        if failLookup {
          return (
            503,
            fixtureError(statusCode: 503, type: "HARNESS_LINK_RETRY", message: "Retry file lookup")
          )
        }
        return (200, folderEnvelope(id: 410, name: "Harness Folder", parentID: 0))
      case "GET /v2/files/413":
        return (
          200,
          """
          {"status":"OK","file":{"id":413,"parent_id":0,"name":"Document.pdf",
          "file_type":"PDF","size":1024,"created_at":"2026-09-01T12:00:00Z",
          "updated_at":"2026-09-01T12:00:00Z"}}
          """
        )
      case "GET /v2/files/999":
        return (
          404,
          fixtureError(
            statusCode: 404, type: "FILE_NOT_FOUND", message: "This file no longer exists")
        )
      case "GET /v2/files/list":
        return filesListFixture(url: url)
      case "POST /v2/files/list/continue":
        return continueFiles(request: request)
      case "GET /v2/files/search":
        return searchFiles(url: url)
      case "POST /v2/files/search/continue":
        return continueSearch(request: request)
      case "POST /v2/files/set-sort-by":
        return setSortBy(request: request)
      case "POST /v2/files/create-folder":
        return createFolder(request: request)
      case "POST /v2/files/rename":
        return renameFile(request: request)
      case "POST /v2/files/delete":
        return deleteFiles(request: request)
      case "POST /v2/files/move":
        return moveFiles(request: request)
      case "GET /v2/trash/list":
        return listTrash()
      case "POST /v2/trash/list/continue":
        return continueTrash(request: request)
      case "POST /v2/trash/restore":
        return restoreTrash(request: request)
      case "POST /v2/trash/delete":
        return permanentlyDeleteTrash(request: request)
      case "POST /v2/trash/empty":
        return emptyTrash()
      case "GET /v2/files/411":
        return (
          200,
          playbackFile(
            id: 411,
            name: "Nested Movie.mkv",
            startFrom: playbackPosition(fileID: 411)
          )
        )
      case "POST /v2/files/411/mp4":
        return startVideoConversion()
      case "GET /v2/files/411/mp4":
        return videoConversionStatus()
      case "GET /v2/files/412":
        return (
          200,
          playbackFile(
            id: 412,
            name: "Root Movie.mkv",
            startFrom: playbackPosition(fileID: 412)
          )
        )
      case "GET /v2/files/412/next-file":
        return (
          200,
          #"{"next_file":{"id":414,"name":"Root Movie 2.mkv","parent_id":0}}"#
        )
      case "GET /v2/files/414":
        return (
          200,
          playbackFile(
            id: 414,
            name: "Root Movie 2.mkv",
            startFrom: playbackPosition(fileID: 414)
          )
        )
      case "GET /v2/files/414/next-file":
        return (200, #"{"next_file":null}"#)
      case "POST /v2/files/411/start-from/set":
        return setPlaybackPosition(request: request, fileID: 411)
      case "POST /v2/files/412/start-from/set":
        return setPlaybackPosition(request: request, fileID: 412)
      case "POST /v2/files/414/start-from/set":
        return setPlaybackPosition(request: request, fileID: 414)
      default:
        return (
          404,
          fixtureError(
            statusCode: 404,
            type: "HARNESS_FIXTURE_NOT_FOUND",
            message: "No harness fixture for \(routeKey)"
          )
        )
      }
    }

    static let rootContinuationCursor = "files-root-page-2"
    static let rootContinuationFileID = 422

    private static func filesListFixture(url: URL) -> (Int, String) {
      let parentID = URLComponents(url: url, resolvingAgainstBaseURL: false)?
        .queryItems?
        .first(where: { $0.name == "parent_id" })?
        .value
        .flatMap(Int.init)
      if let parentID {
        let deleted = fileActionsLock.withLock {
          harnessFolderDeleted && (parentID == 410 || actionFolders[parentID]?.parentID == 410)
        }
        if deleted {
          return (
            404,
            fixtureError(
              statusCode: 404, type: "FOLDER_NOT_FOUND",
              message: "The folder or its ancestor was deleted")
          )
        }
        let child = fileActionsLock.withLock { actionFolders[parentID] }
        if let child, child.name == "Deleted Ancestor Child" {
          return (
            200,
            "{\"parent\":\(folderObject(id: parentID, name: child.name, parentID: child.parentID)),\"files\":[],\"total\":0}"
          )
        }
      }
      switch parentID {
      case 0:
        return (200, rootFiles)
      case 410:
        return (200, nestedFiles)
      case .none:
        return (
          400,
          fixtureError(
            statusCode: 400,
            type: "HARNESS_PARENT_ID_REQUIRED",
            message: "The files fixture requires parent_id"
          )
        )
      case .some(let parentID):
        return (
          404,
          fixtureError(
            statusCode: 404,
            type: "HARNESS_FOLDER_NOT_FOUND",
            message: "No harness folder fixture for parent_id=\(parentID)"
          )
        )
      }
    }

    private static func fixtureError(statusCode: Int, type: String, message: String) -> String {
      return """
        {
          "status": "ERROR",
          "status_code": \(statusCode),
          "error_type": "\(type)",
          "message": "\(message)"
        }
        """
    }

    private static func playbackPosition(fileID: Int) -> Int {
      playbackPositionLock.lock()
      defer { playbackPositionLock.unlock() }
      return playbackPositions[fileID] ?? 0
    }

    private static func setPlaybackPosition(request: URLRequest, fileID: Int) -> (Int, String) {
      guard
        let body = requestBodyData(request),
        let payload = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
        let seconds = payload["time"] as? Int,
        seconds >= 0
      else {
        return (
          400,
          fixtureError(
            statusCode: 400,
            type: "HARNESS_POSITION_REQUIRED",
            message: "The playback-position fixture requires a nonnegative integer time"
          )
        )
      }

      playbackPositionLock.lock()
      playbackPositions[fileID] = seconds
      playbackPositionLock.unlock()
      return (200, #"{"status":"OK"}"#)
    }

    private static func createFolder(request: URLRequest) -> (Int, String) {
      guard
        let payload = requestPayload(request),
        let name = payload["name"] as? String,
        !name.isEmpty,
        let parentID = payload["parent_id"] as? Int,
        parentID == 0 || parentID == 410
      else {
        return (
          400,
          fixtureError(
            statusCode: 400,
            type: "HARNESS_FOLDER_INPUT_REQUIRED",
            message: "The create-folder fixture requires a seeded parent and name"
          )
        )
      }

      fileActionsLock.lock()
      let id = nextActionFolderID
      nextActionFolderID += 1
      actionFolders[id] = ActionFolder(name: name, parentID: parentID)
      fileActionsLock.unlock()
      return (200, folderEnvelope(id: id, name: name, parentID: parentID))
    }

    private static func renameFile(request: URLRequest) -> (Int, String) {
      guard
        let payload = requestPayload(request),
        let fileID = payload["file_id"] as? Int,
        let name = payload["name"] as? String,
        !name.isEmpty
      else {
        return (
          400,
          fixtureError(
            statusCode: 400,
            type: "HARNESS_RENAME_INPUT_REQUIRED",
            message: "The rename fixture requires a file id and name"
          )
        )
      }

      fileActionsLock.lock()
      if fileID == 410, !harnessFolderDeleted {
        harnessFolderName = name
        fileActionsLock.unlock()
        return (200, #"{"status":"OK"}"#)
      }
      guard actionFolders[fileID] != nil else {
        fileActionsLock.unlock()
        return (
          404,
          fixtureError(
            statusCode: 404,
            type: "HARNESS_FILE_NOT_FOUND",
            message: "The rename fixture only changes harness-created folders"
          )
        )
      }
      renameAttempts += 1
      let attempt = renameAttempts
      if attempt > 1 {
        actionFolders[fileID]?.name = name
      }
      fileActionsLock.unlock()
      guard attempt > 1 else {
        return (
          503,
          fixtureError(
            statusCode: 503,
            type: "HARNESS_TRANSIENT_RENAME_FAILURE",
            message: "The first rename request fails for rollback proof"
          )
        )
      }
      return (200, #"{"status":"OK"}"#)
    }

    private static func moveFiles(request: URLRequest) -> (Int, String) {
      guard
        let payload = requestPayload(request),
        let rawFileIDs = payload["file_ids"] as? String,
        let fileID = Int(rawFileIDs),
        let parentID = payload["parent_id"] as? Int,
        parentID == 0 || parentID == 410
      else {
        return (
          400,
          fixtureError(
            statusCode: 400,
            type: "HARNESS_MOVE_INPUT_REQUIRED",
            message: "The move fixture requires one file id and a seeded destination"
          )
        )
      }

      fileActionsLock.lock()
      guard actionFolders[fileID] != nil else {
        fileActionsLock.unlock()
        return (
          404,
          fixtureError(
            statusCode: 404,
            type: "HARNESS_FILE_NOT_FOUND",
            message: "The move fixture only changes harness-created folders"
          )
        )
      }
      actionFolders[fileID]?.parentID = parentID
      if fileID == ambiguousMoveFailureFolderID, !ambiguousMoveFailureDelivered {
        ambiguousMoveFailureDelivered = true
        fileActionsLock.unlock()
        return (
          503,
          fixtureError(
            statusCode: 503,
            type: "HARNESS_AMBIGUOUS_MOVE_FAILURE",
            message: "The move is applied before its first response fails"
          )
        )
      }
      fileActionsLock.unlock()
      return (200, #"{"status":"OK","errors":[]}"#)
    }

    private static func deleteFiles(request: URLRequest) -> (Int, String) {
      guard
        let payload = requestPayload(request),
        let rawFileIDs = payload["file_ids"] as? String,
        let fileID = Int(rawFileIDs)
      else {
        return (
          400,
          fixtureError(
            statusCode: 400,
            type: "HARNESS_DELETE_INPUT_REQUIRED",
            message: "The delete fixture requires one file id"
          )
        )
      }

      fileActionsLock.lock()
      if fileID == 410 {
        harnessFolderDeleted = true
        if trashEnabled { trashFolders[410] = ActionFolder(name: harnessFolderName, parentID: 0) }
        fileActionsLock.unlock()
        return (200, #"{"status":"OK"}"#)
      }
      guard actionFolders[fileID] != nil else {
        fileActionsLock.unlock()
        return (
          404,
          fixtureError(
            statusCode: 404,
            type: "HARNESS_FILE_NOT_FOUND",
            message: "The delete fixture only changes harness-created folders"
          )
        )
      }
      if fileID == bulkDeleteFailureFolderID, !bulkDeleteFailureDelivered {
        bulkDeleteFailureDelivered = true
        fileActionsLock.unlock()
        return (
          503,
          fixtureError(
            statusCode: 503,
            type: "HARNESS_TRANSIENT_DELETE_FAILURE",
            message: "The first delete of the second created folder fails for retry proof"
          )
        )
      }
      if trashEnabled, let folder = actionFolders.removeValue(forKey: fileID) {
        trashFolders[fileID] = folder
      } else {
        actionFolders.removeValue(forKey: fileID)
      }
      fileActionsLock.unlock()
      return (200, #"{"status":"OK"}"#)
    }

    private static func listTrash() -> (Int, String) {
      fileActionsLock.lock()
      trashListRequests += 1
      let failEmptyRefresh = trashFolders.isEmpty && !trashEmptyRefreshFailed
      if !usesFilePreferences && (trashListRequests == 2 || failEmptyRefresh) {
        if failEmptyRefresh { trashEmptyRefreshFailed = true }
        fileActionsLock.unlock()
        return (
          503,
          fixtureError(
            statusCode: 503,
            type: "HARNESS_TRANSIENT_TRASH_REFRESH_FAILURE",
            message: "The first populated and empty Trash refreshes fail for retry proof"
          )
        )
      }
      let folders = trashFolders.sorted { $0.key < $1.key }
      let rows = folders.prefix(2).map { id, folder in
        trashFolderObject(id: id, folder: folder)
      }
      let cursor = folders.count > 2 ? "trash-after-\(folders[1].key)" : ""
      fileActionsLock.unlock()
      return (
        200,
        """
        {
          "cursor": "\(cursor)",
          "total": \(folders.count),
          "trash_size": \(Int64(folders.count) * trashFolderBytes),
          "files": [\(rows.joined(separator: ","))]
        }
        """
      )
    }

    private static func continueTrash(request: URLRequest) -> (Int, String) {
      guard
        let payload = requestPayload(request),
        let cursor = payload["cursor"] as? String,
        cursor.hasPrefix("trash-after-"),
        let boundary = Int(cursor.dropFirst("trash-after-".count)),
        boundary > 0
      else {
        return (
          400,
          fixtureError(
            statusCode: 400,
            type: "HARNESS_TRASH_CURSOR_INVALID",
            message: "The Trash fixture requires its current continuation cursor"
          )
        )
      }
      fileActionsLock.lock()
      let folders = trashFolders.sorted { $0.key < $1.key }
      let rows = folders.filter { $0.key > boundary }.map { id, folder in
        trashFolderObject(id: id, folder: folder)
      }
      fileActionsLock.unlock()
      return (
        200,
        """
        {
          "cursor": "",
          "total": \(folders.count),
          "trash_size": \(Int64(folders.count) * trashFolderBytes),
          "files": [\(rows.joined(separator: ","))]
        }
        """
      )
    }

    private static var initialTrashFolders: [Int: ActionFolder] {
      [
        trashRestoreFolderID: ActionFolder(name: "Restore Me", parentID: 0),
        trashDeleteFolderID: ActionFolder(name: "Delete Me", parentID: 410),
        trashEmptyFolderID: ActionFolder(name: "Empty Me", parentID: 0),
      ]
    }

    private static func restoreTrash(request: URLRequest) -> (Int, String) {
      guard let fileID = trashFileID(from: request) else {
        return trashMutationInputError()
      }
      fileActionsLock.lock()
      guard let folder = trashFolders.removeValue(forKey: fileID) else {
        fileActionsLock.unlock()
        return trashNotFoundError()
      }
      actionFolders[fileID] = folder
      fileActionsLock.unlock()
      return (200, #"{"status":"OK"}"#)
    }

    private static func permanentlyDeleteTrash(request: URLRequest) -> (Int, String) {
      guard let fileID = trashFileID(from: request) else {
        return trashMutationInputError()
      }
      fileActionsLock.lock()
      guard trashFolders[fileID] != nil else {
        fileActionsLock.unlock()
        return trashNotFoundError()
      }
      if fileID == trashDeleteFolderID, !trashDeleteFailureDelivered {
        trashDeleteFailureDelivered = true
        fileActionsLock.unlock()
        return (
          503,
          fixtureError(
            statusCode: 503,
            type: "HARNESS_TRANSIENT_TRASH_DELETE_FAILURE",
            message: "The first permanent delete fails for retry proof"
          )
        )
      }
      trashFolders.removeValue(forKey: fileID)
      trashFreedBytes += trashFolderBytes
      fileActionsLock.unlock()
      return (200, #"{"status":"OK"}"#)
    }

    private static func emptyTrash() -> (Int, String) {
      fileActionsLock.lock()
      trashFreedBytes += Int64(trashFolders.count) * trashFolderBytes
      trashFolders = [:]
      accountRefreshFailuresRemaining = 1
      fileActionsLock.unlock()
      return (200, #"{"status":"OK"}"#)
    }

    private static func trashFileID(from request: URLRequest) -> Int? {
      guard
        let payload = requestPayload(request),
        let rawFileIDs = payload["file_ids"] as? String,
        !rawFileIDs.contains(",")
      else { return nil }
      return Int(rawFileIDs)
    }

    private static func trashMutationInputError() -> (Int, String) {
      (
        400,
        fixtureError(
          statusCode: 400,
          type: "HARNESS_TRASH_INPUT_REQUIRED",
          message: "The Trash fixture requires one file id"
        )
      )
    }

    private static func trashNotFoundError() -> (Int, String) {
      (
        404,
        fixtureError(
          statusCode: 404,
          type: "HARNESS_TRASH_FILE_NOT_FOUND",
          message: "The Trash fixture only changes seeded Trash folders"
        )
      )
    }

    private static func dynamicFileID(from path: String) -> Int? {
      let prefix = "/v2/files/"
      guard path.hasPrefix(prefix) else { return nil }
      let suffix = path.dropFirst(prefix.count)
      guard !suffix.contains("/") else { return nil }
      return Int(suffix)
    }

    private static func actionFolderResponse(fileID: Int) -> (Int, String)? {
      fileActionsLock.lock()
      let folder = actionFolders[fileID]
      fileActionsLock.unlock()
      guard let folder else { return nil }
      return (200, folderEnvelope(id: fileID, name: folder.name, parentID: folder.parentID))
    }

    private static func trashFolderObject(id: Int, folder: ActionFolder) -> String {
      """
      {
        "id": \(id),
        "name": \(jsonString(folder.name)),
        "file_type": "FOLDER",
        "parent_id": \(folder.parentID),
        "size": \(trashFolderBytes),
        "created_at": "2026-08-28T10:00:00Z",
        "deleted_at": "2026-09-02T10:00:00Z",
        "expiration_date": "2026-10-02T10:00:00Z"
      }
      """
    }

    private static func startVideoConversion() -> (Int, String) {
      conversionLock.lock()
      defer { conversionLock.unlock() }
      conversionStartAttempts += 1
      guard conversionStartAttempts > 1 else {
        return (
          503,
          fixtureError(
            statusCode: 503,
            type: "HARNESS_TRANSIENT_CONVERSION_FAILURE",
            message: "The first conversion request fails for retry proof"
          )
        )
      }
      conversionStarted = true
      conversionStatusLoads = 0
      return (200, #"{"status":"OK"}"#)
    }

    private static func videoConversionStatus() -> (Int, String) {
      conversionLock.lock()
      defer { conversionLock.unlock() }
      guard conversionStarted else {
        return (
          409,
          fixtureError(
            statusCode: 409,
            type: "HARNESS_CONVERSION_NOT_STARTED",
            message: "Conversion status was requested before conversion started"
          )
        )
      }

      let response: (status: String, percentDone: Int)
      switch conversionStatusLoads {
      case 0:
        response = ("IN_QUEUE", 0)
      case 1:
        response = ("CONVERTING", 35)
      default:
        response = ("COMPLETED", 100)
        conversionCompleted = true
      }
      conversionStatusLoads += 1
      return (
        200,
        #"{"mp4":{"percent_done":\#(response.percentDone),"status":"\#(response.status)"}}"#
      )
    }

    private static func requestBodyData(_ request: URLRequest) -> Data? {
      if let body = request.httpBody {
        return body
      }
      guard let stream = request.httpBodyStream else { return nil }

      stream.open()
      defer { stream.close() }
      let bufferSize = 1_024
      let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
      defer { buffer.deallocate() }

      var body = Data()
      while stream.hasBytesAvailable {
        let count = stream.read(buffer, maxLength: bufferSize)
        guard count >= 0 else { return nil }
        guard count > 0 else { break }
        body.append(buffer, count: count)
      }
      return body
    }

    private static func replayableRequest(_ request: URLRequest) -> URLRequest {
      guard request.httpBody == nil, request.httpBodyStream != nil,
        let body = requestBodyData(request)
      else { return request }
      var replayableRequest = request
      replayableRequest.httpBodyStream = nil
      replayableRequest.httpBody = body
      return replayableRequest
    }

    private static func requestPayload(_ request: URLRequest) -> [String: Any]? {
      guard let body = requestBodyData(request) else { return nil }
      return try? JSONSerialization.jsonObject(with: body) as? [String: Any]
    }

    // Caller holds fileActionsLock.
    private static var accountInfoLocked: String {
      prepareFilePreferencesLocked()
      let historyEnabled =
        usesFilePreferences
        ? filePreferences?.historyEnabled ?? true
        : !ProcessInfo.processInfo.arguments.contains("--putio-harness-history-disabled")
      let defaultSort = usesFilePreferences ? filePreferences?.sortBy ?? "NAME_ASC" : "NAME_ASC"
      let usedBytes = diskUsedBytes - trashFreedBytes
      let trashSizeBytes = Int64(trashFolders.count) * trashFolderBytes
      return """
        {
          "info": {
            "user_id": 1001,
            "username": "moviebuff",
            "mail": "harness@example.com",
            "avatar_url": "https://static.put.io/e2e-avatar.png",
            "user_hash": "harness-hash",
            "features": {},
            "download_token": "harness-download-token",
            "trash_size": \(trashSizeBytes),
            "account_active": true,
            "files_will_be_deleted_at": "",
            "password_last_changed_at": "",
            "disk": {
              "avail": \(diskTotalBytes - usedBytes),
              "size": \(diskTotalBytes),
              "used": \(usedBytes)
            },
            "settings": {
              "tunnel_route_name": \(jsonString(filePreferences?.routeName ?? "default")),
              "next_episode": true,
              "start_from": true,
              "history_enabled": \(historyEnabled),
              "trash_enabled": \(trashEnabled),
              "sort_by": \(jsonString(defaultSort)),
              "show_optimistic_usage": false,
              "two_factor_enabled": false,
              "hide_subtitles": \(filePreferences?.hideSubtitles ?? false),
              "dont_autoselect_subtitles": \(filePreferences?.dontAutoSelectSubtitles ?? false)
            }
          }
        }
        """
    }

    private static var rootFiles: String {
      fileActionsLock.lock()
      let mutableFolders =
        actionFolders
        .filter { $0.value.parentID == 0 }
        .sorted { $0.key < $1.key }
      prepareFilePreferencesLocked()
      let inheritsDefault =
        usesFilePreferences && filePreferences?.overridesReset == true
        && folderSorts[0] == nil
      let sortBy =
        folderSorts[0]
        ?? (inheritsDefault ? filePreferences?.sortBy ?? "NAME_ASC" : "NAME_ASC")
      let parentSort = inheritsDefault ? "null" : jsonString(sortBy)
      let folderName = harnessFolderName
      let folderDeleted = harnessFolderDeleted
      fileActionsLock.unlock()
      let mutableFolderRows = mutableFolders.map { id, folder in
        folderObject(id: id, name: folder.name, parentID: folder.parentID)
      }
      var rows =
        [
          """
          {
            "id": 410,
            "name": \(jsonString(folderName)),
            "file_type": "FOLDER",
            "parent_id": 0,
            "size": 0,
            "created_at": "2026-08-28T10:00:00Z",
            "updated_at": "2026-08-29T10:00:00Z"
          }
          """,
          """
          {
            "id": 412,
            "name": "Root Movie.mkv",
            "file_type": "VIDEO",
            "parent_id": 0,
            "size": 734003200,
            "created_at": "2026-08-28T10:00:00Z",
            "updated_at": "2026-08-29T10:00:00Z",
            "start_from": \(playbackPosition(fileID: 412))
          }
          """,
          """
          {
            "id": 413,
            "name": "Document.pdf",
            "file_type": "PDF",
            "parent_id": 0,
            "size": 1048576,
            "created_at": "2026-08-28T10:00:00Z",
            "updated_at": "2026-08-29T10:00:00Z"
          }
          """,
        ] + mutableFolderRows
      if folderDeleted { rows.removeFirst() }
      // Only the two name orders are modelled; the journey proves the
      // round trip, not the server's comparator.
      if sortBy == "NAME_DESC" { rows.reverse() }
      return """
        {
          "cursor": \(jsonString(rootContinuationCursor)),
          "parent": {
            "id": 0,
            "name": "Your Files",
            "file_type": "FOLDER",
            "parent_id": 0,
            "size": 0,
            "sort_by": \(parentSort),
            "created_at": "2026-08-01T10:00:00Z",
            "updated_at": "2026-08-01T10:00:00Z"
          },
          "files": [
            \(rows.joined(separator: ",\n"))
          ],
          "total": \(4 + mutableFolders.count - (folderDeleted ? 1 : 0))
        }
        """
    }

    private static func folderEnvelope(id: Int, name: String, parentID: Int) -> String {
      """
      {
        "file": \(folderObject(id: id, name: name, parentID: parentID))
      }
      """
    }

    private static func folderObject(id: Int, name: String, parentID: Int) -> String {
      """
      {
        "id": \(id),
        "name": \(jsonString(name)),
        "file_type": "FOLDER",
        "parent_id": \(parentID),
        "size": 0,
        "created_at": "2026-09-01T20:00:00Z",
        "updated_at": "2026-09-01T20:00:00Z"
      }
      """
    }

    private static func jsonString(_ value: String) -> String {
      guard
        let data = try? JSONSerialization.data(withJSONObject: value, options: .fragmentsAllowed),
        let encoded = String(data: data, encoding: .utf8)
      else { return "\"\"" }
      return encoded
    }

    private static var nestedFiles: String {
      fileActionsLock.lock()
      let folderName = harnessFolderName
      let mutableFolders =
        actionFolders
        .filter { $0.value.parentID == 410 }
        .sorted { $0.key < $1.key }
      fileActionsLock.unlock()
      let mutableFolderRows = mutableFolders.map { id, folder in
        folderObject(id: id, name: folder.name, parentID: folder.parentID)
      }
      let extraRows =
        mutableFolderRows.isEmpty ? "" : ",\n" + mutableFolderRows.joined(separator: ",\n")
      return """
        {
          "parent": {
            "id": 410,
            "name": \(jsonString(folderName)),
            "file_type": "FOLDER",
            "parent_id": 0,
            "size": 0,
            "created_at": "2026-08-28T10:00:00Z",
            "updated_at": "2026-08-29T10:00:00Z"
          },
          "files": [
            {
              "id": 411,
              "name": "Nested Movie.mkv",
              "file_type": "VIDEO",
              "parent_id": 410,
              "size": 1073741824,
              "created_at": "2026-08-28T11:00:00Z",
              "updated_at": "2026-08-29T11:00:00Z",
              "start_from": \(playbackPosition(fileID: 411))
            }\(extraRows)
          ],
          "total": \(1 + mutableFolders.count)
        }
        """
    }

    private static func playbackFile(id: Int, name: String, startFrom: Int) -> String {
      let needsConversion: Bool
      if id == 411 {
        conversionLock.lock()
        needsConversion = !conversionCompleted
        conversionLock.unlock()
      } else {
        needsConversion = false
      }
      return """
        {
          "file": {
            "id": \(id),
            "name": "\(name)",
            "file_type": "VIDEO",
            "parent_id": \(id == 411 ? 410 : 0),
            "created_at": "2026-09-01T12:00:00",
            "updated_at": "2026-09-01T12:00:00",
            "need_convert": \(needsConversion),
            "start_from": \(startFrom)
          }
        }
        """
    }
  }
#endif
