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
      if state.gatedRoutes.contains(route) {
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

  func testListMapsAppOwnedValuesAndPreservesOnlyHasMore() async throws {
    let (runtime, _) = await makeSignedInRuntime()
    RuntimeMockURLProtocol.setFixture(Self.filesList(cursor: "next-page"), for: Self.filesRoute)

    let contents = try await runtime.listFiles(parentID: .root)

    XCTAssertEqual(contents.folder?.id, .root)
    XCTAssertEqual(contents.folder?.name, "Your Files")
    XCTAssertEqual(contents.folder?.kind, .folder)
    XCTAssertTrue(contents.hasMore)
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
    XCTAssertFalse(nilCursorContents.hasMore)

    RuntimeMockURLProtocol.setFixture(Self.filesList(cursor: ""), for: Self.filesRoute)
    let emptyCursorContents = try await runtime.listFiles()
    XCTAssertFalse(emptyCursorContents.hasMore)
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
    try await runtime.permanentlyDeleteTrashItem(fileID: fileID)
    try await runtime.emptyTrash()

    XCTAssertEqual(restoredItem.parentID, PutioFileID(rawValue: 7))
    let requests = RuntimeMockURLProtocol.capturedRequests().suffix(4)
    XCTAssertEqual(
      requests.compactMap { $0.url?.path },
      ["/v2/trash/restore", "/v2/files/91", "/v2/trash/delete", "/v2/trash/empty"]
    )
    XCTAssertEqual(requests.map(\.httpMethod), ["POST", "GET", "POST", "POST"])
    for request in [
      requests[requests.startIndex], requests[requests.index(requests.startIndex, offsetBy: 2)],
    ] {
      let body = try XCTUnwrap(requestBodyData(for: request))
      let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
      XCTAssertEqual(json["file_ids"] as? String, "91")
      XCTAssertNil(json["cursor"])
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
      try await runtime.permanentlyDeleteTrashItem(fileID: PutioFileID(rawValue: 91))
    }
    await assertRuntimeError(.invalidResponse) {
      try await runtime.emptyTrash()
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

  func testVideoConversionRejectsUnknownStatusAndInvalidProgress() async {
    let (runtime, _) = await makeSignedInRuntime()
    for body in [
      #"{"mp4":{"percent_done":35,"status":"PAUSED"}}"#,
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
    requireSendable(PutioNextVideo.self)
    requireSendable(PutioPlaybackSource.self)
    requireSendable(PutioPlaybackResolution.self)
    requireSendable(PutioVideoConversionStatus.self)
    requireSendable(PutioRuntimeError.self)
    requireSendable(PutioSessionState.self)
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

  private func waitForRequest(_ route: String) async -> Bool {
    for _ in 0..<1_000 {
      if RuntimeMockURLProtocol.capturedRequests().contains(where: { request in
        guard let url = request.url else { return false }
        return "\(request.httpMethod ?? "GET") \(url.path)" == route
      }) {
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

  private static func filesList(cursor: String?) -> String {
    let cursorField = cursor.map { "\"cursor\": \"\($0)\"," } ?? ""
    return """
      {
        \(cursorField)
        "parent": {
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
