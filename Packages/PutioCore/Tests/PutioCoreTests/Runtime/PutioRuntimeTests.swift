import Foundation
import XCTest

@testable import PutioCore

@MainActor
final class PutioRuntimeTests: XCTestCase {
  static let filesRoute = "GET /v2/files/list"
  private static let logoutRoute = "POST /v2/oauth/grants/logout"
  private static let validValidation =
    #"{"result": true, "token_id": 1, "token_scope": "default", "user_id": 1001}"#
  static let accountInfo = """
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

  let fixtures = RuntimeMockURLProtocol.Fixtures()

  func testConcurrentRuntimesKeepResponsesAndCapturedRequestsIsolated() async throws {
    stubSignedInRoutes()
    let otherFixtures = RuntimeMockURLProtocol.Fixtures()
    otherFixtures.setFixture(Self.validValidation, for: "GET /v2/oauth2/validate")
    otherFixtures.setFixture(
      Self.accountInfo.replacingOccurrences(of: "moviebuff", with: "another-user"),
      for: "GET /v2/account/info")
    let (first, _) = makeRuntime(token: "first-token")
    let (second, _) = makeRuntime(token: "second-token", fixtures: otherFixtures)

    async let firstRestore: Void = first.session.restore()
    async let secondRestore: Void = second.session.restore()
    _ = await (firstRestore, secondRestore)

    guard case .signedIn(let firstAccount) = first.session.state,
      case .signedIn(let secondAccount) = second.session.state
    else { return XCTFail("both independent runtimes must restore") }
    XCTAssertEqual(firstAccount.username, "moviebuff")
    XCTAssertEqual(secondAccount.username, "another-user")
    XCTAssertEqual(fixtures.capturedRequests().count, 2)
    XCTAssertEqual(otherFixtures.capturedRequests().count, 2)
    XCTAssertTrue(
      fixtures.capturedRequests().allSatisfy {
        $0.value(forHTTPHeaderField: "Authorization")?.lowercased() == "token first-token"
      })
    XCTAssertTrue(
      otherFixtures.capturedRequests().allSatisfy {
        $0.value(forHTTPHeaderField: "Authorization")?.lowercased() == "token second-token"
      })
  }

  func testRestoredTokenIsSharedByValidationAccountAndFilesRequests() async throws {
    stubSignedInRoutes()
    fixtures.setFixture(Self.filesList(cursor: nil), for: Self.filesRoute)
    let (runtime, _) = makeRuntime(token: "stored-token")

    await runtime.session.restore()
    _ = try await runtime.listFiles()

    let requests = fixtures.capturedRequests()
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

  func testUnauthorizedAndForbiddenResponsesExpireTheSharedSession() async {
    for statusCode in [401, 403] {
      fixtures.reset()
      let (runtime, tokenStore) = await makeSignedInRuntime()
      fixtures.setFixture(
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

      let requestCount = fixtures.capturedRequests().count
      await assertRuntimeError(.sessionExpired) {
        _ = try await runtime.listFiles()
      }
      XCTAssertEqual(
        fixtures.capturedRequests().count,
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
      fixtures.setFixture(
        #"{"status":"ERROR"}"#,
        statusCode: statusCode,
        for: Self.filesRoute
      )
      await assertRuntimeError(expected) {
        _ = try await runtime.listFiles()
      }
    }

    fixtures.setNetworkFailure(true, for: Self.filesRoute)
    await assertRuntimeError(.transient) {
      _ = try await runtime.listFiles()
    }
    fixtures.setNetworkFailure(false, for: Self.filesRoute)

    fixtures.setFixture("{", for: Self.filesRoute)
    await assertRuntimeError(.invalidResponse) {
      _ = try await runtime.listFiles()
    }

    fixtures.setNonHTTPResponse(true, for: Self.filesRoute)
    await assertRuntimeError(.unknown) {
      _ = try await runtime.listFiles()
    }
  }

  func testCancellationPreservesTheSignedInSessionAndToken() async {
    let (runtime, tokenStore) = await makeSignedInRuntime()
    fixtures.suspend(Self.filesRoute)

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

  func testAuthenticationFailureSeenByACancelledTaskStillExpiresTheSession() async {
    let (runtime, tokenStore) = await makeSignedInRuntime()
    fixtures.gateFixture(
      #"{"status":"ERROR","error_type":"invalid_grant"}"#, statusCode: 401, for: Self.filesRoute)

    let task = Task { try await runtime.listFiles() }
    guard await waitForRequest(Self.filesRoute) else {
      task.cancel()
      fixtures.releaseFixture(for: Self.filesRoute)
      return XCTFail("files request did not start")
    }
    // Holding the main actor lets the 401 finish loading before the
    // cancellation, so the runtime sees both at once.
    fixtures.releaseFixture(for: Self.filesRoute)
    blockCurrentThread(seconds: 0.3)
    task.cancel()

    do {
      _ = try await task.value
      XCTFail("expected sessionExpired")
    } catch {
      XCTAssertEqual(error as? PutioRuntimeError, .sessionExpired)
    }
    XCTAssertEqual(runtime.session.state, .signedOut(.sessionExpired))
    XCTAssertNil(try? tokenStore.read())
  }

  func testResponseCompletingDuringSignOutIsDiscarded() async {
    let (runtime, tokenStore) = await makeSignedInRuntime()
    fixtures.gateFixture(Self.filesList(cursor: nil), for: Self.filesRoute)
    fixtures.gateFixture(#"{"status":"OK"}"#, for: Self.logoutRoute)
    defer {
      fixtures.releaseFixture(for: Self.filesRoute)
      fixtures.releaseFixture(for: Self.logoutRoute)
    }

    let listTask = Task { try await runtime.listFiles() }
    guard await waitForRequest(Self.filesRoute) else {
      listTask.cancel()
      return XCTFail("files request did not start")
    }

    let signOutTask = Task { await runtime.session.signOut() }
    guard await waitForRequest(Self.logoutRoute) else {
      listTask.cancel()
      signOutTask.cancel()
      return XCTFail("logout request did not start")
    }
    XCTAssertEqual(runtime.session.state, .signingOut)
    XCTAssertNil(try? tokenStore.read())
    fixtures.releaseFixture(for: Self.filesRoute)
    await assertRuntimeError(.authenticationRequired) {
      _ = try await listTask.value
    }
    XCTAssertEqual(runtime.session.state, .signingOut)

    fixtures.releaseFixture(for: Self.logoutRoute)
    await signOutTask.value
    XCTAssertEqual(runtime.session.state, .signedOut(.userSignedOut))
    XCTAssertNil(try? tokenStore.read())
  }

  func testSignInIsUnavailableUntilRemoteLogoutFinishes() async throws {
    let (runtime, _) = await makeSignedInRuntime()
    fixtures.gateFixture(#"{"status":"OK"}"#, for: Self.logoutRoute)

    let signOutTask = Task { await runtime.session.signOut() }
    guard await waitForRequest(Self.logoutRoute) else {
      fixtures.releaseFixture(for: Self.logoutRoute)
      await signOutTask.value
      return XCTFail("logout request did not start")
    }

    XCTAssertEqual(runtime.session.state, .signingOut)
    XCTAssertThrowsError(try runtime.session.beginSignIn()) { error in
      XCTAssertEqual(error as? PutioSessionOperationError, .signInUnavailable)
    }

    fixtures.releaseFixture(for: Self.logoutRoute)
    await signOutTask.value
    XCTAssertEqual(runtime.session.state, .signedOut(.userSignedOut))

    _ = try runtime.session.beginSignIn()
    XCTAssertEqual(runtime.session.state, .authenticating)
  }

  func testStrayCallbackDuringSignOutDoesNotBlockCredentialCleanup() async throws {
    let (runtime, tokenStore) = await makeSignedInRuntime()
    fixtures.gateFixture(#"{"status":"OK"}"#, for: Self.logoutRoute)

    let signOutTask = Task { await runtime.session.signOut() }
    guard await waitForRequest(Self.logoutRoute) else {
      fixtures.releaseFixture(for: Self.logoutRoute)
      await signOutTask.value
      return XCTFail("logout request did not start")
    }

    let callback = try XCTUnwrap(
      URL(string: "putio://auth#access_token=stray-token&state=stray-state")
    )
    await runtime.session.completeSignIn(callbackURL: callback)
    XCTAssertEqual(runtime.session.state, .signingOut)

    fixtures.releaseFixture(for: Self.logoutRoute)
    await signOutTask.value
    XCTAssertEqual(runtime.session.state, .signedOut(.userSignedOut))
    XCTAssertNil(try? tokenStore.read())
  }

  func testOldSessionResponsesCannotEscapeIntoAFreshSession() async throws {
    for (statusCode, body) in [
      (200, Self.filesList(cursor: nil)),
      (401, #"{"status":"ERROR","error_type":"invalid_grant"}"#),
    ] {
      fixtures.reset()
      let (runtime, tokenStore) = await makeSignedInRuntime()
      fixtures.gateFixture(
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
        fixtures.releaseFixture(for: Self.filesRoute)
        return XCTFail("fresh session did not sign in")
      }

      fixtures.releaseFixture(for: Self.filesRoute)
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

  func makeRuntime(
    token: String?, fixtures: RuntimeMockURLProtocol.Fixtures? = nil
  ) -> (PutioRuntime, PutioInMemoryTokenStore) {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [RuntimeMockURLProtocol.self]
    RuntimeMockURLProtocol.registry.configure(configuration, fixture: fixtures ?? self.fixtures)
    let tokenStore = PutioInMemoryTokenStore(token: token)
    let runtime = PutioRuntime(
      clientID: "3001",
      clientName: "tests",
      tokenStore: tokenStore,
      urlSession: URLSession(configuration: configuration)
    )
    return (runtime, tokenStore)
  }

  func makeSignedInRuntime() async -> (PutioRuntime, PutioInMemoryTokenStore) {
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
    fixtures.setFixture(
      Self.validValidation,
      for: "GET /v2/oauth2/validate"
    )
    fixtures.setFixture(
      Self.accountInfo,
      for: "GET /v2/account/info"
    )
    fixtures.setFixture(
      #"{"status":"OK"}"#,
      for: Self.logoutRoute
    )
  }

  func assertRuntimeError(
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

  func requestBodyData(for request: URLRequest) -> Data? {
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

  private nonisolated func blockCurrentThread(seconds: TimeInterval) {
    Thread.sleep(forTimeInterval: seconds)
  }

  func waitForRequest(_ route: String, count: Int = 1) async -> Bool {
    let deadline = ContinuousClock.now + .seconds(5)
    while ContinuousClock.now < deadline {
      if fixtures.capturedRequests().filter({ request in
        guard let url = request.url else { return false }
        return "\(request.httpMethod ?? "GET") \(url.path)" == route
      }).count >= count {
        return true
      }
      try? await Task.sleep(for: .milliseconds(10))
    }
    return false
  }

  func oauthState(from url: URL) -> String? {
    URLComponents(url: url, resolvingAgainstBaseURL: false)?
      .queryItems?
      .first(where: { $0.name == "state" })?
      .value
  }

  static func filesList(cursor: String?, sortBy: String? = nil) -> String {
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
}
