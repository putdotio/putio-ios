import Foundation
import Synchronization
import XCTest

@testable import PutioCore

// URLProtocol supports asynchronous client callbacks. Gated tests retain each
// loader behind a Mutex and release it exactly once.
private final class RuntimeMockURLProtocol: URLProtocol, @unchecked Sendable {
  private struct Fixture: Sendable {
    let statusCode: Int
    let body: String
  }

  private final class GatedResponse: Sendable {
    private let fixture: Fixture
    private let loader: RuntimeMockURLProtocol
    private let released = Mutex(false)

    init(loader: RuntimeMockURLProtocol, fixture: Fixture) {
      self.fixture = fixture
      self.loader = loader
    }

    func release() {
      let shouldRespond = released.withLock { released in
        guard !released else { return false }
        released = true
        return true
      }
      guard shouldRespond else { return }
      loader.respond(with: fixture)
    }
  }

  private enum Action: Sendable {
    case fixture(Fixture)
    case gatedFixture(Fixture)
    case networkFailure
    case nonHTTPResponse
    case suspend
  }

  private struct State {
    var fixtures: [String: Fixture] = [:]
    var networkFailureRoutes: Set<String> = []
    var nonHTTPRoutes: Set<String> = []
    var suspendedRoutes: Set<String> = []
    var gatedRoutes: Set<String> = []
    var gatedResponses: [String: GatedResponse] = [:]
    var requests: [URLRequest] = []
  }

  private static let state = Mutex(State())

  static func reset() {
    state.withLock { $0 = State() }
  }

  static func setFixture(_ body: String, statusCode: Int = 200, for route: String) {
    state.withLock { $0.fixtures[route] = Fixture(statusCode: statusCode, body: body) }
  }

  static func setNetworkFailure(_ enabled: Bool, for route: String) {
    state.withLock {
      if enabled {
        $0.networkFailureRoutes.insert(route)
      } else {
        $0.networkFailureRoutes.remove(route)
      }
    }
  }

  static func setNonHTTPResponse(_ enabled: Bool, for route: String) {
    state.withLock {
      if enabled {
        $0.nonHTTPRoutes.insert(route)
      } else {
        $0.nonHTTPRoutes.remove(route)
      }
    }
  }

  static func suspend(_ route: String) {
    state.withLock { _ = $0.suspendedRoutes.insert(route) }
  }

  static func gateFixture(_ body: String, statusCode: Int = 200, for route: String) {
    state.withLock {
      $0.fixtures[route] = Fixture(statusCode: statusCode, body: body)
      $0.gatedRoutes.insert(route)
    }
  }

  static func releaseFixture(for route: String) {
    let response = state.withLock { state in
      state.gatedRoutes.remove(route)
      return state.gatedResponses.removeValue(forKey: route)
    }
    response?.release()
  }

  static func capturedRequests() -> [URLRequest] {
    state.withLock { $0.requests }
  }

  override class func canInit(with request: URLRequest) -> Bool {
    true
  }

  override class func canonicalRequest(for request: URLRequest) -> URLRequest {
    request
  }

  override func startLoading() {
    guard let url = request.url else {
      client?.urlProtocol(self, didFailWithError: URLError(.badURL))
      return
    }

    let route = "\(request.httpMethod ?? "GET") \(url.path)"
    let capturedRequest = request
    let action = Self.state.withLock { state -> Action in
      if state.suspendedRoutes.contains(route) {
        state.requests.append(capturedRequest)
        return .suspend
      }
      if state.networkFailureRoutes.contains(route) {
        state.requests.append(capturedRequest)
        return .networkFailure
      }
      if state.nonHTTPRoutes.contains(route) {
        state.requests.append(capturedRequest)
        return .nonHTTPResponse
      }
      let fixture =
        state.fixtures[route]
        ?? Fixture(
          statusCode: 404,
          body: #"{"status":"ERROR","status_code":404,"error_type":"FIXTURE_NOT_FOUND"}"#
        )
      if state.gatedRoutes.remove(route) != nil {
        return .gatedFixture(fixture)
      }
      state.requests.append(capturedRequest)
      return .fixture(fixture)
    }

    switch action {
    case .fixture(let fixture):
      respond(with: fixture)
    case .gatedFixture(let fixture):
      let response = GatedResponse(loader: self, fixture: fixture)
      Self.state.withLock { state in
        state.gatedResponses[route] = response
        state.requests.append(capturedRequest)
      }
      return
    case .networkFailure:
      client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
    case .nonHTTPResponse:
      let response = URLResponse(
        url: url,
        mimeType: "application/json",
        expectedContentLength: 0,
        textEncodingName: "utf-8"
      )
      client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
      client?.urlProtocolDidFinishLoading(self)
    case .suspend:
      break
    }
  }

  override func stopLoading() {}

  private func respond(with fixture: Fixture) {
    guard let url = request.url else {
      client?.urlProtocol(self, didFailWithError: URLError(.badURL))
      return
    }
    guard
      let response = HTTPURLResponse(
        url: url,
        statusCode: fixture.statusCode,
        httpVersion: nil,
        headerFields: ["Content-Type": "application/json"]
      )
    else {
      client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
      return
    }
    client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
    client?.urlProtocol(self, didLoad: Data(fixture.body.utf8))
    client?.urlProtocolDidFinishLoading(self)
  }
}

@MainActor
final class PutioRuntimeTests: XCTestCase {
  private static let filesRoute = "GET /v2/files/list"
  private static let filesContinueRoute = "POST /v2/files/list/continue"
  private static let searchRoute = "GET /v2/files/search"
  private static let searchContinueRoute = "POST /v2/files/search/continue"
  private static let setSortRoute = "POST /v2/files/set-sort-by"
  private static let createFolderRoute = "POST /v2/files/create-folder"
  private static let renameFileRoute = "POST /v2/files/rename"
  private static let moveFilesRoute = "POST /v2/files/move"
  private static let deleteFilesRoute = "POST /v2/files/delete"
  private static let trashListRoute = "GET /v2/trash/list"
  private static let trashContinueRoute = "POST /v2/trash/list/continue"
  private static let trashRestoreRoute = "POST /v2/trash/restore"
  private static let trashDeleteRoute = "POST /v2/trash/delete"
  private static let trashEmptyRoute = "POST /v2/trash/empty"
  private static let restoredTrashFileRoute = "GET /v2/files/91"
  private static let nextVideoRoute = "GET /v2/files/411/next-file"
  private static let playbackRoute = "GET /v2/files/411"
  private static let playbackPositionRoute = "POST /v2/files/411/start-from/set"
  private static let conversionStartRoute = "POST /v2/files/411/mp4"
  private static let conversionStatusRoute = "GET /v2/files/411/mp4"
  private static let logoutRoute = "POST /v2/oauth/grants/logout"
  private static let validValidation =
    #"{"result": true, "token_id": 1, "token_scope": "default", "user_id": 1001}"#
  private static let accountInfo = """
    {
      "info": {
        "user_id": 1001,
        "username": "moviebuff",
        "mail": "tests@example.com",
        "avatar_url": "https://static.put.io/private-avatar.png",
        "user_hash": "private-hash",
        "features": {},
        "download_token": "account-download-secret",
        "trash_size": 0,
        "account_active": true,
        "files_will_be_deleted_at": "",
        "password_last_changed_at": "",
        "disk": { "avail": 10, "size": 30, "used": 20 },
        "settings": {
          "tunnel_route_name": "default",
          "next_episode": true,
          "start_from": true,
          "history_enabled": true,
          "trash_enabled": true,
          "sort_by": "NAME_ASC",
          "show_optimistic_usage": false,
          "two_factor_enabled": false,
          "hide_subtitles": false,
          "dont_autoselect_subtitles": false
        }
      }
    }
    """

  override func setUp() {
    super.setUp()
    RuntimeMockURLProtocol.reset()
  }

  func testUnauthenticatedRuntimeRejectsListingWithoutARequest() async {
    let (runtime, _) = makeRuntime(token: nil)

    await assertRuntimeError(.authenticationRequired) {
      _ = try await runtime.listFiles()
    }
    await runtime.session.restore()
    await assertRuntimeError(.authenticationRequired) {
      _ = try await runtime.listFiles()
    }

    XCTAssertTrue(RuntimeMockURLProtocol.capturedRequests().isEmpty)
  }

  func testRestoredTokenIsSharedByValidationAccountAndFilesRequests() async throws {
    stubSignedInRoutes()
    RuntimeMockURLProtocol.setFixture(Self.filesList(cursor: nil), for: Self.filesRoute)
    let (runtime, _) = makeRuntime(token: "stored-token")

    await runtime.session.restore()
    _ = try await runtime.listFiles()

    let requests = RuntimeMockURLProtocol.capturedRequests()
    XCTAssertEqual(
      requests.compactMap { $0.url?.path },
      ["/v2/oauth2/validate", "/v2/account/info", "/v2/files/list"]
    )
    XCTAssertEqual(
      requests.compactMap { $0.value(forHTTPHeaderField: "Authorization")?.lowercased() },
      ["token stored-token", "token stored-token", "token stored-token"]
    )

    guard case .signedIn(let account) = runtime.session.state else {
      return XCTFail("expected a restored account")
    }
    let accountDescription = String(reflecting: account)
    XCTAssertFalse(accountDescription.contains("account-download-secret"))
    XCTAssertFalse(accountDescription.contains("private-avatar"))
  }

  func testListMapsAppOwnedValuesAndKeepsCursorAndSort() async throws {
    let (runtime, _) = await makeSignedInRuntime()
    RuntimeMockURLProtocol.setFixture(
      Self.filesList(cursor: "next-page", sortBy: "DATE_DESC"), for: Self.filesRoute)

    let contents = try await runtime.listFiles(parentID: .root)

    XCTAssertEqual(contents.folder?.id, .root)
    XCTAssertEqual(contents.folder?.name, "Your Files")
    XCTAssertEqual(contents.folder?.kind, .folder)
    XCTAssertEqual(contents.nextCursor, "next-page")
    XCTAssertTrue(contents.hasMore)
    XCTAssertEqual(contents.sort, .dateAddedDescending)
    XCTAssertEqual(
      contents.items.map(\.kind),
      [.video, .audio, .image, .pdf, .folder, .other("ARCHIVE")]
    )

    let video = try XCTUnwrap(contents.items.first)
    XCTAssertEqual(video.id, PutioFileID(rawValue: 11))
    XCTAssertEqual(video.parentID, .root)
    XCTAssertEqual(video.name, "Episode 1.mkv")
    XCTAssertEqual(video.sizeBytes, 1_024)
    XCTAssertEqual(video.resumePositionSeconds, 42)
    XCTAssertTrue(video.isWatched)
    XCTAssertEqual(
      video.createdAt,
      try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-08-28T10:00:00Z"))
    )
    XCTAssertEqual(
      video.updatedAt,
      try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-08-29T10:00:00Z"))
    )

    let description = String(reflecting: contents)
    XCTAssertFalse(description.contains("stream-secret"))
    XCTAssertFalse(description.contains("mp4-secret"))
  }

  func testNilAndEmptyCursorsDoNotClaimContinuation() async throws {
    let (runtime, _) = await makeSignedInRuntime()

    RuntimeMockURLProtocol.setFixture(Self.filesList(cursor: nil), for: Self.filesRoute)
    let nilCursorContents = try await runtime.listFiles()
    XCTAssertNil(nilCursorContents.nextCursor)
    XCTAssertFalse(nilCursorContents.hasMore)

    RuntimeMockURLProtocol.setFixture(Self.filesList(cursor: ""), for: Self.filesRoute)
    let emptyCursorContents = try await runtime.listFiles()
    XCTAssertNil(emptyCursorContents.nextCursor)
    XCTAssertFalse(emptyCursorContents.hasMore)
  }

  func testUnknownAndMissingSortKeysMapToNil() async throws {
    let (runtime, _) = await makeSignedInRuntime()

    RuntimeMockURLProtocol.setFixture(
      Self.filesList(cursor: nil, sortBy: "FUTURE_KEY"), for: Self.filesRoute)
    let unknownSort = try await runtime.listFiles().sort
    XCTAssertNil(unknownSort)

    RuntimeMockURLProtocol.setFixture(Self.filesList(cursor: nil), for: Self.filesRoute)
    let missingSort = try await runtime.listFiles().sort
    XCTAssertNil(missingSort)
  }

  func testContinueFilesPostsTheCursorAndAppendsNothingItself() async throws {
    let (runtime, _) = await makeSignedInRuntime()
    RuntimeMockURLProtocol.setFixture(
      #"{"cursor":"","files":[{"id":31,"name":"Page 2.mkv","file_type":"VIDEO","parent_id":0,"size":1,"created_at":"2026-08-28T10:00:00Z","updated_at":"2026-08-29T10:00:00Z"}]}"#,
      for: Self.filesContinueRoute
    )

    let page = try await runtime.continueFiles(cursor: "files-page-2")

    XCTAssertNil(page.folder)
    XCTAssertNil(page.nextCursor)
    XCTAssertEqual(page.items.map(\.id), [PutioFileID(rawValue: 31)])
    let request = try XCTUnwrap(RuntimeMockURLProtocol.capturedRequests().last)
    XCTAssertEqual(request.httpMethod, "POST")
    XCTAssertEqual(request.url?.path, "/v2/files/list/continue")
    let body = try XCTUnwrap(requestBodyData(for: request))
    let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
    XCTAssertEqual(json["cursor"] as? String, "files-page-2")
  }

  func testSearchEncodesQueryAndMapsAppOwnedResults() async throws {
    let (runtime, _) = await makeSignedInRuntime()
    RuntimeMockURLProtocol.setFixture(
      #"{"total":2,"cursor":"search-page-2","files":[{"id":31,"name":"Summer & snow.mkv","file_type":"VIDEO","parent_id":42,"size":1024,"start_from":12,"created_at":"2026-08-28T10:00:00Z","updated_at":"2026-08-29T10:00:00Z","stream_url":"https://example.com/stream-secret"}]}"#,
      for: Self.searchRoute
    )

    let query = "Summer & snow + 東京?"
    let page = try await runtime.searchFiles(query: query)

    XCTAssertEqual(page.totalCount, 2)
    XCTAssertEqual(page.nextCursor, "search-page-2")
    let item = try XCTUnwrap(page.items.first)
    XCTAssertEqual(item.id, PutioFileID(rawValue: 31))
    XCTAssertEqual(item.parentID, PutioFileID(rawValue: 42))
    XCTAssertEqual(item.name, "Summer & snow.mkv")
    XCTAssertEqual(item.kind, .video)
    XCTAssertEqual(item.sizeBytes, 1024)
    XCTAssertEqual(item.resumePositionSeconds, 12)
    XCTAssertFalse(String(reflecting: page).contains("stream-secret"))
    let request = try XCTUnwrap(RuntimeMockURLProtocol.capturedRequests().last)
    XCTAssertEqual(request.httpMethod, "GET")
    XCTAssertEqual(request.url?.path, "/v2/files/search")
    let components = try XCTUnwrap(
      request.url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false) }
    )
    XCTAssertEqual(components.queryItems?.first { $0.name == "query" }?.value, query)
    XCTAssertEqual(components.queryItems?.first { $0.name == "per_page" }?.value, "50")
    XCTAssertEqual(
      request.value(forHTTPHeaderField: "Authorization")?.lowercased(), "token stored-token")
  }

  func testSearchContinuationPostsOpaqueCursorAndMapsFinalPage() async throws {
    let (runtime, _) = await makeSignedInRuntime()
    RuntimeMockURLProtocol.setFixture(
      #"{"total":2,"cursor":"","files":[{"id":32,"name":"Page 2.mkv","file_type":"VIDEO","parent_id":42,"size":1,"created_at":"2026-08-28T10:00:00Z","updated_at":"2026-08-29T10:00:00Z"}]}"#,
      for: Self.searchContinueRoute
    )

    let cursor = "opaque+/= search cursor"
    let page = try await runtime.continueFileSearch(cursor: cursor)

    XCTAssertEqual(page.totalCount, 2)
    XCTAssertNil(page.nextCursor)
    XCTAssertEqual(page.items.map(\.id), [PutioFileID(rawValue: 32)])
    let request = try XCTUnwrap(RuntimeMockURLProtocol.capturedRequests().last)
    XCTAssertEqual(request.httpMethod, "POST")
    XCTAssertEqual(request.url?.path, "/v2/files/search/continue")
    let body = try XCTUnwrap(requestBodyData(for: request))
    let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
    XCTAssertEqual(json["cursor"] as? String, cursor)
    XCTAssertEqual(
      request.value(forHTTPHeaderField: "Authorization")?.lowercased(), "token stored-token")
  }

  func testSearchRejectsNegativeTotalsAndNonadvancingContinuation() async throws {
    let (runtime, _) = await makeSignedInRuntime()
    RuntimeMockURLProtocol.setFixture(#"{"total":-1,"files":[]}"#, for: Self.searchRoute)
    await assertRuntimeError(.invalidResponse) {
      _ = try await runtime.searchFiles(query: "video")
    }
    RuntimeMockURLProtocol.setFixture(
      #"{"total":3,"cursor":"same-page","files":[]}"#, for: Self.searchContinueRoute)
    await assertRuntimeError(.invalidResponse) {
      _ = try await runtime.continueFileSearch(cursor: "same-page")
    }
    RuntimeMockURLProtocol.setFixture(#"{"total":0,"files":[]}"#, for: Self.searchRoute)
    let emptyPage = try await runtime.searchFiles(query: "missing")
    XCTAssertEqual(emptyPage, PutioFileSearchPage(items: [], nextCursor: nil, totalCount: 0))
  }

  func testUnauthenticatedRuntimeRejectsSearchAndContinuationWithoutRequests() async {
    let (runtime, _) = makeRuntime(token: nil)
    await assertRuntimeError(.authenticationRequired) {
      _ = try await runtime.searchFiles(query: "video")
    }
    await assertRuntimeError(.authenticationRequired) {
      _ = try await runtime.continueFileSearch(cursor: "next-page")
    }
    XCTAssertTrue(RuntimeMockURLProtocol.capturedRequests().isEmpty)
  }

  func testSearchAuthenticationFailuresExpireSessionAndBlockFurtherRequests() async {
    for route in [Self.searchRoute, Self.searchContinueRoute] {
      RuntimeMockURLProtocol.reset()
      let (runtime, tokenStore) = await makeSignedInRuntime()
      RuntimeMockURLProtocol.setFixture(
        #"{"status":"ERROR","error_type":"invalid_grant"}"#, statusCode: 401, for: route)
      await assertRuntimeError(.sessionExpired) {
        if route == Self.searchRoute {
          _ = try await runtime.searchFiles(query: "video")
        } else {
          _ = try await runtime.continueFileSearch(cursor: "next-page")
        }
      }
      XCTAssertEqual(runtime.session.state, .signedOut(.sessionExpired))
      XCTAssertNil(try? tokenStore.read())
      let requestCount = RuntimeMockURLProtocol.capturedRequests().count
      await assertRuntimeError(.sessionExpired) {
        _ = try await runtime.searchFiles(query: "video")
      }
      XCTAssertEqual(RuntimeMockURLProtocol.capturedRequests().count, requestCount)
    }
  }

  func testPlaybackRoutesRejectAmbiguousIdentityAndPreserveDescriptions() async throws {
    let (runtime, _) = await makeSignedInRuntime()
    let route = "GET /v2/tunnel/routes"
    RuntimeMockURLProtocol.setFixture(
      #"{"routes":[{"name":"default","description":"Default proxy"},{"name":"edge","description":"Nearby proxy"}]}"#,
      for: route)
    let routes = try await runtime.listPlaybackRoutes()
    XCTAssertEqual(
      routes,
      [
        PutioPlaybackRoute(name: "default", description: "Default proxy"),
        PutioPlaybackRoute(name: "edge", description: "Nearby proxy"),
      ])
    for body in [#"{"routes":[{"name":""}]}"#, #"{"routes":[{"name":"same"},{"name":"same"}]}"#] {
      RuntimeMockURLProtocol.setFixture(body, for: route)
      await assertRuntimeError(.invalidResponse) { _ = try await runtime.listPlaybackRoutes() }
    }
    let before = RuntimeMockURLProtocol.capturedRequests().count
    await assertRuntimeError(.invalidResponse) { _ = try await runtime.setPlaybackRoute(name: " ") }
    XCTAssertEqual(RuntimeMockURLProtocol.capturedRequests().count, before)
  }

  func testRejectedPlaybackPreferencesRemainFailuresWhenAccountValuesAreUnchanged() async {
    let (runtime, _) = await makeSignedInRuntime()
    RuntimeMockURLProtocol.setFixture(
      #"{"status":"ERROR"}"#, statusCode: 503, for: "POST /v2/account/settings")
    await assertRuntimeError(.transient) { _ = try await runtime.setPlaybackRoute(name: "edge") }
    await assertRuntimeError(.transient) { _ = try await runtime.setSubtitlesVisible(false) }
    await assertRuntimeError(.transient) {
      _ = try await runtime.setSubtitleAutoSelectionDisabled(true)
    }
    XCTAssertFalse(runtime.session.isAccountPreferencesStale)
    guard case .signedIn(let account) = runtime.session.state else {
      return XCTFail("missing account")
    }
    XCTAssertEqual(account.routeName, "default")
    XCTAssertFalse(account.hideSubtitles)
    XCTAssertFalse(account.dontAutoSelectSubtitles)
  }

  func testLostPlaybackPreferenceResponsesAcceptAuthoritativelyAppliedValues() async throws {
    let (runtime, _) = await makeSignedInRuntime()
    RuntimeMockURLProtocol.setFixture(
      #"{"status":"ERROR"}"#, statusCode: 503, for: "POST /v2/account/settings")
    RuntimeMockURLProtocol.setFixture(
      Self.accountInfo
        .replacingOccurrences(
          of: #""tunnel_route_name": "default""#, with: #""tunnel_route_name": "edge""#
        )
        .replacingOccurrences(of: #""hide_subtitles": false"#, with: #""hide_subtitles": true"#)
        .replacingOccurrences(
          of: #""dont_autoselect_subtitles": false"#, with: #""dont_autoselect_subtitles": true"#),
      for: "GET /v2/account/info")
    let route = try await runtime.setPlaybackRoute(name: "edge")
    let visibility = try await runtime.setSubtitlesVisible(false)
    let selection = try await runtime.setSubtitleAutoSelectionDisabled(true)
    XCTAssertTrue(route.accountRefreshed)
    XCTAssertTrue(visibility.accountRefreshed)
    XCTAssertTrue(selection.accountRefreshed)
    XCTAssertFalse(runtime.session.isAccountPreferencesStale)
    XCTAssertEqual(
      RuntimeMockURLProtocol.capturedRequests().filter { $0.url?.path == "/v2/account/settings" }
        .count, 3)
  }

  func testPlaybackPreferencesUseSingleFieldPatchesAndKeepAcknowledgedValues() async throws {
    let (runtime, _) = await makeSignedInRuntime()
    RuntimeMockURLProtocol.setFixture(#"{"status":"OK"}"#, for: "POST /v2/account/settings")
    RuntimeMockURLProtocol.setFixture(
      #"{"status":"ERROR"}"#, statusCode: 503, for: "GET /v2/account/info")
    _ = try await runtime.setPlaybackRoute(name: "edge")
    _ = try await runtime.setSubtitlesVisible(false)
    _ = try await runtime.setSubtitleAutoSelectionDisabled(true)
    _ = try await runtime.setTrashEnabled(false)
    guard case .signedIn(let account) = runtime.session.state else {
      return XCTFail("missing account")
    }
    XCTAssertEqual(account.routeName, "edge")
    XCTAssertTrue(account.hideSubtitles)
    XCTAssertTrue(account.dontAutoSelectSubtitles)
    XCTAssertFalse(account.trashEnabled)
    XCTAssertTrue(runtime.session.isAccountPreferencesStale)
    let writes = RuntimeMockURLProtocol.capturedRequests().filter {
      $0.url?.path == "/v2/account/settings"
    }
    let bodies = try writes.map { request in
      try XCTUnwrap(
        JSONSerialization.jsonObject(with: XCTUnwrap(requestBodyData(for: request)))
          as? [String: Any])
    }
    XCTAssertEqual(bodies.count, 4)
    XCTAssertEqual(bodies[0]["tunnel_route_name"] as? String, "edge")
    XCTAssertEqual(bodies[1]["hide_subtitles"] as? Bool, true)
    XCTAssertEqual(bodies[2]["dont_autoselect_subtitles"] as? Bool, true)
    XCTAssertTrue(bodies.allSatisfy { $0.count == 1 })
    RuntimeMockURLProtocol.setFixture(
      Self.accountInfo
        .replacingOccurrences(
          of: #""tunnel_route_name": "default""#, with: #""tunnel_route_name": "edge""#
        )
        .replacingOccurrences(of: #""hide_subtitles": false"#, with: #""hide_subtitles": true"#)
        .replacingOccurrences(
          of: #""dont_autoselect_subtitles": false"#, with: #""dont_autoselect_subtitles": true"#
        )
        .replacingOccurrences(of: #""trash_enabled": true"#, with: #""trash_enabled": false"#),
      for: "GET /v2/account/info")
    let refreshed = await runtime.refreshAccountPreferences()
    XCTAssertTrue(refreshed)
    XCTAssertEqual(runtime.session.state, .signedIn(account))

  }

  func testPreferenceWritesUseTypedSDKPatchesAndRefreshAuthoritativeSnapshot() async throws {
    let (runtime, _) = await makeSignedInRuntime()
    let settingsRoute = "POST /v2/account/settings"
    RuntimeMockURLProtocol.setFixture(#"{"status":"OK"}"#, for: settingsRoute)
    RuntimeMockURLProtocol.setFixture(
      Self.accountInfo.replacingOccurrences(of: "NAME_ASC", with: "SIZE_DESC"),
      for: "GET /v2/account/info")
    let sorted = try await runtime.setDefaultFolderSort(.sizeDescending)
    XCTAssertTrue(sorted.accountRefreshed)
    guard case .signedIn(let account) = runtime.session.state else {
      return XCTFail("missing account")
    }
    XCTAssertEqual(account.defaultSort, .sizeDescending)
    _ = try await runtime.setTrashEnabled(true)
    _ = try await runtime.setHistoryEnabled(false)
    let writes = RuntimeMockURLProtocol.capturedRequests().filter {
      $0.url?.path == "/v2/account/settings"
    }
    let bodies = try writes.map { request in
      try XCTUnwrap(
        JSONSerialization.jsonObject(with: XCTUnwrap(requestBodyData(for: request)))
          as? [String: Any])
    }
    XCTAssertEqual(bodies.count, 3)
    XCTAssertEqual(bodies[0]["sort_by"] as? String, "SIZE_DESC")
    XCTAssertEqual(bodies[1]["trash_enabled"] as? Bool, true)
    XCTAssertEqual(bodies[2]["history_enabled"] as? Bool, false)
    XCTAssertTrue(bodies.allSatisfy { $0.count == 1 })
    RuntimeMockURLProtocol.setFixture(
      #"{"status":"OK"}"#, for: "POST /v2/files/remove-sort-by-settings")
    let reset = try await runtime.resetFolderSorts()
    XCTAssertTrue(reset.accountRefreshed)
    XCTAssertEqual(runtime.session.folderSortsRevision, 1)
  }

  func testCommittedTrashDisableHasRefreshOnlyRecoveryAndKeepsAcknowledgedSetting() async throws {
    let (runtime, _) = await makeSignedInRuntime()
    RuntimeMockURLProtocol.setFixture(#"{"status":"OK"}"#, for: "POST /v2/account/settings")
    RuntimeMockURLProtocol.setFixture(
      #"{"status":"ERROR"}"#, statusCode: 503, for: "GET /v2/account/info")
    let result = try await runtime.setTrashEnabled(false)
    XCTAssertFalse(result.accountRefreshed)
    XCTAssertTrue(runtime.session.isAccountPreferencesStale)
    XCTAssertTrue(runtime.session.isAccountStorageStale)
    guard case .signedIn(let stale) = runtime.session.state else {
      return XCTFail("missing account")
    }
    XCTAssertFalse(stale.trashEnabled, "committed disable must not offer recoverable Trash")
    RuntimeMockURLProtocol.setFixture(
      Self.accountInfo.replacingOccurrences(
        of: "\"trash_enabled\": true", with: "\"trash_enabled\": false"),
      for: "GET /v2/account/info")
    let refreshed = await runtime.refreshAccountPreferences()
    XCTAssertTrue(refreshed)
    XCTAssertFalse(runtime.session.isAccountPreferencesStale)
    XCTAssertFalse(runtime.session.isAccountStorageStale)
    guard case .signedIn(let current) = runtime.session.state else {
      return XCTFail("missing account")
    }
    XCTAssertFalse(current.trashEnabled)
    XCTAssertEqual(
      RuntimeMockURLProtocol.capturedRequests().filter { $0.url?.path == "/v2/account/settings" }
        .count, 1)
  }

  func testPendingTrashDisableBlocksDeletionEvenAfterUnrelatedAccountRefresh() async throws {
    let (runtime, _) = await makeSignedInRuntime()
    let route = "POST /v2/account/settings"
    RuntimeMockURLProtocol.gateFixture(#"{"status":"OK"}"#, for: route)
    let saving = Task { try await runtime.setTrashEnabled(false) }
    defer {
      saving.cancel()
      RuntimeMockURLProtocol.releaseFixture(for: route)
    }
    guard await waitForRequest(route, count: 1) else {
      return XCTFail("preference write never started")
    }
    XCTAssertTrue(runtime.session.isUpdatingAccountPreferences)
    _ = await runtime.refreshAccountPreferences()
    XCTAssertTrue(runtime.session.isUpdatingAccountPreferences)
    let requests = RuntimeMockURLProtocol.capturedRequests().count
    await assertRuntimeError(.transient) {
      try await runtime.deleteFile(fileID: PutioFileID(rawValue: 411))
    }
    await assertRuntimeError(.transient) { _ = try await runtime.resetFolderSorts() }
    XCTAssertEqual(runtime.session.folderSortsRevision, 0)
    XCTAssertEqual(RuntimeMockURLProtocol.capturedRequests().count, requests)
    RuntimeMockURLProtocol.setFixture(
      Self.accountInfo.replacingOccurrences(
        of: "\"trash_enabled\": true", with: "\"trash_enabled\": false"),
      for: "GET /v2/account/info")
    RuntimeMockURLProtocol.releaseFixture(for: route)
    let result = try await saving.value
    XCTAssertTrue(result.accountRefreshed)
    XCTAssertFalse(runtime.session.isUpdatingAccountPreferences)
    guard case .signedIn(let account) = runtime.session.state else {
      return XCTFail("missing account")
    }
    XCTAssertFalse(account.trashEnabled)
  }

  func testPendingFolderSortResetSerializesSettingsWritesAndOtherResets() async throws {
    let (runtime, _) = await makeSignedInRuntime()
    let route = "POST /v2/files/remove-sort-by-settings"
    RuntimeMockURLProtocol.gateFixture(#"{"status":"OK"}"#, for: route)
    let resetting = Task { try await runtime.resetFolderSorts() }
    defer {
      resetting.cancel()
      RuntimeMockURLProtocol.releaseFixture(for: route)
    }
    guard await waitForRequest(route) else { return XCTFail("reset never started") }
    XCTAssertTrue(runtime.session.isUpdatingAccountPreferences)
    let requests = RuntimeMockURLProtocol.capturedRequests().count
    await assertRuntimeError(.transient) { _ = try await runtime.setTrashEnabled(false) }
    await assertRuntimeError(.transient) { _ = try await runtime.resetFolderSorts() }
    XCTAssertEqual(RuntimeMockURLProtocol.capturedRequests().count, requests)
    XCTAssertEqual(runtime.session.folderSortsRevision, 0)
    RuntimeMockURLProtocol.releaseFixture(for: route)
    _ = try await resetting.value
    XCTAssertFalse(runtime.session.isUpdatingAccountPreferences)
    XCTAssertEqual(runtime.session.folderSortsRevision, 1)
  }

  func testFolderSortResetCompletionAfterSignOutDoesNotInvalidateAnotherSession() async {
    let (runtime, _) = await makeSignedInRuntime()
    let route = "POST /v2/files/remove-sort-by-settings"
    RuntimeMockURLProtocol.gateFixture(#"{"status":"OK"}"#, for: route)
    let resetting = Task { try await runtime.resetFolderSorts() }
    defer {
      resetting.cancel()
      RuntimeMockURLProtocol.releaseFixture(for: route)
    }
    guard await waitForRequest(route) else { return XCTFail("reset never started") }
    await runtime.session.signOut()
    RuntimeMockURLProtocol.releaseFixture(for: route)
    await assertRuntimeError(.authenticationRequired) { _ = try await resetting.value }
    XCTAssertFalse(runtime.session.isUpdatingAccountPreferences)
    XCTAssertEqual(runtime.session.folderSortsRevision, 0)
  }

  func testRejectedFolderSortResetDoesNotReportSuccessFromUnchangedAccountSettings() async {
    let (runtime, _) = await makeSignedInRuntime()
    RuntimeMockURLProtocol.setFixture(
      #"{"status":"ERROR"}"#, statusCode: 503, for: "POST /v2/files/remove-sort-by-settings")
    await assertRuntimeError(.transient) { _ = try await runtime.resetFolderSorts() }
    XCTAssertFalse(runtime.session.isAccountPreferencesStale)
    XCTAssertEqual(runtime.session.folderSortsRevision, 1)
    XCTAssertFalse(runtime.session.isUpdatingAccountPreferences)
  }

  func testAmbiguousTrashDisableBlocksDeletionUntilAccountCanBeReconciled() async throws {
    let (runtime, _) = await makeSignedInRuntime()
    RuntimeMockURLProtocol.setFixture(
      #"{"status":"ERROR"}"#, statusCode: 503, for: "POST /v2/account/settings")
    RuntimeMockURLProtocol.setFixture(
      #"{"status":"ERROR"}"#, statusCode: 503, for: "GET /v2/account/info")
    await assertRuntimeError(.transient) { _ = try await runtime.setTrashEnabled(false) }
    XCTAssertTrue(runtime.session.isAccountPreferencesStale)
    XCTAssertTrue(runtime.session.isAccountStorageStale)
    let requests = RuntimeMockURLProtocol.capturedRequests().count
    await assertRuntimeError(.transient) {
      try await runtime.deleteFile(fileID: PutioFileID(rawValue: 411))
    }
    XCTAssertEqual(RuntimeMockURLProtocol.capturedRequests().count, requests)
    RuntimeMockURLProtocol.setFixture(
      Self.accountInfo.replacingOccurrences(
        of: "\"trash_enabled\": true", with: "\"trash_enabled\": false"),
      for: "GET /v2/account/info")
    let refreshed = await runtime.refreshAccountPreferences()
    XCTAssertTrue(refreshed)
    guard case .signedIn(let account) = runtime.session.state else {
      return XCTFail("missing account")
    }
    XCTAssertFalse(account.trashEnabled)
    RuntimeMockURLProtocol.setFixture(#"{"status":"OK"}"#, for: "POST /v2/files/delete")
    try await runtime.deleteFile(fileID: PutioFileID(rawValue: 411))
    XCTAssertEqual(
      RuntimeMockURLProtocol.capturedRequests().filter { $0.url?.path == "/v2/account/settings" }
        .count, 1)
  }

  func testLostWriteResponseAcceptsAuthoritativelyAppliedPreference() async throws {
    let (runtime, _) = await makeSignedInRuntime()
    RuntimeMockURLProtocol.setFixture(
      #"{"status":"ERROR"}"#, statusCode: 503, for: "POST /v2/account/settings")
    RuntimeMockURLProtocol.setFixture(
      Self.accountInfo.replacingOccurrences(
        of: "\"trash_enabled\": true", with: "\"trash_enabled\": false"),
      for: "GET /v2/account/info")
    let result = try await runtime.setTrashEnabled(false)
    XCTAssertTrue(result.accountRefreshed)
    XCTAssertFalse(runtime.session.isAccountPreferencesStale)
    XCTAssertEqual(
      RuntimeMockURLProtocol.capturedRequests().filter { $0.url?.path == "/v2/account/settings" }
        .count, 1)
  }

  func testOldAccountResponseCannotOverwritePreferencesAfterCommittedMutation() async throws {
    let (runtime, _) = await makeSignedInRuntime()
    let route = "GET /v2/account/info"
    RuntimeMockURLProtocol.gateFixture(
      Self.accountInfo.replacingOccurrences(of: "NAME_ASC", with: "DATE_DESC"), for: route)
    let older = Task { await runtime.refreshAccountPreferences() }
    guard await waitForRequest(route, count: 2) else {
      older.cancel()
      RuntimeMockURLProtocol.releaseFixture(for: route)
      return XCTFail("old refresh never started")
    }
    RuntimeMockURLProtocol.setFixture(#"{"status":"OK"}"#, for: "POST /v2/account/settings")
    RuntimeMockURLProtocol.setFixture(#"{"status":"ERROR"}"#, statusCode: 503, for: route)
    let saved = try await runtime.setHistoryEnabled(false)
    XCTAssertFalse(saved.accountRefreshed)
    RuntimeMockURLProtocol.releaseFixture(for: route)
    let oldResult = await older.value
    XCTAssertFalse(oldResult)
    XCTAssertTrue(runtime.session.isAccountPreferencesStale)
    guard case .signedIn(let account) = runtime.session.state else {
      return XCTFail("missing account")
    }
    XCTAssertEqual(
      account.defaultSort, .nameAscending, "obsolete response must not apply any fields")
    await runtime.session.signOut()
    XCTAssertFalse(runtime.session.isAccountPreferencesStale)
  }

  func testRejectedPreferenceIsReconciledAndUnknownSortStaysNil() async {
    let (runtime, _) = await makeSignedInRuntime()
    RuntimeMockURLProtocol.setFixture(
      #"{"status":"ERROR"}"#, statusCode: 503, for: "POST /v2/account/settings")
    await assertRuntimeError(.transient) { _ = try await runtime.setHistoryEnabled(false) }
    XCTAssertFalse(runtime.session.isAccountPreferencesStale)
    RuntimeMockURLProtocol.setFixture(
      Self.accountInfo.replacingOccurrences(of: "NAME_ASC", with: "FUTURE_SORT"),
      for: "GET /v2/account/info")
    let refreshed = await runtime.refreshAccountPreferences()
    XCTAssertTrue(refreshed)
    guard case .signedIn(let account) = runtime.session.state else {
      return XCTFail("missing account")
    }
    XCTAssertNil(account.defaultSort)
  }

  func testHistoryMapsSupportedEventsAndUsesRawPageBoundary() async throws {
    let (runtime, _) = await makeSignedInRuntime()
    RuntimeMockURLProtocol.setFixture(
      Self.historyFixture(
        [
          Self.historyEvent(
            99, type: "upload", fields: #""file_name":"Movie","file_size":42,"file_id":411"#),
          Self.historyEvent(
            98, type: "file_shared",
            fields: #""file_name":"Shared","sharing_user_name":"alice","file_id":410"#),
          Self.historyEvent(
            97, type: "transfer_completed",
            fields: #""transfer_name":"Complete","transfer_size":12,"file_id":0"#),
          Self.historyEvent(
            96, type: "transfer_error",
            fields: #""transfer_name":"Failed","source":"private-source""#),
          Self.historyEvent(
            95, type: "file_from_rss_deleted_for_space", fields: #""file_name":"Old","file_size":6"#
          ),
          Self.historyEvent(94, type: "rss_filter_paused", fields: #""rss_filter_title":"Feed""#),
          Self.historyEvent(93, type: "transfer_from_rss_error", fields: #""transfer_name":"RSS""#),
          Self.historyEvent(
            92, type: "transfer_callback_error",
            fields: #""transfer_name":"Callback","message":"private-callback""#),
          Self.historyEvent(91, type: "future_event"),
        ], hasMore: true), for: "GET /v2/events/list")
    let page = try await runtime.listHistory(before: 100)
    XCTAssertEqual(page.nextBefore, 91)
    XCTAssertEqual(page.items.map(\.id), Array((92...99).reversed()))
    XCTAssertEqual(
      page.items.map(\.kind),
      [
        .upload(name: "Movie", sizeBytes: 42, fileID: PutioFileID(rawValue: 411)),
        .fileShared(name: "Shared", sharingUserName: "alice", fileID: PutioFileID(rawValue: 410)),
        .transferCompleted(name: "Complete", sizeBytes: 12, fileID: nil),
        .transferError(name: "Failed"), .fileFromRSSDeleted(name: "Old", sizeBytes: 6),
        .rssFilterPaused(title: "Feed"), .transferFromRSSError(name: "RSS"),
        .transferCallbackError(name: "Callback"),
      ])
    XCTAssertEqual(page.items.first?.fileID, PutioFileID(rawValue: 411))
    XCTAssertNil(page.items[2].fileID)
    XCTAssertFalse(String(reflecting: page).contains("private-"))
    let request = try XCTUnwrap(RuntimeMockURLProtocol.capturedRequests().last)
    let components = try XCTUnwrap(
      request.url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false) })
    XCTAssertEqual(components.queryItems?.first { $0.name == "before" }?.value, "100")
    XCTAssertEqual(components.queryItems?.first { $0.name == "per_page" }?.value, "50")
  }

  func testHistoryFilteredPageRetainsContinuationAndFinalPageEndsIt() async throws {
    let (runtime, _) = await makeSignedInRuntime()
    RuntimeMockURLProtocol.setFixture(
      Self.historyFixture(
        [
          Self.historyEvent(90, type: "voucher"), Self.historyEvent(89, type: "zip_created"),
        ], hasMore: true), for: "GET /v2/events/list")
    let filtered = try await runtime.listHistory()
    XCTAssertEqual(filtered, PutioHistoryPage(items: [], nextBefore: 89))
    RuntimeMockURLProtocol.setFixture(
      Self.historyFixture([], hasMore: false), for: "GET /v2/events/list")
    let final = try await runtime.listHistory(before: 89)
    XCTAssertEqual(final, PutioHistoryPage(items: [], nextBefore: nil))
  }

  func testHistoryRejectsMalformedPagination() async {
    let (runtime, _) = await makeSignedInRuntime()
    for events in [
      [], [Self.historyEvent(0, type: "upload")], [Self.historyEvent(100, type: "upload")],
    ] {
      RuntimeMockURLProtocol.setFixture(
        Self.historyFixture(events, hasMore: true), for: "GET /v2/events/list")
      await assertRuntimeError(.invalidResponse) { _ = try await runtime.listHistory(before: 100) }
    }
    let count = RuntimeMockURLProtocol.capturedRequests().count
    await assertRuntimeError(.invalidResponse) { _ = try await runtime.listHistory(before: 0) }
    await assertRuntimeError(.invalidResponse) { try await runtime.deleteHistoryEvent(id: -1) }
    XCTAssertEqual(RuntimeMockURLProtocol.capturedRequests().count, count)
  }

  func testHistoryMutationsUseSDKRoutesAndPreserveSessionOnFailure() async throws {
    let (runtime, _) = await makeSignedInRuntime()
    RuntimeMockURLProtocol.setFixture(#"{"status":"OK"}"#, for: "POST /v2/events/delete/99")
    RuntimeMockURLProtocol.setFixture(#"{"status":"OK"}"#, for: "POST /v2/events/delete")
    try await runtime.deleteHistoryEvent(id: 99)
    try await runtime.clearHistory()
    XCTAssertEqual(
      RuntimeMockURLProtocol.capturedRequests().suffix(2).compactMap { $0.url?.path },
      ["/v2/events/delete/99", "/v2/events/delete"])
    RuntimeMockURLProtocol.setFixture(
      #"{"status":"ERROR"}"#, statusCode: 503, for: "POST /v2/events/delete")
    await assertRuntimeError(.transient) { try await runtime.clearHistory() }
    guard case .signedIn = runtime.session.state else {
      return XCTFail("transient failure expired session")
    }
  }

  func testHistoryRequiresAuthenticationAndExpiresRejectedSessions() async {
    let (signedOut, _) = makeRuntime(token: nil)
    await assertRuntimeError(.authenticationRequired) { _ = try await signedOut.listHistory() }
    await assertRuntimeError(.authenticationRequired) {
      try await signedOut.deleteHistoryEvent(id: 1)
    }
    await assertRuntimeError(.authenticationRequired) { try await signedOut.clearHistory() }
    XCTAssertTrue(RuntimeMockURLProtocol.capturedRequests().isEmpty)
    let (runtime, store) = await makeSignedInRuntime()
    RuntimeMockURLProtocol.setFixture(
      #"{"status":"ERROR"}"#, statusCode: 401, for: "GET /v2/events/list")
    await assertRuntimeError(.sessionExpired) { _ = try await runtime.listHistory() }
    XCTAssertEqual(runtime.session.state, .signedOut(.sessionExpired))
    XCTAssertNil(try? store.read())
  }

  func testFileLookupMapsAuthoritativeFileAndRejectsWrongIdentity() async throws {
    let (runtime, _) = await makeSignedInRuntime()
    let route = "GET /v2/files/410"
    let fixture =
      #"{"file":{"id":410,"name":"Folder","file_type":"FOLDER","parent_id":42,"size":0,"created_at":"2026-08-28T10:00:00Z","updated_at":"2026-08-29T10:00:00Z"}}"#
    RuntimeMockURLProtocol.setFixture(fixture, for: route)
    let file = try await runtime.getFile(fileID: PutioFileID(rawValue: 410))
    XCTAssertEqual(file.kind, .folder)
    XCTAssertEqual(file.parentID, PutioFileID(rawValue: 42))
    RuntimeMockURLProtocol.setFixture(
      fixture.replacingOccurrences(of: "410", with: "411"), for: route)
    await assertRuntimeError(.invalidResponse) {
      _ = try await runtime.getFile(fileID: PutioFileID(rawValue: 410))
    }
    RuntimeMockURLProtocol.setFixture(#"{"status":"ERROR"}"#, statusCode: 404, for: route)
    await assertRuntimeError(.notFound) {
      _ = try await runtime.getFile(fileID: PutioFileID(rawValue: 410))
    }
  }

  private static func historyEvent(_ id: Int, type: String, fields: String = "") -> String {
    let extra = fields.isEmpty ? "" : "," + fields
    return """
      {"id":\(id),"user_id":1001,"type":"\(type)","created_at":"2026-09-08T10:00:00Z"\(extra)}
      """
  }

  private static func historyFixture(_ events: [String], hasMore: Bool) -> String {
    """
    {"status":"OK","has_more":\(hasMore),"events":[\(events.joined(separator: ","))]}
    """
  }

  func testSetFolderSortPostsTheServerKey() async throws {
    let (runtime, _) = await makeSignedInRuntime()
    RuntimeMockURLProtocol.setFixture(#"{"status":"OK"}"#, for: Self.setSortRoute)

    try await runtime.setFolderSort(folderID: PutioFileID(rawValue: 42), sort: .sizeDescending)

    let request = try XCTUnwrap(RuntimeMockURLProtocol.capturedRequests().last)
    XCTAssertEqual(request.url?.path, "/v2/files/set-sort-by")
    let body = try XCTUnwrap(requestBodyData(for: request))
    let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
    XCTAssertEqual(json["file_id"] as? Int, 42)
    XCTAssertEqual(json["sort_by"] as? String, "SIZE_DESC")
  }

  func testListSendsTheRequestedParentID() async throws {
    let (runtime, _) = await makeSignedInRuntime()
    RuntimeMockURLProtocol.setFixture(Self.filesList(cursor: nil), for: Self.filesRoute)

    _ = try await runtime.listFiles(parentID: PutioFileID(rawValue: 42))

    let request = try XCTUnwrap(RuntimeMockURLProtocol.capturedRequests().last)
    let components = try XCTUnwrap(
      request.url.flatMap {
        URLComponents(url: $0, resolvingAgainstBaseURL: false)
      }
    )
    XCTAssertEqual(
      components.queryItems?.first(where: { $0.name == "parent_id" })?.value,
      "42"
    )
  }

  func testFileActionsUseSDKOwnedRoutesAndMapCreatedFolder() async throws {
    let (runtime, _) = await makeSignedInRuntime()
    RuntimeMockURLProtocol.setFixture(
      """
      {
        "file": {
          "id": 91,
          "name": "Season 2",
          "file_type": "FOLDER",
          "parent_id": 7,
          "size": 0,
          "created_at": "2026-09-01T10:00:00Z",
          "updated_at": "2026-09-01T10:00:00Z"
        }
      }
      """,
      for: Self.createFolderRoute
    )
    RuntimeMockURLProtocol.setFixture(#"{"status":"OK"}"#, for: Self.renameFileRoute)
    RuntimeMockURLProtocol.setFixture(#"{"status":"OK"}"#, for: Self.deleteFilesRoute)

    let folder = try await runtime.createFolder(
      name: "Season 2",
      parentID: PutioFileID(rawValue: 7)
    )
    try await runtime.renameFile(fileID: folder.id, name: "Season Two")
    try await runtime.deleteFile(fileID: folder.id)

    XCTAssertEqual(folder.id, PutioFileID(rawValue: 91))
    XCTAssertEqual(folder.parentID, PutioFileID(rawValue: 7))
    XCTAssertEqual(folder.name, "Season 2")
    XCTAssertEqual(folder.kind, .folder)

    let actionRequests = RuntimeMockURLProtocol.capturedRequests().suffix(3)
    XCTAssertEqual(
      actionRequests.compactMap { $0.url?.path },
      ["/v2/files/create-folder", "/v2/files/rename", "/v2/files/delete"]
    )
    let bodies = try actionRequests.map { request -> [String: Any] in
      let data = try XCTUnwrap(requestBodyData(for: request))
      return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }
    XCTAssertEqual(bodies[0]["name"] as? String, "Season 2")
    XCTAssertEqual(bodies[0]["parent_id"] as? Int, 7)
    XCTAssertEqual(bodies[1]["file_id"] as? Int, 91)
    XCTAssertEqual(bodies[1]["name"] as? String, "Season Two")
    XCTAssertEqual(bodies[2]["file_ids"] as? String, "91")
  }

  func testMoveFileUsesSingleItemSDKRequestAndAcceptsAnEmptyErrorList() async throws {
    let (runtime, _) = await makeSignedInRuntime()
    RuntimeMockURLProtocol.setFixture(
      #"{"status":"OK","errors":[]}"#,
      for: Self.moveFilesRoute
    )

    try await runtime.moveFile(
      fileID: PutioFileID(rawValue: 91),
      to: PutioFileID(rawValue: 7)
    )

    let request = try XCTUnwrap(RuntimeMockURLProtocol.capturedRequests().last)
    XCTAssertEqual(request.httpMethod, "POST")
    XCTAssertEqual(request.url?.path, "/v2/files/move")
    let body = try XCTUnwrap(requestBodyData(for: request))
    let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
    XCTAssertEqual(json["file_ids"] as? String, "91")
    XCTAssertEqual(json["parent_id"] as? Int, 7)
  }

  func testMoveFileMapsAReportedItemFailureWithoutExpiringTheSession() async {
    let cases: [(Int, PutioRuntimeError)] = [
      (403, .unknown),
      (404, .notFound),
      (408, .transient),
      (429, .rateLimited),
      (500, .transient),
    ]

    for (statusCode, expected) in cases {
      RuntimeMockURLProtocol.reset()
      let (runtime, tokenStore) = await makeSignedInRuntime()
      RuntimeMockURLProtocol.setFixture(
        """
        {
          "status": "OK",
          "errors": [
            {
              "error_type": "MOVE_FAILED",
              "id": 91,
              "name": "Season 2",
              "status_code": \(statusCode)
            }
          ]
        }
        """,
        for: Self.moveFilesRoute
      )

      await assertRuntimeError(expected) {
        try await runtime.moveFile(
          fileID: PutioFileID(rawValue: 91),
          to: PutioFileID(rawValue: 7)
        )
      }

      guard case .signedIn = runtime.session.state else {
        return XCTFail("a structured item failure must preserve the signed-in session")
      }
      XCTAssertEqual(try? tokenStore.read(), "stored-token")
    }
  }

  func testMoveFileRejectsContradictoryOrMismatchedStructuredResponses() async {
    let (runtime, _) = await makeSignedInRuntime()
    let responses = [
      #"{"status":"ERROR","errors":[]}"#,
      """
      {
        "status": "OK",
        "errors": [
          {
            "error_type": "MOVE_FAILED",
            "id": 92,
            "status_code": 404
          }
        ]
      }
      """,
    ]

    for response in responses {
      RuntimeMockURLProtocol.setFixture(response, for: Self.moveFilesRoute)
      await assertRuntimeError(.invalidResponse) {
        try await runtime.moveFile(
          fileID: PutioFileID(rawValue: 91),
          to: PutioFileID(rawValue: 7)
        )
      }
    }
  }

  func testMoveFileAuthenticationFailureUsesTheSharedSessionBoundary() async {
    let (runtime, tokenStore) = await makeSignedInRuntime()
    RuntimeMockURLProtocol.setFixture(
      #"{"status":"ERROR","error_type":"invalid_grant"}"#,
      statusCode: 401,
      for: Self.moveFilesRoute
    )

    await assertRuntimeError(.sessionExpired) {
      try await runtime.moveFile(
        fileID: PutioFileID(rawValue: 91),
        to: PutioFileID(rawValue: 7)
      )
    }

    XCTAssertEqual(runtime.session.state, .signedOut(.sessionExpired))
    XCTAssertNil(try? tokenStore.read())
  }

  func testListTrashMapsAppOwnedPageAndItemValues() async throws {
    let (runtime, _) = await makeSignedInRuntime()
    RuntimeMockURLProtocol.setFixture(
      """
      {
        "cursor": "trash-page-2",
        "total": 3,
        "trash_size": 4096,
        "files": [
          {
            "id": 91,
            "name": "Old episode.mkv",
            "file_type": "VIDEO",
            "parent_id": 7,
            "size": 2048,
            "created_at": "2026-08-28T10:00:00Z",
            "deleted_at": "2026-09-01T11:00:00Z",
            "expiration_date": "2026-10-01T11:00:00Z"
          }
        ]
      }
      """,
      for: Self.trashListRoute
    )

    let page = try await runtime.listTrash()

    XCTAssertEqual(page.nextCursor, "trash-page-2")
    XCTAssertEqual(page.totalCount, 3)
    XCTAssertEqual(page.sizeBytes, 4_096)
    let item = try XCTUnwrap(page.items.first)
    XCTAssertEqual(item.id, PutioFileID(rawValue: 91))
    XCTAssertEqual(item.parentID, PutioFileID(rawValue: 7))
    XCTAssertEqual(item.name, "Old episode.mkv")
    XCTAssertEqual(item.kind, .video)
    XCTAssertEqual(item.sizeBytes, 2_048)
    XCTAssertEqual(
      item.deletedAt,
      try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-09-01T11:00:00Z"))
    )
    XCTAssertEqual(
      item.expiresAt,
      try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-10-01T11:00:00Z"))
    )
  }

  func testListTrashContinuationUsesCursorRequestAndDropsEmptyNextCursor() async throws {
    let (runtime, _) = await makeSignedInRuntime()
    RuntimeMockURLProtocol.setFixture(
      #"{"cursor":"","trash_size":0,"files":[]}"#,
      for: Self.trashContinueRoute
    )

    let page = try await runtime.listTrash(cursor: "trash-page-2")

    XCTAssertNil(page.nextCursor)
    let request = try XCTUnwrap(RuntimeMockURLProtocol.capturedRequests().last)
    XCTAssertEqual(request.httpMethod, "POST")
    XCTAssertEqual(request.url?.path, "/v2/trash/list/continue")
    let body = try XCTUnwrap(requestBodyData(for: request))
    let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
    XCTAssertEqual(json["cursor"] as? String, "trash-page-2")
  }

  func testTrashMutationsUseSingleItemSDKRequests() async throws {
    let (runtime, _) = await makeSignedInRuntime()
    RuntimeMockURLProtocol.setFixture(#"{"status":"OK"}"#, for: Self.trashRestoreRoute)
    RuntimeMockURLProtocol.setFixture(
      """
      {
        "file": {
          "id": 91,
          "name": "Old episode.mkv",
          "file_type": "VIDEO",
          "parent_id": 7,
          "size": 2048,
          "created_at": "2026-08-28T10:00:00Z",
          "updated_at": "2026-09-03T10:00:00Z"
        }
      }
      """,
      for: Self.restoredTrashFileRoute
    )
    RuntimeMockURLProtocol.setFixture(#"{"status":"OK"}"#, for: Self.trashDeleteRoute)
    RuntimeMockURLProtocol.setFixture(#"{"status":"OK"}"#, for: Self.trashEmptyRoute)
    let fileID = PutioFileID(rawValue: 91)

    let restoredItem = try await runtime.restoreTrashItem(fileID: fileID)
    RuntimeMockURLProtocol.setFixture(
      Self.accountInfo.replacingOccurrences(of: "\"used\": 20", with: "\"used\": 10"),
      for: "GET /v2/account/info"
    )
    let deleteOutcome = try await runtime.permanentlyDeleteTrashItem(fileID: fileID)
    XCTAssertTrue(deleteOutcome.storageRefreshed)
    guard case .signedIn(let afterDelete) = runtime.session.state else {
      return XCTFail("expected account after deletion")
    }
    XCTAssertEqual(afterDelete.storage.usedBytes, 10)
    RuntimeMockURLProtocol.setFixture(
      Self.accountInfo.replacingOccurrences(of: "\"used\": 20", with: "\"used\": 0"),
      for: "GET /v2/account/info"
    )
    let emptyOutcome = try await runtime.emptyTrash()
    XCTAssertTrue(emptyOutcome.storageRefreshed)
    guard case .signedIn(let afterEmpty) = runtime.session.state else {
      return XCTFail("expected account after emptying Trash")
    }
    XCTAssertEqual(afterEmpty.storage.usedBytes, 0)

    XCTAssertEqual(restoredItem, .restored(destinationID: PutioFileID(rawValue: 7)))
    let requests = RuntimeMockURLProtocol.capturedRequests().suffix(6)
    XCTAssertEqual(
      requests.compactMap { $0.url?.path },
      [
        "/v2/trash/restore", "/v2/files/91", "/v2/trash/delete", "/v2/account/info",
        "/v2/trash/empty", "/v2/account/info",
      ]
    )
    XCTAssertEqual(requests.map(\.httpMethod), ["POST", "GET", "POST", "GET", "POST", "GET"])
    for request in [
      requests[requests.startIndex], requests[requests.index(requests.startIndex, offsetBy: 2)],
    ] {
      let body = try XCTUnwrap(requestBodyData(for: request))
      let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
      XCTAssertEqual(json["file_ids"] as? String, "91")
      XCTAssertNil(json["cursor"])
    }
  }

  func testRestoreSurfacesCancellationDuringDestinationLookup() async throws {
    let (runtime, _) = await makeSignedInRuntime()
    RuntimeMockURLProtocol.setFixture(#"{"status":"OK"}"#, for: Self.trashRestoreRoute)
    RuntimeMockURLProtocol.gateFixture(#"{"status":"OK"}"#, for: Self.restoredTrashFileRoute)

    let restore = Task { try await runtime.restoreTrashItem(fileID: PutioFileID(rawValue: 91)) }
    guard await waitForRequest(Self.restoredTrashFileRoute) else {
      restore.cancel()
      RuntimeMockURLProtocol.releaseFixture(for: Self.restoredTrashFileRoute)
      return XCTFail("the destination lookup did not start")
    }
    restore.cancel()
    RuntimeMockURLProtocol.releaseFixture(for: Self.restoredTrashFileRoute)

    let result = try await restore.value
    XCTAssertEqual(result, .restoredLookupCancelled, "the restore itself is committed")
  }

  func testRestoreCancelledBeforeCommitThrows() async throws {
    let (runtime, _) = await makeSignedInRuntime()
    RuntimeMockURLProtocol.gateFixture(#"{"status":"OK"}"#, for: Self.trashRestoreRoute)

    let restore = Task { try await runtime.restoreTrashItem(fileID: PutioFileID(rawValue: 91)) }
    guard await waitForRequest(Self.trashRestoreRoute) else {
      restore.cancel()
      RuntimeMockURLProtocol.releaseFixture(for: Self.trashRestoreRoute)
      return XCTFail("the restore request did not start")
    }
    restore.cancel()
    RuntimeMockURLProtocol.releaseFixture(for: Self.trashRestoreRoute)

    do {
      let result = try await restore.value
      XCTFail("expected an error before commit, got \(result)")
    } catch is CancellationError {
      // The runtime normalizes URLSession cancellation to CancellationError,
      // so callers only ever classify one representation.
    } catch {
      XCTFail("expected CancellationError, got \(error)")
    }
  }

  func testRestorePreservesCommittedMutationWhenDestinationLookupFails() async throws {
    let (runtime, _) = await makeSignedInRuntime()
    RuntimeMockURLProtocol.setFixture(#"{"status":"OK"}"#, for: Self.trashRestoreRoute)
    RuntimeMockURLProtocol.setFixture(
      #"{"error_type":"service_unavailable"}"#,
      statusCode: 503,
      for: Self.restoredTrashFileRoute
    )

    let result = try await runtime.restoreTrashItem(fileID: PutioFileID(rawValue: 91))

    XCTAssertEqual(result, .restoredDestinationUnknown)
    XCTAssertEqual(
      RuntimeMockURLProtocol.capturedRequests().suffix(2).compactMap { $0.url?.path },
      ["/v2/trash/restore", "/v2/files/91"]
    )
  }

  func testTrashMutationSuccessSurvivesAccountRefreshFailure() async throws {
    let (runtime, _) = await makeSignedInRuntime()
    let originalState = runtime.session.state
    RuntimeMockURLProtocol.setFixture(#"{"status":"OK"}"#, for: Self.trashDeleteRoute)
    RuntimeMockURLProtocol.setFixture(#"{"status":"OK"}"#, for: Self.trashEmptyRoute)
    RuntimeMockURLProtocol.setFixture(
      #"{"status":"ERROR","error_type":"TEMPORARY_ERROR"}"#,
      statusCode: 503,
      for: "GET /v2/account/info"
    )

    XCTAssertFalse(runtime.session.isAccountStorageStale)
    let deleteResult = try await runtime.permanentlyDeleteTrashItem(
      fileID: PutioFileID(rawValue: 91))
    XCTAssertEqual(runtime.session.state, originalState)
    XCTAssertFalse(deleteResult.storageRefreshed)
    XCTAssertTrue(runtime.session.isAccountStorageStale, "the session remembers stale storage")
    let emptyResult = try await runtime.emptyTrash()
    XCTAssertEqual(runtime.session.state, originalState)
    XCTAssertFalse(emptyResult.storageRefreshed)

    RuntimeMockURLProtocol.setFixture(
      Self.accountInfo.replacingOccurrences(of: "\"used\": 20", with: "\"used\": 5"),
      for: "GET /v2/account/info"
    )
    let refreshed = await runtime.refreshAccountStorage()
    XCTAssertTrue(refreshed)
    XCTAssertFalse(runtime.session.isAccountStorageStale)
    guard case .signedIn(let account) = runtime.session.state else {
      return XCTFail("expected a signed-in account after the storage retry")
    }
    XCTAssertEqual(account.storage.usedBytes, 5)
  }

  func testStaleStorageDoesNotOutliveTheSession() async throws {
    let (runtime, _) = await makeSignedInRuntime()
    RuntimeMockURLProtocol.setFixture(#"{"status":"OK"}"#, for: Self.trashEmptyRoute)
    RuntimeMockURLProtocol.setFixture(
      #"{"status":"ERROR","error_type":"TEMPORARY_ERROR"}"#,
      statusCode: 503,
      for: "GET /v2/account/info"
    )
    _ = try await runtime.emptyTrash()
    XCTAssertTrue(runtime.session.isAccountStorageStale)

    await runtime.session.signOut()
    XCTAssertFalse(runtime.session.isAccountStorageStale)
  }

  func testRefreshStartedBeforeAMutationCannotClearStaleStorage() async throws {
    let route = "GET /v2/account/info"
    let (runtime, _) = await makeSignedInRuntime()
    RuntimeMockURLProtocol.gateFixture(Self.accountInfo, for: route)
    let preMutation = Task { await runtime.refreshAccountStorage() }
    guard await waitForRequest(route, count: 2) else {
      preMutation.cancel()
      RuntimeMockURLProtocol.releaseFixture(for: route)
      return XCTFail("the gated account refresh did not start")
    }

    RuntimeMockURLProtocol.setFixture(#"{"status":"OK"}"#, for: Self.trashEmptyRoute)
    RuntimeMockURLProtocol.setFixture(
      #"{"status":"ERROR","error_type":"TEMPORARY_ERROR"}"#, statusCode: 503, for: route)
    let emptied = try await runtime.emptyTrash()
    XCTAssertFalse(emptied.storageRefreshed)
    XCTAssertTrue(runtime.session.isAccountStorageStale)

    RuntimeMockURLProtocol.releaseFixture(for: route)
    let preMutationResult = await preMutation.value
    XCTAssertFalse(preMutationResult, "a pre-mutation snapshot does not satisfy the retry")
    XCTAssertTrue(runtime.session.isAccountStorageStale, "stale storage stays visible")

    RuntimeMockURLProtocol.setFixture(
      Self.accountInfo.replacingOccurrences(of: "\"used\": 20", with: "\"used\": 0"), for: route)
    let retried = await runtime.refreshAccountStorage()
    XCTAssertTrue(retried)
    XCTAssertFalse(runtime.session.isAccountStorageStale)
  }

  func testOlderSuccessfulRefreshAppliesWhenTheNewerRefreshFailed() async throws {
    let route = "GET /v2/account/info"
    let (runtime, _) = await makeSignedInRuntime()
    RuntimeMockURLProtocol.gateFixture(
      Self.accountInfo.replacingOccurrences(of: "\"used\": 20", with: "\"used\": 99"),
      for: route
    )
    let older = Task { await runtime.refreshAccountStorage() }
    guard await waitForRequest(route, count: 2) else {
      older.cancel()
      RuntimeMockURLProtocol.releaseFixture(for: route)
      return XCTFail("the gated account refresh did not start")
    }

    RuntimeMockURLProtocol.setFixture(
      #"{"status":"ERROR","error_type":"TEMPORARY_ERROR"}"#, statusCode: 503, for: route)
    let newer = await runtime.refreshAccountStorage()
    XCTAssertFalse(newer)

    RuntimeMockURLProtocol.releaseFixture(for: route)
    let olderResult = await older.value
    XCTAssertTrue(olderResult)
    guard case .signedIn(let account) = runtime.session.state else {
      return XCTFail("expected a signed-in account")
    }
    XCTAssertEqual(account.storage.usedBytes, 99, "the only successful response is the truth")
  }

  func testOlderAccountRefreshCannotOverwriteANewerSnapshotInTheSameSession() async throws {
    let route = "GET /v2/account/info"
    let (runtime, _) = await makeSignedInRuntime()
    RuntimeMockURLProtocol.gateFixture(
      Self.accountInfo.replacingOccurrences(of: "\"used\": 20", with: "\"used\": 99"),
      for: route
    )
    let older = Task { await runtime.refreshAccountStorage() }
    guard await waitForRequest(route, count: 2) else {
      older.cancel()
      RuntimeMockURLProtocol.releaseFixture(for: route)
      return XCTFail("the gated account refresh did not start")
    }

    RuntimeMockURLProtocol.setFixture(
      Self.accountInfo.replacingOccurrences(of: "\"used\": 20", with: "\"used\": 5"),
      for: route
    )
    let newer = await runtime.refreshAccountStorage()
    XCTAssertTrue(newer)

    RuntimeMockURLProtocol.releaseFixture(for: route)
    let olderResult = await older.value
    XCTAssertTrue(olderResult, "the older refresh still succeeded for its caller")

    guard case .signedIn(let account) = runtime.session.state else {
      return XCTFail("expected a signed-in account")
    }
    XCTAssertEqual(account.storage.usedBytes, 5, "the slower older response must not win")
  }

  func testTrashAccountRefreshAuthFailureExpiresSessionWithoutFailingMutation() async throws {
    let (runtime, tokenStore) = await makeSignedInRuntime()
    RuntimeMockURLProtocol.setFixture(#"{"status":"OK"}"#, for: Self.trashEmptyRoute)
    RuntimeMockURLProtocol.setFixture(
      #"{"status":"ERROR","error_type":"invalid_grant"}"#,
      statusCode: 401,
      for: "GET /v2/account/info"
    )

    _ = try await runtime.emptyTrash()

    XCTAssertEqual(runtime.session.state, .signedOut(.sessionExpired))
    XCTAssertNil(try tokenStore.read())
  }

  func testOldTrashAccountRefreshCannotChangeANewerSession() async throws {
    let route = "GET /v2/account/info"
    for (statusCode, body) in [
      (200, Self.accountInfo),
      (401, #"{"status":"ERROR","error_type":"invalid_grant"}"#),
    ] {
      RuntimeMockURLProtocol.reset()
      let (runtime, tokenStore) = await makeSignedInRuntime()
      RuntimeMockURLProtocol.setFixture(#"{"status":"OK"}"#, for: Self.trashEmptyRoute)
      RuntimeMockURLProtocol.gateFixture(body, statusCode: statusCode, for: route)
      let mutation = Task { try await runtime.emptyTrash() }
      guard await waitForRequest(route, count: 2) else {
        mutation.cancel()
        RuntimeMockURLProtocol.releaseFixture(for: route)
        return XCTFail("post-mutation account refresh did not start")
      }

      await runtime.session.signOut()
      RuntimeMockURLProtocol.setFixture(
        Self.accountInfo.replacingOccurrences(of: "moviebuff", with: "fresh-user"), for: route)
      let request = try runtime.session.beginSignIn()
      let oauthState = try XCTUnwrap(oauthState(from: request.url))
      let callback = try XCTUnwrap(
        URL(string: "putio://auth#access_token=fresh-token&state=\(oauthState)"))
      await runtime.session.completeSignIn(callbackURL: callback)
      RuntimeMockURLProtocol.releaseFixture(for: route)
      _ = try await mutation.value

      guard case .signedIn(let account) = runtime.session.state else {
        return XCTFail("old account HTTP \(statusCode) response expired the new session")
      }
      XCTAssertEqual(account.username, "fresh-user")
      XCTAssertEqual(try tokenStore.read(), "fresh-token")
    }
  }

  func testTrashMutationsRejectNonOKStatuses() async {
    let (runtime, _) = await makeSignedInRuntime()
    RuntimeMockURLProtocol.setFixture(#"{"status":"ERROR"}"#, for: Self.trashRestoreRoute)
    RuntimeMockURLProtocol.setFixture(#"{"status":"ERROR"}"#, for: Self.trashDeleteRoute)
    RuntimeMockURLProtocol.setFixture(#"{"status":"ERROR"}"#, for: Self.trashEmptyRoute)

    await assertRuntimeError(.invalidResponse) {
      _ = try await runtime.restoreTrashItem(fileID: PutioFileID(rawValue: 91))
    }
    await assertRuntimeError(.invalidResponse) {
      _ = try await runtime.permanentlyDeleteTrashItem(fileID: PutioFileID(rawValue: 91))
    }
    await assertRuntimeError(.invalidResponse) {
      _ = try await runtime.emptyTrash()
    }
  }

  func testFindNextVideoMapsAppOwnedSuccessorAndVideoQuery() async throws {
    let (runtime, _) = await makeSignedInRuntime()
    RuntimeMockURLProtocol.setFixture(
      """
      {
        "next_file": {
          "id": 412,
          "name": "Episode 2.mkv",
          "parent_id": 7,
          "file_type": "VIDEO"
        }
      }
      """,
      for: Self.nextVideoRoute
    )

    let nextVideo = try await runtime.findNextVideo(
      after: PutioFileID(rawValue: 411)
    )

    XCTAssertEqual(
      nextVideo,
      PutioNextVideo(
        id: PutioFileID(rawValue: 412),
        parentID: PutioFileID(rawValue: 7),
        name: "Episode 2.mkv"
      )
    )
    let request = try XCTUnwrap(RuntimeMockURLProtocol.capturedRequests().last)
    XCTAssertEqual(request.url?.path, "/v2/files/411/next-file")
    let components = try XCTUnwrap(
      request.url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false) }
    )
    XCTAssertEqual(
      components.queryItems?.first(where: { $0.name == "file_type" })?.value,
      "VIDEO"
    )
  }

  func testFindNextVideoMapsNullSuccessorToNil() async throws {
    let (runtime, _) = await makeSignedInRuntime()
    RuntimeMockURLProtocol.setFixture(
      #"{"next_file":null}"#,
      for: Self.nextVideoRoute
    )

    let nextVideo = try await runtime.findNextVideo(
      after: PutioFileID(rawValue: 411)
    )

    XCTAssertNil(nextVideo)
  }

  func testFindNextVideoRejectsMissingSuccessorField() async {
    let (runtime, _) = await makeSignedInRuntime()
    RuntimeMockURLProtocol.setFixture("{}", for: Self.nextVideoRoute)

    await assertRuntimeError(.invalidResponse) {
      _ = try await runtime.findNextVideo(after: PutioFileID(rawValue: 411))
    }
  }

  func testUnauthenticatedRuntimeRejectsNextVideoWithoutARequest() async {
    let (runtime, _) = makeRuntime(token: nil)

    await assertRuntimeError(.authenticationRequired) {
      _ = try await runtime.findNextVideo(after: PutioFileID(rawValue: 411))
    }

    XCTAssertTrue(RuntimeMockURLProtocol.capturedRequests().isEmpty)
  }

  func testFindNextVideoCancellationPreservesSignedInSessionAndToken() async {
    let (runtime, tokenStore) = await makeSignedInRuntime()
    RuntimeMockURLProtocol.suspend(Self.nextVideoRoute)

    let task = Task {
      try await runtime.findNextVideo(after: PutioFileID(rawValue: 411))
    }
    guard await waitForRequest(Self.nextVideoRoute) else {
      task.cancel()
      return XCTFail("next-video request did not start")
    }
    task.cancel()

    do {
      _ = try await task.value
      XCTFail("expected cancellation")
    } catch is CancellationError {
    } catch {
      XCTFail("expected CancellationError, got \(error)")
    }

    guard case .signedIn = runtime.session.state else {
      return XCTFail("cancellation must preserve the signed-in session")
    }
    XCTAssertEqual(try? tokenStore.read(), "stored-token")
  }

  func testUnauthenticatedRuntimeRejectsPlaybackResolutionWithoutARequest() async {
    let (runtime, _) = makeRuntime(token: nil)

    await assertRuntimeError(.authenticationRequired) {
      _ = try await runtime.resolveVideoPlaybackSource(fileID: PutioFileID(rawValue: 411))
    }

    XCTAssertTrue(RuntimeMockURLProtocol.capturedRequests().isEmpty)
  }

  func testPlaybackResolutionMapsReadySourceWithoutReflectingItsToken() async throws {
    let (runtime, _) = await makeSignedInRuntime()
    RuntimeMockURLProtocol.setFixture(
      Self.playbackFile(needConvert: false, startFrom: 90),
      for: Self.playbackRoute
    )

    let resolution = try await runtime.resolveVideoPlaybackSource(
      fileID: PutioFileID(rawValue: 411)
    )

    guard case .ready(let source) = resolution else {
      return XCTFail("expected ready playback source")
    }
    XCTAssertEqual(source.startFromSeconds, 90)
    XCTAssertEqual(source.url.path, "/v2/files/411/hls/media.m3u8")
    XCTAssertEqual(
      URLComponents(url: source.url, resolvingAgainstBaseURL: false)?
        .queryItems?.first(where: { $0.name == "oauth_token" })?.value,
      "stored-token"
    )
    XCTAssertFalse(String(describing: source).contains("stored-token"))
    XCTAssertFalse(String(reflecting: source).contains("stored-token"))
  }

  func testPlaybackResolutionPreservesConversionRequired() async throws {
    let (runtime, _) = await makeSignedInRuntime()
    RuntimeMockURLProtocol.setFixture(
      Self.playbackFile(needConvert: true, startFrom: 0),
      for: Self.playbackRoute
    )

    let resolution = try await runtime.resolveVideoPlaybackSource(
      fileID: PutioFileID(rawValue: 411)
    )

    XCTAssertEqual(resolution, .conversionRequired)
  }

  func testVideoConversionStartSendsTheSDKOwnedRequest() async throws {
    let (runtime, _) = await makeSignedInRuntime()
    RuntimeMockURLProtocol.setFixture(#"{"status":"OK"}"#, for: Self.conversionStartRoute)

    try await runtime.startVideoConversion(fileID: PutioFileID(rawValue: 411))

    let request = try XCTUnwrap(RuntimeMockURLProtocol.capturedRequests().last)
    XCTAssertEqual(request.httpMethod, "POST")
    XCTAssertEqual(request.url?.path, "/v2/files/411/mp4")
  }

  func testAudioPlaybackSourceMapsStreamURLAndPositionThroughTheSDK() async throws {
    let (runtime, _) = await makeSignedInRuntime()
    RuntimeMockURLProtocol.setFixture(
      #"{"file":{"id":430,"file_type":"AUDIO","start_from":45}}"#, for: "GET /v2/files/430")

    let source = try await runtime.resolveAudioPlaybackSource(fileID: PutioFileID(rawValue: 430))

    XCTAssertEqual(source.url.path, "/v2/files/430/stream")
    XCTAssertEqual(source.startFromSeconds, 45)
    XCTAssertFalse(String(describing: source).contains("stored-token"))
  }

  func testAudioPlaybackSourceRejectsNonAudioAsUnknown() async {
    let (runtime, _) = await makeSignedInRuntime()
    RuntimeMockURLProtocol.setFixture(
      Self.playbackFile(needConvert: false, startFrom: 0), for: Self.playbackRoute)

    await assertRuntimeError(.unknown) {
      _ = try await runtime.resolveAudioPlaybackSource(fileID: PutioFileID(rawValue: 411))
    }
  }

  func testFileDownloadSourceCarriesTheTokenedURLAndRedactsIt() async throws {
    let (runtime, _) = await makeSignedInRuntime()
    RuntimeMockURLProtocol.setFixture(
      #"{"file":{"id":440,"parent_id":7,"name":"Poster.png","file_type":"IMAGE","size":10,"created_at":"2026-08-28T10:00:00Z","updated_at":"2026-08-29T10:00:00Z"}}"#,
      for: "GET /v2/files/440")

    let source = try await runtime.resolveFileDownloadSource(fileID: PutioFileID(rawValue: 440))

    XCTAssertEqual(source.id, PutioFileID(rawValue: 440))
    XCTAssertEqual(source.kind, .image)
    XCTAssertEqual(source.name, "Poster.png")
    XCTAssertEqual(source.url.path, "/v2/files/440/download")
    XCTAssertEqual(source.url.query?.contains("oauth_token=stored-token"), true)
    XCTAssertFalse(String(describing: source).contains("stored-token"))
    XCTAssertFalse(String(reflecting: source).contains("stored-token"))
  }

  func testFileDownloadSourceRejectsFoldersAndMismatchedIDs() async {
    let (runtime, _) = await makeSignedInRuntime()
    RuntimeMockURLProtocol.setFixture(
      #"{"file":{"id":441,"parent_id":0,"name":"Folder","file_type":"FOLDER","size":0,"created_at":"2026-08-28T10:00:00Z","updated_at":"2026-08-29T10:00:00Z"}}"#,
      for: "GET /v2/files/441")
    RuntimeMockURLProtocol.setFixture(
      #"{"file":{"id":9,"parent_id":0,"name":"Other.png","file_type":"IMAGE","size":1,"created_at":"2026-08-28T10:00:00Z","updated_at":"2026-08-29T10:00:00Z"}}"#,
      for: "GET /v2/files/442")

    await assertRuntimeError(.invalidResponse) {
      _ = try await runtime.resolveFileDownloadSource(fileID: PutioFileID(rawValue: 441))
    }
    await assertRuntimeError(.invalidResponse) {
      _ = try await runtime.resolveFileDownloadSource(fileID: PutioFileID(rawValue: 442))
    }
    await assertRuntimeError(.invalidResponse) {
      _ = try await runtime.resolveFileDownloadSource(fileID: .root)
    }
  }

  func testNextAudioUsesTheAudioFileTypeAndMapsTheSuccessor() async throws {
    let (runtime, _) = await makeSignedInRuntime()
    RuntimeMockURLProtocol.setFixture(
      #"{"next_file":{"id":431,"name":"Track 2.m4a","parent_id":7}}"#,
      for: "GET /v2/files/430/next-file")

    let next = try await runtime.findNextAudio(after: PutioFileID(rawValue: 430))

    XCTAssertEqual(
      next,
      PutioNextAudio(
        id: PutioFileID(rawValue: 431), parentID: PutioFileID(rawValue: 7), name: "Track 2.m4a"))
    let request = try XCTUnwrap(RuntimeMockURLProtocol.capturedRequests().last)
    XCTAssertEqual(request.url?.query?.contains("file_type=AUDIO"), true)
  }

  func testVideoConversionStatusMapsEveryKnownSDKState() async throws {
    let (runtime, _) = await makeSignedInRuntime()
    let cases: [(String, Int, PutioVideoConversionStatus)] = [
      ("IN_QUEUE", 0, .queued),
      ("CONVERTING", 35, .converting(progress: 0.35)),
      ("COMPLETED", 100, .completed),
      ("ERROR", 0, .failed),
      ("NOT_AVAILABLE", 0, .failed),
    ]

    for (status, percentDone, expected) in cases {
      RuntimeMockURLProtocol.setFixture(
        #"{"mp4":{"percent_done":\#(percentDone),"status":"\#(status)"}}"#,
        for: Self.conversionStatusRoute
      )

      let conversion = try await runtime.videoConversionStatus(
        fileID: PutioFileID(rawValue: 411)
      )
      if case .converting(let progress) = conversion,
        case .converting(let expectedProgress) = expected
      {
        XCTAssertEqual(progress, expectedProgress, accuracy: 0.001)
      } else {
        XCTAssertEqual(conversion, expected)
      }
    }
  }

  func testVideoConversionTreatsUnknownStatusAsStillConverting() async throws {
    let (runtime, _) = await makeSignedInRuntime()
    RuntimeMockURLProtocol.setFixture(
      #"{"mp4":{"percent_done":35,"status":"PAUSED"}}"#, for: Self.conversionStatusRoute)

    let conversion = try await runtime.videoConversionStatus(fileID: PutioFileID(rawValue: 411))

    guard case .converting(let progress) = conversion else {
      return XCTFail("expected an in-progress state, got \(conversion)")
    }
    XCTAssertEqual(progress, 0.35, accuracy: 0.001)
  }

  func testVideoConversionTerminalRowsIgnoreProgress() async throws {
    let (runtime, _) = await makeSignedInRuntime()
    for (status, expected) in [
      ("ERROR", PutioVideoConversionStatus.failed), ("NOT_AVAILABLE", .failed),
      ("COMPLETED", .completed), ("IN_QUEUE", .queued),
    ] {
      RuntimeMockURLProtocol.setFixture(
        #"{"mp4":{"percent_done":-1,"status":"\#(status)"}}"#, for: Self.conversionStatusRoute)
      let conversion = try await runtime.videoConversionStatus(
        fileID: PutioFileID(rawValue: 411))
      XCTAssertEqual(conversion, expected)
    }
  }

  func testVideoConversionRejectsInvalidProgressWhileConverting() async {
    let (runtime, _) = await makeSignedInRuntime()
    for body in [
      #"{"mp4":{"percent_done":101,"status":"CONVERTING"}}"#,
      #"{"mp4":{"percent_done":-1,"status":"CONVERTING"}}"#,
    ] {
      RuntimeMockURLProtocol.setFixture(body, for: Self.conversionStatusRoute)
      await assertRuntimeError(.invalidResponse) {
        _ = try await runtime.videoConversionStatus(fileID: PutioFileID(rawValue: 411))
      }
    }
  }

  func testUnauthenticatedRuntimeRejectsVideoConversionWithoutARequest() async {
    let (runtime, _) = makeRuntime(token: nil)

    await assertRuntimeError(.authenticationRequired) {
      try await runtime.startVideoConversion(fileID: PutioFileID(rawValue: 411))
    }
    await assertRuntimeError(.authenticationRequired) {
      _ = try await runtime.videoConversionStatus(fileID: PutioFileID(rawValue: 411))
    }

    XCTAssertTrue(RuntimeMockURLProtocol.capturedRequests().isEmpty)
  }

  func testMediaAgnosticPlaybackPositionReportSharesTheStartFromRoute() async throws {
    let (runtime, _) = await makeSignedInRuntime()
    RuntimeMockURLProtocol.setFixture(#"{"status":"OK"}"#, for: Self.playbackPositionRoute)

    try await runtime.reportPlaybackPosition(fileID: PutioFileID(rawValue: 411), seconds: 42)

    let request = try XCTUnwrap(RuntimeMockURLProtocol.capturedRequests().last)
    XCTAssertEqual(request.url?.path, "/v2/files/411/start-from/set")
  }

  func testPlaybackPositionReportSendsExactPathAndBody() async throws {
    let (runtime, _) = await makeSignedInRuntime()
    RuntimeMockURLProtocol.setFixture(#"{"status":"OK"}"#, for: Self.playbackPositionRoute)

    try await runtime.reportVideoPlaybackPosition(
      fileID: PutioFileID(rawValue: 411),
      seconds: 91
    )

    let request = try XCTUnwrap(RuntimeMockURLProtocol.capturedRequests().last)
    XCTAssertEqual(request.httpMethod, "POST")
    XCTAssertEqual(request.url?.path, "/v2/files/411/start-from/set")
    let body = try XCTUnwrap(requestBodyData(for: request))
    let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Int])
    XCTAssertEqual(json, ["time": 91])
  }

  func testUnauthenticatedRuntimeRejectsPlaybackPositionReportWithoutARequest() async {
    let (runtime, _) = makeRuntime(token: nil)

    await assertRuntimeError(.authenticationRequired) {
      try await runtime.reportVideoPlaybackPosition(
        fileID: PutioFileID(rawValue: 411),
        seconds: 91
      )
    }

    XCTAssertTrue(RuntimeMockURLProtocol.capturedRequests().isEmpty)
  }

  func testPlaybackPositionAuthenticationFailureExpiresSessionAndClearsToken() async {
    let (runtime, tokenStore) = await makeSignedInRuntime()
    RuntimeMockURLProtocol.setFixture(
      #"{"status":"ERROR","error_type":"invalid_grant"}"#,
      statusCode: 401,
      for: Self.playbackPositionRoute
    )

    await assertRuntimeError(.sessionExpired) {
      try await runtime.reportVideoPlaybackPosition(
        fileID: PutioFileID(rawValue: 411),
        seconds: 91
      )
    }

    XCTAssertEqual(runtime.session.state, .signedOut(.sessionExpired))
    XCTAssertNil(try? tokenStore.read())
  }

  func testPlaybackPositionCancellationPreservesSignedInSessionAndToken() async {
    let (runtime, tokenStore) = await makeSignedInRuntime()
    RuntimeMockURLProtocol.suspend(Self.playbackPositionRoute)

    let task = Task {
      try await runtime.reportVideoPlaybackPosition(
        fileID: PutioFileID(rawValue: 411),
        seconds: 91
      )
    }
    guard await waitForRequest(Self.playbackPositionRoute) else {
      task.cancel()
      return XCTFail("playback-position request did not start")
    }
    task.cancel()

    do {
      try await task.value
      XCTFail("expected cancellation")
    } catch is CancellationError {
    } catch {
      XCTFail("expected CancellationError, got \(error)")
    }

    guard case .signedIn = runtime.session.state else {
      return XCTFail("cancellation must preserve the signed-in session")
    }
    XCTAssertEqual(try? tokenStore.read(), "stored-token")
  }

  func testPlaybackAuthenticationFailureExpiresSessionAndClearsToken() async {
    let (runtime, tokenStore) = await makeSignedInRuntime()
    RuntimeMockURLProtocol.setFixture(
      #"{"status":"ERROR","error_type":"invalid_grant"}"#,
      statusCode: 401,
      for: Self.playbackRoute
    )

    await assertRuntimeError(.sessionExpired) {
      _ = try await runtime.resolveVideoPlaybackSource(fileID: PutioFileID(rawValue: 411))
    }

    XCTAssertEqual(runtime.session.state, .signedOut(.sessionExpired))
    XCTAssertNil(try? tokenStore.read())
  }

  func testUnauthorizedAndForbiddenResponsesExpireTheSharedSession() async {
    for statusCode in [401, 403] {
      RuntimeMockURLProtocol.reset()
      let (runtime, tokenStore) = await makeSignedInRuntime()
      RuntimeMockURLProtocol.setFixture(
        #"{"status":"ERROR","error_type":"invalid_grant"}"#,
        statusCode: statusCode,
        for: Self.filesRoute
      )

      await assertRuntimeError(.sessionExpired) {
        _ = try await runtime.listFiles()
      }

      XCTAssertEqual(
        runtime.session.state,
        .signedOut(.sessionExpired),
        "HTTP \(statusCode) must expire the session"
      )
      XCTAssertNil(try? tokenStore.read(), "HTTP \(statusCode) must clear persisted auth")

      let requestCount = RuntimeMockURLProtocol.capturedRequests().count
      await assertRuntimeError(.sessionExpired) {
        _ = try await runtime.listFiles()
      }
      XCTAssertEqual(
        RuntimeMockURLProtocol.capturedRequests().count,
        requestCount,
        "an expired session must reject follow-up work without another request"
      )
    }
  }

  func testRuntimeClassifiesExpectedSDKFailures() async {
    let (runtime, _) = await makeSignedInRuntime()

    for (statusCode, expected) in [
      (404, PutioRuntimeError.notFound),
      (429, PutioRuntimeError.rateLimited),
      (500, PutioRuntimeError.transient),
    ] {
      RuntimeMockURLProtocol.setFixture(
        #"{"status":"ERROR"}"#,
        statusCode: statusCode,
        for: Self.filesRoute
      )
      await assertRuntimeError(expected) {
        _ = try await runtime.listFiles()
      }
    }

    RuntimeMockURLProtocol.setNetworkFailure(true, for: Self.filesRoute)
    await assertRuntimeError(.transient) {
      _ = try await runtime.listFiles()
    }
    RuntimeMockURLProtocol.setNetworkFailure(false, for: Self.filesRoute)

    RuntimeMockURLProtocol.setFixture("{", for: Self.filesRoute)
    await assertRuntimeError(.invalidResponse) {
      _ = try await runtime.listFiles()
    }

    RuntimeMockURLProtocol.setNonHTTPResponse(true, for: Self.filesRoute)
    await assertRuntimeError(.unknown) {
      _ = try await runtime.listFiles()
    }
  }

  func testCancellationPreservesTheSignedInSessionAndToken() async {
    let (runtime, tokenStore) = await makeSignedInRuntime()
    RuntimeMockURLProtocol.suspend(Self.filesRoute)

    let task = Task { try await runtime.listFiles() }
    guard await waitForRequest(Self.filesRoute) else {
      task.cancel()
      return XCTFail("files request did not start")
    }
    task.cancel()

    do {
      _ = try await task.value
      XCTFail("expected cancellation")
    } catch is CancellationError {
    } catch {
      XCTFail("expected CancellationError, got \(error)")
    }

    guard case .signedIn = runtime.session.state else {
      return XCTFail("cancellation must preserve the signed-in session")
    }
    XCTAssertEqual(try? tokenStore.read(), "stored-token")
  }

  func testResponseCompletingDuringSignOutIsDiscarded() async {
    let (runtime, tokenStore) = await makeSignedInRuntime()
    RuntimeMockURLProtocol.gateFixture(Self.filesList(cursor: nil), for: Self.filesRoute)

    let listTask = Task { try await runtime.listFiles() }
    guard await waitForRequest(Self.filesRoute) else {
      listTask.cancel()
      return XCTFail("files request did not start")
    }

    let signOutTask = Task { await runtime.session.signOut() }
    let localSessionInvalidated = await waitForSessionState(
      runtime,
      expected: .signingOut
    )
    XCTAssertNil(try? tokenStore.read())
    RuntimeMockURLProtocol.releaseFixture(for: Self.filesRoute)
    await signOutTask.value

    XCTAssertTrue(
      localSessionInvalidated,
      "sign-out must invalidate local work before its remote request completes"
    )
    await assertRuntimeError(.authenticationRequired) {
      _ = try await listTask.value
    }
    XCTAssertEqual(runtime.session.state, .signedOut(.userSignedOut))
    XCTAssertNil(try? tokenStore.read())
  }

  func testSignInIsUnavailableUntilRemoteLogoutFinishes() async throws {
    let (runtime, _) = await makeSignedInRuntime()
    RuntimeMockURLProtocol.gateFixture(#"{"status":"OK"}"#, for: Self.logoutRoute)

    let signOutTask = Task { await runtime.session.signOut() }
    guard await waitForRequest(Self.logoutRoute) else {
      RuntimeMockURLProtocol.releaseFixture(for: Self.logoutRoute)
      await signOutTask.value
      return XCTFail("logout request did not start")
    }

    XCTAssertEqual(runtime.session.state, .signingOut)
    XCTAssertThrowsError(try runtime.session.beginSignIn()) { error in
      XCTAssertEqual(error as? PutioSessionOperationError, .signInUnavailable)
    }

    RuntimeMockURLProtocol.releaseFixture(for: Self.logoutRoute)
    await signOutTask.value
    XCTAssertEqual(runtime.session.state, .signedOut(.userSignedOut))

    _ = try runtime.session.beginSignIn()
    XCTAssertEqual(runtime.session.state, .authenticating)
  }

  func testStrayCallbackDuringSignOutDoesNotBlockCredentialCleanup() async throws {
    let (runtime, tokenStore) = await makeSignedInRuntime()
    RuntimeMockURLProtocol.gateFixture(#"{"status":"OK"}"#, for: Self.logoutRoute)

    let signOutTask = Task { await runtime.session.signOut() }
    guard await waitForRequest(Self.logoutRoute) else {
      RuntimeMockURLProtocol.releaseFixture(for: Self.logoutRoute)
      await signOutTask.value
      return XCTFail("logout request did not start")
    }

    let callback = try XCTUnwrap(
      URL(string: "putio://auth#access_token=stray-token&state=stray-state")
    )
    await runtime.session.completeSignIn(callbackURL: callback)
    XCTAssertEqual(runtime.session.state, .signingOut)

    RuntimeMockURLProtocol.releaseFixture(for: Self.logoutRoute)
    await signOutTask.value
    XCTAssertEqual(runtime.session.state, .signedOut(.userSignedOut))
    XCTAssertNil(try? tokenStore.read())
  }

  func testOldSessionResponsesCannotEscapeIntoAFreshSession() async throws {
    for (statusCode, body) in [
      (200, Self.filesList(cursor: nil)),
      (401, #"{"status":"ERROR","error_type":"invalid_grant"}"#),
    ] {
      RuntimeMockURLProtocol.reset()
      let (runtime, tokenStore) = await makeSignedInRuntime()
      RuntimeMockURLProtocol.gateFixture(
        body,
        statusCode: statusCode,
        for: Self.filesRoute
      )

      let oldListTask = Task { try await runtime.listFiles() }
      guard await waitForRequest(Self.filesRoute) else {
        oldListTask.cancel()
        return XCTFail("old-session files request did not start")
      }

      await runtime.session.signOut()
      let signInRequest = try runtime.session.beginSignIn()
      let oauthState = try XCTUnwrap(oauthState(from: signInRequest.url))
      let callback = try XCTUnwrap(
        URL(string: "putio://auth#access_token=fresh-token&state=\(oauthState)")
      )
      await runtime.session.completeSignIn(callbackURL: callback)
      guard case .signedIn = runtime.session.state else {
        RuntimeMockURLProtocol.releaseFixture(for: Self.filesRoute)
        return XCTFail("fresh session did not sign in")
      }

      RuntimeMockURLProtocol.releaseFixture(for: Self.filesRoute)
      await assertRuntimeError(.authenticationRequired) {
        _ = try await oldListTask.value
      }
      guard case .signedIn = runtime.session.state else {
        return XCTFail("old HTTP \(statusCode) response mutated the fresh session")
      }
      XCTAssertEqual(try? tokenStore.read(), "fresh-token")
    }
  }

  func testRuntimeValuesAreSendable() {
    requireSendable(PutioAccountSnapshot.self)
    requireSendable(PutioFileID.self)
    requireSendable(PutioFileKind.self)
    requireSendable(PutioFileItem.self)
    requireSendable(PutioFolderContents.self)
    requireSendable(PutioTrashItem.self)
    requireSendable(PutioTrashPage.self)
    requireSendable(PutioTrashRestoreResult.self)
    requireSendable(PutioNextVideo.self)
    requireSendable(PutioPlaybackSource.self)
    requireSendable(PutioPlaybackResolution.self)
    requireSendable(PutioVideoConversionStatus.self)
    requireSendable(PutioRuntimeError.self)
    requireSendable(PutioSessionState.self)
  }

  func testCastPlaybackTypeRoundTripsThroughTheConfigEndpoints() async throws {
    let (runtime, _) = await makeSignedInRuntime()
    RuntimeMockURLProtocol.setFixture(
      #"{"config":{"chromecast_playback_type":"mp4"}}"#, for: "GET /v2/config")
    let type = try await runtime.castPlaybackType()
    XCTAssertEqual(type, .mp4)
    RuntimeMockURLProtocol.setFixture(#"{"config":{}}"#, for: "GET /v2/config")
    let fallback = try await runtime.castPlaybackType()
    XCTAssertEqual(fallback, .hls)

    let route = "PUT /v2/config/chromecast_playback_type"
    RuntimeMockURLProtocol.setFixture(#"{"status":"OK"}"#, for: route)
    try await runtime.setCastPlaybackType(.mp4)
    let request = try XCTUnwrap(
      RuntimeMockURLProtocol.capturedRequests().last {
        $0.url?.path == "/v2/config/chromecast_playback_type"
      })
    let body = try XCTUnwrap(requestBodyData(for: request))
    XCTAssertEqual(
      try JSONSerialization.jsonObject(with: body) as? [String: String], ["value": "mp4"])
    RuntimeMockURLProtocol.setFixture(#"{"status":"ERROR"}"#, for: route)
    await assertRuntimeError(.invalidResponse) { try await runtime.setCastPlaybackType(.hls) }
  }

  func testCastMediaUsesHLSWithMuxedSubtitlesAndRedactsTheToken() async throws {
    let (runtime, _) = await makeSignedInRuntime()
    RuntimeMockURLProtocol.setFixture(
      """
      {"file":{"id":412,"name":"Movie.mkv","file_type":"VIDEO","parent_id":0,
       "created_at":"2026-09-01T12:00:00","updated_at":"2026-09-01T12:00:00",
       "need_convert":false,"start_from":589,"screenshot":"https://img.put.io/412.jpg",
       "video_metadata":{"duration":5400.5,"codec":"h264","width":1920,"height":1080}}}
      """, for: "GET /v2/files/412")
    guard
      case .ready(let media) = try await runtime.resolveCastMedia(
        fileID: PutioFileID(rawValue: 412), playbackType: .hls)
    else { return XCTFail("expected ready media") }
    XCTAssertEqual(media.playbackType, .hls)
    XCTAssertEqual(media.title, "Movie.mkv")
    XCTAssertEqual(media.startFromSeconds, 589)
    XCTAssertEqual(media.durationSeconds, 5400.5)
    XCTAssertEqual(media.artworkURL, URL(string: "https://img.put.io/412.jpg"))
    XCTAssertTrue(media.subtitles.isEmpty)
    let components = try XCTUnwrap(URLComponents(url: media.url, resolvingAgainstBaseURL: false))
    XCTAssertEqual(components.path, "/v2/files/412/hls/media.m3u8")
    XCTAssertEqual(components.queryItems?.first { $0.name == "subtitle_key" }?.value, "all")
    XCTAssertEqual(components.queryItems?.first { $0.name == "oauth_token" }?.value, "stored-token")
    XCTAssertFalse(String(reflecting: media).contains("stored-token"))
    XCTAssertFalse(String(describing: media).contains("stored-token"))
    XCTAssertFalse(
      RuntimeMockURLProtocol.capturedRequests().contains {
        $0.url?.path.hasSuffix("/subtitles") == true
      })
  }

  func testCastMediaUsesMP4WithWebVTTTracksAndGatesOnConversion() async throws {
    let (runtime, _) = await makeSignedInRuntime()
    let file = { (needConvert: Bool, hasMP4: Bool) in
      """
      {"file":{"id":412,"name":"Movie.mkv","file_type":"VIDEO","parent_id":7,
       "created_at":"2026-09-01T12:00:00","updated_at":"2026-09-01T12:00:00",
       "need_convert":\(needConvert),"is_mp4_available":\(hasMP4),"start_from":10,
       "screenshot":"http://insecure.example/412.jpg"}}
      """
    }
    RuntimeMockURLProtocol.setFixture(
      """
      {"default":"tr","subtitles":[
        {"key":"en","language":"English","language_code":"eng","name":"English.srt","source":"opensubtitles","url":"https://api.put.io/v2/files/412/subtitles/en?oauth_token=stored-token"},
        {"key":"tr","language":"Turkish","language_code":"tur","name":"Turkish.srt","source":"opensubtitles","url":"https://api.put.io/v2/files/412/subtitles/tr?oauth_token=stored-token"},
        {"key":"tr","language":"Turkish","language_code":"tur","name":"Dup.srt","source":"x","url":"https://api.put.io/v2/files/412/subtitles/tr"},
        {"key":"","language":"","language_code":"","name":"","source":"","url":""}
      ]}
      """, for: "GET /v2/files/412/subtitles")

    RuntimeMockURLProtocol.setFixture(file(true, true), for: "GET /v2/files/412")
    guard
      case .ready(let converted) = try await runtime.resolveCastMedia(
        fileID: PutioFileID(rawValue: 412), playbackType: .mp4)
    else { return XCTFail("expected ready media") }
    XCTAssertEqual(converted.playbackType, .mp4)
    XCTAssertEqual(converted.parentID, PutioFileID(rawValue: 7))
    XCTAssertNil(converted.artworkURL, "insecure artwork is dropped")
    XCTAssertEqual(converted.url.path, "/v2/files/412/mp4/download")
    XCTAssertEqual(converted.subtitles.map(\.key), ["en", "tr"])
    XCTAssertEqual(converted.defaultSubtitleKey, "tr")
    let subtitle = try XCTUnwrap(
      URLComponents(url: converted.subtitles[0].url, resolvingAgainstBaseURL: false))
    XCTAssertEqual(subtitle.queryItems?.map(\.name), ["oauth_token", "format"])
    XCTAssertEqual(subtitle.queryItems?.last?.value, "webvtt")
    XCTAssertFalse(String(reflecting: converted).contains("stored-token"))

    RuntimeMockURLProtocol.setFixture(file(false, false), for: "GET /v2/files/412")
    guard
      case .ready(let original) = try await runtime.resolveCastMedia(
        fileID: PutioFileID(rawValue: 412), playbackType: .mp4)
    else { return XCTFail("expected ready media") }
    XCTAssertEqual(original.url.path, "/v2/files/412/download")

    RuntimeMockURLProtocol.setFixture(file(true, false), for: "GET /v2/files/412")
    let gated = try await runtime.resolveCastMedia(
      fileID: PutioFileID(rawValue: 412), playbackType: .mp4)
    XCTAssertEqual(gated, .conversionRequired)
    let hlsGated = try await runtime.resolveCastMedia(
      fileID: PutioFileID(rawValue: 412), playbackType: .hls)
    XCTAssertEqual(hlsGated, .conversionRequired)

    RuntimeMockURLProtocol.setFixture(
      #"{"file":{"id":413,"name":"Other","file_type":"VIDEO","parent_id":0,"created_at":"2026-09-01T12:00:00","updated_at":"2026-09-01T12:00:00"}}"#,
      for: "GET /v2/files/412")
    await assertRuntimeError(.invalidResponse) {
      _ = try await runtime.resolveCastMedia(fileID: PutioFileID(rawValue: 412), playbackType: .hls)
    }
    await assertRuntimeError(.invalidResponse) {
      _ = try await runtime.resolveCastMedia(fileID: .root, playbackType: .hls)
    }
  }

  private func makeRuntime(
    token: String?
  ) -> (PutioRuntime, PutioInMemoryTokenStore) {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [RuntimeMockURLProtocol.self]
    let tokenStore = PutioInMemoryTokenStore(token: token)
    let runtime = PutioRuntime(
      clientID: "3001",
      clientName: "tests",
      tokenStore: tokenStore,
      urlSession: URLSession(configuration: configuration)
    )
    return (runtime, tokenStore)
  }

  private func makeSignedInRuntime() async -> (PutioRuntime, PutioInMemoryTokenStore) {
    stubSignedInRoutes()
    let (runtime, tokenStore) = makeRuntime(token: "stored-token")
    await runtime.session.restore()
    guard case .signedIn = runtime.session.state else {
      XCTFail("fixture restore must sign in")
      return (runtime, tokenStore)
    }
    return (runtime, tokenStore)
  }

  private func stubSignedInRoutes() {
    RuntimeMockURLProtocol.setFixture(
      Self.validValidation,
      for: "GET /v2/oauth2/validate"
    )
    RuntimeMockURLProtocol.setFixture(
      Self.accountInfo,
      for: "GET /v2/account/info"
    )
    RuntimeMockURLProtocol.setFixture(
      #"{"status":"OK"}"#,
      for: Self.logoutRoute
    )
  }

  private func assertRuntimeError(
    _ expected: PutioRuntimeError,
    file: StaticString = #filePath,
    line: UInt = #line,
    operation: () async throws -> Void
  ) async {
    do {
      try await operation()
      XCTFail("expected \(expected)", file: file, line: line)
    } catch let error as PutioRuntimeError {
      XCTAssertEqual(error, expected, file: file, line: line)
    } catch {
      XCTFail("expected \(expected), got \(error)", file: file, line: line)
    }
  }

  private func requireSendable<Value: Sendable>(_: Value.Type) {}

  private func requestBodyData(for request: URLRequest) -> Data? {
    if let body = request.httpBody {
      return body
    }

    guard let stream = request.httpBodyStream else {
      return nil
    }

    stream.open()
    defer { stream.close() }

    let bufferSize = 1_024
    let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
    defer { buffer.deallocate() }

    var data = Data()
    while stream.hasBytesAvailable {
      let read = stream.read(buffer, maxLength: bufferSize)
      guard read >= 0 else { return nil }
      guard read > 0 else { break }
      data.append(buffer, count: read)
    }
    return data
  }

  private func waitForRequest(_ route: String, count: Int = 1) async -> Bool {
    for _ in 0..<1_000 {
      if RuntimeMockURLProtocol.capturedRequests().filter({ request in
        guard let url = request.url else { return false }
        return "\(request.httpMethod ?? "GET") \(url.path)" == route
      }).count >= count {
        return true
      }
      await Task.yield()
    }
    return false
  }

  private func waitForSessionState(
    _ runtime: PutioRuntime,
    expected: PutioSessionState
  ) async -> Bool {
    for _ in 0..<1_000 {
      if runtime.session.state == expected {
        return true
      }
      await Task.yield()
    }
    return false
  }

  private func oauthState(from url: URL) -> String? {
    URLComponents(url: url, resolvingAgainstBaseURL: false)?
      .queryItems?
      .first(where: { $0.name == "state" })?
      .value
  }

  private static func filesList(cursor: String?, sortBy: String? = nil) -> String {
    let cursorField = cursor.map { "\"cursor\": \"\($0)\"," } ?? ""
    let sortField = sortBy.map { "\"sort_by\": \"\($0)\"," } ?? ""
    return """
      {
        \(cursorField)
        "parent": {
          \(sortField)
          "id": 0,
          "name": "Your Files",
          "file_type": "FOLDER",
          "parent_id": 0,
          "size": 0,
          "created_at": "2026-08-01T10:00:00Z",
          "updated_at": "2026-08-01T10:00:00Z"
        },
        "files": [
          {
            "id": 11,
            "name": "Episode 1.mkv",
            "file_type": "VIDEO",
            "parent_id": 0,
            "size": 1024,
            "created_at": "2026-08-28T10:00:00Z",
            "updated_at": "2026-08-29T10:00:00Z",
            "start_from": 42.5,
            "stream_url": "https://api.put.io/video?oauth_token=stream-secret",
            "mp4_stream_url": "https://api.put.io/video?oauth_token=mp4-secret"
          },
          {
            "id": 12,
            "name": "Track.flac",
            "file_type": "AUDIO",
            "parent_id": 0,
            "size": 2048,
            "created_at": "2026-08-28T10:00:00Z",
            "updated_at": "2026-08-29T10:00:00Z"
          },
          {
            "id": 13,
            "name": "Cover.png",
            "file_type": "IMAGE",
            "parent_id": 0,
            "size": 512,
            "created_at": "2026-08-28T10:00:00Z",
            "updated_at": "2026-08-29T10:00:00Z"
          },
          {
            "id": 14,
            "name": "Notes.pdf",
            "file_type": "PDF",
            "parent_id": 0,
            "size": 256,
            "created_at": "2026-08-28T10:00:00Z",
            "updated_at": "2026-08-29T10:00:00Z"
          },
          {
            "id": 15,
            "name": "Season 2",
            "file_type": "FOLDER",
            "parent_id": 0,
            "size": 0,
            "created_at": "2026-08-28T10:00:00Z",
            "updated_at": "2026-08-29T10:00:00Z"
          },
          {
            "id": 16,
            "name": "Backup.tar",
            "file_type": "ARCHIVE",
            "parent_id": 0,
            "size": 4096,
            "created_at": "2026-08-28T10:00:00Z",
            "updated_at": "2026-08-29T10:00:00Z"
          }
        ],
        "total": 6
      }
      """
  }

  private static func playbackFile(needConvert: Bool, startFrom: Int) -> String {
    return """
      {
        "file": {
          "id": 411,
          "file_type": "VIDEO",
          "need_convert": \(needConvert),
          "start_from": \(startFrom)
        }
      }
      """
  }
}
