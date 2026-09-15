import PutioSDK
import Synchronization
import XCTest

@testable import PutioCore

private final class SessionMockURLProtocol: URLProtocol, @unchecked Sendable {
  static let registry = TestURLProtocolRegistry<Fixtures>()

  final class Fixtures: @unchecked Sendable {
    fileprivate let lock = NSLock()
    private var storedFixtures: [String: (Int, String)] = [:]
    private var storedSequences: [String: [(Int, String)]] = [:]
    private var storedNetworkFailureRoutes: Set<String> = []
    private var storedRequests: [URLRequest] = []
    fileprivate var gatedRoutes: Set<String> = []
    fileprivate var responses: [String: @Sendable () -> Void] = [:]

    var fixtures: [String: (Int, String)] {
      get { lock.withLock { storedFixtures } }
      _modify {
        lock.lock()
        defer { lock.unlock() }
        yield &storedFixtures
      }
    }
    var sequences: [String: [(Int, String)]] {
      get { lock.withLock { storedSequences } }
      _modify {
        lock.lock()
        defer { lock.unlock() }
        yield &storedSequences
      }
    }
    var networkFailureRoutes: Set<String> {
      get { lock.withLock { storedNetworkFailureRoutes } }
      _modify {
        lock.lock()
        defer { lock.unlock() }
        yield &storedNetworkFailureRoutes
      }
    }
    var requests: [URLRequest] { lock.withLock { storedRequests } }

    func requestCount(route: String) -> Int {
      requests.filter { "\($0.httpMethod ?? "GET") \($0.url?.path ?? "")" == route }.count
    }

    func gate(_ route: String) { lock.withLock { _ = gatedRoutes.insert(route) } }

    func release(_ route: String) {
      let deliver = lock.withLock {
        gatedRoutes.remove(route)
        return responses.removeValue(forKey: route)
      }
      deliver?()
    }

    fileprivate func response(for request: URLRequest) -> (Int, String, Bool) {
      lock.withLock {
        storedRequests.append(request)
        let route = "\(request.httpMethod ?? "GET") \(request.url?.path ?? "")"
        if storedNetworkFailureRoutes.contains(route) { return (0, "", true) }
        if var queued = storedSequences[route], !queued.isEmpty {
          let next = queued.removeFirst()
          storedSequences[route] = queued
          return (next.0, next.1, false)
        }
        let fixture =
          storedFixtures[route]
          ?? (404, #"{"status":"ERROR","status_code":404,"error_type":"FIXTURE_NOT_FOUND"}"#)
        return (fixture.0, fixture.1, false)
      }
    }
  }

  override class func canInit(with request: URLRequest) -> Bool { true }
  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
  private let cancelled = Mutex(false)

  override func startLoading() {
    guard let url = request.url, let fixtures = Self.registry.fixture(for: request) else {
      client?.urlProtocol(self, didFailWithError: URLError(.resourceUnavailable))
      return
    }
    let route = "\(request.httpMethod ?? "GET") \(url.path)"
    let (statusCode, body, fails) = fixtures.response(for: request)
    let deliver: @Sendable () -> Void = { [self] in
      guard !cancelled.withLock({ $0 }) else { return }
      if fails {
        client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
        return
      }
      guard
        let response = HTTPURLResponse(
          url: url, statusCode: statusCode, httpVersion: nil,
          headerFields: ["Content-Type": "application/json"]
        )
      else {
        client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
        return
      }
      client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
      client?.urlProtocol(self, didLoad: Data(body.utf8))
      client?.urlProtocolDidFinishLoading(self)
    }
    let gated = fixtures.lock.withLock {
      guard fixtures.gatedRoutes.contains(route) else { return false }
      fixtures.responses[route] = deliver
      return true
    }
    if !gated { deliver() }
  }

  override func stopLoading() { cancelled.withLock { $0 = true } }
}

private final class FailingClearTokenStore: PutioTokenStore, @unchecked Sendable {
  private let lock = NSLock()
  private let storage = PutioInMemoryTokenStore(token: "stored-token")
  private var clearFails = true

  func allowClear() {
    lock.withLock { clearFails = false }
  }

  func read() throws -> String? { try storage.read() }
  func write(_ token: String) throws { try storage.write(token) }
  func clear() throws {
    try lock.withLock {
      if clearFails { throw URLError(.cannotWriteToFile) }
      try storage.clear()
    }
  }
}

@MainActor
final class PutioSessionStoreTests: XCTestCase {
  private static let validValidation =
    #"{"result": true, "token_id": 1, "token_scope": "default", "user_id": 1001}"#
  private static let rejectedValidation = #"{"result": false}"#
  private static func accountInfo(
    rememberVideoTime: Bool,
    suggestNextVideo: Bool = true,
    historyEnabled: Bool = true,
    trashEnabled: Bool = true
  ) -> String {
    """
    {
      "info": {
        "user_id": 1001,
        "username": "moviebuff",
        "mail": "tests@example.com",
        "avatar_url": "",
        "user_hash": "hash",
        "features": {},
        "download_token": "token",
        "trash_size": 0,
        "account_active": true,
        "files_will_be_deleted_at": "",
        "password_last_changed_at": "",
        "disk": { "avail": 10, "size": 30, "used": 20 },
        "settings": {
          "tunnel_route_name": "default",
          "next_episode": \(suggestNextVideo),
          "start_from": \(rememberVideoTime),
          "history_enabled": \(historyEnabled),
          "trash_enabled": \(trashEnabled),
          "sort_by": "NAME_ASC",
          "show_optimistic_usage": false,
          "two_factor_enabled": false,
          "hide_subtitles": false,
          "dont_autoselect_subtitles": false
        }
      }
    }
    """
  }

  private let fixtures = SessionMockURLProtocol.Fixtures()

  private func makeStore(token: String?) -> (PutioSessionStore, PutioInMemoryTokenStore) {
    let tokenStore = PutioInMemoryTokenStore(token: token)
    return (makeStore(tokenStore: tokenStore).0, tokenStore)
  }

  private func makeStore(
    tokenStore: PutioTokenStore, fixtures: SessionMockURLProtocol.Fixtures? = nil
  ) -> (PutioSessionStore, PutioSDK) {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [SessionMockURLProtocol.self]
    SessionMockURLProtocol.registry.configure(configuration, fixture: fixtures ?? self.fixtures)
    let sdk = PutioSDK(
      config: PutioSDKConfig(clientID: "3001", clientName: "tests"),
      urlSession: URLSession(configuration: configuration)
    )
    return (PutioSessionStore(sdk: sdk, tokenStore: tokenStore), sdk)
  }

  private func stubSignedInRoutes() {
    fixtures.fixtures["GET /v2/oauth2/validate"] = (200, Self.validValidation)
    fixtures.fixtures["GET /v2/account/info"] = (
      200,
      Self.accountInfo(rememberVideoTime: true)
    )
    fixtures.fixtures["POST /v2/oauth/grants/logout"] = (200, #"{"status":"OK"}"#)
  }

  func testConcurrentSessionsKeepResponsesAndCapturedRequestsIsolated() async throws {
    stubSignedInRoutes()
    let otherFixtures = SessionMockURLProtocol.Fixtures()
    otherFixtures.fixtures["GET /v2/oauth2/validate"] = (200, Self.validValidation)
    otherFixtures.fixtures["GET /v2/account/info"] = (
      200, Self.accountInfo(rememberVideoTime: false, historyEnabled: false)
    )
    let (first, _) = makeStore(token: "first-token")
    let (second, _) = makeStore(
      tokenStore: PutioInMemoryTokenStore(token: "second-token"), fixtures: otherFixtures)

    async let firstRestore: Void = first.restore()
    async let secondRestore: Void = second.restore()
    _ = await (firstRestore, secondRestore)

    guard case .signedIn(let firstAccount) = first.state,
      case .signedIn(let secondAccount) = second.state
    else { return XCTFail("both independent sessions must restore") }
    XCTAssertTrue(firstAccount.historyEnabled)
    XCTAssertFalse(secondAccount.historyEnabled)
    XCTAssertEqual(fixtures.requests.count, 2)
    XCTAssertEqual(otherFixtures.requests.count, 2)
    XCTAssertTrue(
      fixtures.requests.allSatisfy {
        $0.value(forHTTPHeaderField: "Authorization")?.lowercased() == "token first-token"
      })
    XCTAssertTrue(
      otherFixtures.requests.allSatisfy {
        $0.value(forHTTPHeaderField: "Authorization")?.lowercased() == "token second-token"
      })
  }

  func testDisabledHistoryIsPreservedInAccountSnapshot() async {
    fixtures.fixtures["GET /v2/oauth2/validate"] = (200, Self.validValidation)
    fixtures.fixtures["GET /v2/account/info"] = (
      200, Self.accountInfo(rememberVideoTime: true, historyEnabled: false)
    )
    let (store, _) = makeStore(token: "stored-token")
    await store.restore()
    guard case .signedIn(let account) = store.state else {
      return XCTFail("expected a restored account")
    }
    XCTAssertFalse(account.historyEnabled)
  }

  func testRestoreWithoutTokenLandsSignedOut() async {
    let (store, _) = makeStore(token: nil)
    await store.restore()
    XCTAssertEqual(store.state, .signedOut(nil))
  }

  func testRestoreWithValidTokenSignsIn() async {
    stubSignedInRoutes()
    let (store, _) = makeStore(token: "stored-token")
    await store.restore()
    guard case .signedIn(let account) = store.state else {
      return XCTFail("expected signedIn, got \(store.state)")
    }
    XCTAssertTrue(account.suggestNextVideo)
    XCTAssertEqual(
      account,
      PutioAccountSnapshot(
        id: 1001,
        username: "moviebuff",
        email: "tests@example.com",
        suggestNextVideo: true,
        rememberVideoTime: true,
        defaultSort: .nameAscending,
        historyEnabled: true,
        trashEnabled: true,
        storage: PutioAccountSnapshot.Storage(
          availableBytes: 10,
          totalBytes: 30,
          usedBytes: 20
        )
      )
    )
  }

  func testRestoreMapsDisabledRememberVideoTimeSetting() async {
    fixtures.fixtures["GET /v2/oauth2/validate"] = (200, Self.validValidation)
    fixtures.fixtures["GET /v2/account/info"] = (
      200,
      Self.accountInfo(rememberVideoTime: false)
    )
    let (store, _) = makeStore(token: "stored-token")

    await store.restore()

    guard case .signedIn(let account) = store.state else {
      return XCTFail("expected signedIn, got \(store.state)")
    }
    XCTAssertFalse(account.rememberVideoTime)
  }

  func testRestoreMapsDisabledTrashSetting() async {
    fixtures.fixtures["GET /v2/oauth2/validate"] = (200, Self.validValidation)
    fixtures.fixtures["GET /v2/account/info"] = (
      200,
      Self.accountInfo(rememberVideoTime: true, trashEnabled: false)
    )
    let (store, _) = makeStore(token: "stored-token")

    await store.restore()

    guard case .signedIn(let account) = store.state else {
      return XCTFail("expected signedIn, got \(store.state)")
    }
    XCTAssertFalse(account.trashEnabled)
  }

  func testRestoreMapsDisabledNextVideoSetting() async {
    fixtures.fixtures["GET /v2/oauth2/validate"] = (200, Self.validValidation)
    fixtures.fixtures["GET /v2/account/info"] = (
      200,
      Self.accountInfo(rememberVideoTime: true, suggestNextVideo: false)
    )
    let (store, _) = makeStore(token: "stored-token")

    await store.restore()

    guard case .signedIn(let account) = store.state else {
      return XCTFail("expected signedIn, got \(store.state)")
    }
    XCTAssertFalse(account.suggestNextVideo)
  }

  func testRestoreWithRejectedTokenClearsAndExpires() async {
    fixtures.fixtures["GET /v2/oauth2/validate"] = (200, Self.rejectedValidation)
    let (store, tokenStore) = makeStore(token: "revoked-token")
    await store.restore()
    XCTAssertEqual(store.state, .signedOut(.sessionExpired))
    XCTAssertNil(try tokenStore.read())
  }

  func testRestoreWithUnauthorizedResponseClearsAndExpires() async {
    fixtures.fixtures["GET /v2/oauth2/validate"] = (
      401, #"{"status":"ERROR","status_code":401,"error_type":"invalid_grant"}"#
    )
    let (store, tokenStore) = makeStore(token: "revoked-token")
    await store.restore()
    XCTAssertEqual(store.state, .signedOut(.sessionExpired))
    XCTAssertNil(try tokenStore.read())
  }

  func testRestoreNetworkFailureKeepsTokenForRetry() async {
    fixtures.networkFailureRoutes.insert("GET /v2/oauth2/validate")
    let (store, tokenStore) = makeStore(token: "stored-token")
    await store.restore()
    guard case .signedOut(.restoreFailed) = store.state else {
      return XCTFail("expected restoreFailed, got \(store.state)")
    }
    XCTAssertEqual(try tokenStore.read(), "stored-token")
  }

  func testSignInFlowStoresTokenAndBootstrapsAccount() async throws {
    stubSignedInRoutes()
    let (store, tokenStore) = makeStore(token: nil)

    let request = try store.beginSignIn()
    XCTAssertEqual(store.state, .authenticating)
    let oauthState = try XCTUnwrap(oauthState(from: request.url))

    let callback = try XCTUnwrap(
      URL(string: "putio://auth#access_token=fresh-token&state=\(oauthState)")
    )
    await store.completeSignIn(callbackURL: callback)

    guard case .signedIn(let account) = store.state else {
      return XCTFail("expected signedIn, got \(store.state)")
    }
    XCTAssertEqual(account.username, "moviebuff")
    XCTAssertEqual(account.email, "tests@example.com")
    XCTAssertEqual(try tokenStore.read(), "fresh-token")
  }

  func testRestoreDoesNotSupersedeSignInStartedBeforeRestore() async throws {
    stubSignedInRoutes()
    let (store, tokenStore) = makeStore(token: nil)

    let request = try store.beginSignIn()
    await store.restore()
    XCTAssertEqual(store.state, .authenticating)

    let oauthState = try XCTUnwrap(oauthState(from: request.url))
    let callback = try XCTUnwrap(
      URL(string: "putio://auth#access_token=fresh-token&state=\(oauthState)")
    )
    await store.completeSignIn(callbackURL: callback)

    guard case .signedIn(let account) = store.state else {
      return XCTFail("expected signedIn, got \(store.state)")
    }
    XCTAssertEqual(account.username, "moviebuff")
    XCTAssertEqual(try tokenStore.read(), "fresh-token")
  }

  func testDuplicateSignInFailureKeepsFirstFlowActive() async throws {
    stubSignedInRoutes()
    let (store, tokenStore) = makeStore(token: nil)

    let firstRequest = try store.beginSignIn()
    do {
      _ = try store.beginSignIn()
      XCTFail("expected the overlapping sign-in to be rejected")
    } catch {
      XCTAssertEqual(error as? PutioSessionOperationError, .signInUnavailable)
      store.failSignIn(error)
    }
    XCTAssertEqual(store.state, .authenticating)

    let oauthState = try XCTUnwrap(oauthState(from: firstRequest.url))
    let callback = try XCTUnwrap(
      URL(string: "putio://auth#access_token=fresh-token&state=\(oauthState)")
    )
    await store.completeSignIn(callbackURL: callback)

    guard case .signedIn(let account) = store.state else {
      return XCTFail("expected signedIn, got \(store.state)")
    }
    XCTAssertEqual(account.username, "moviebuff")
    XCTAssertEqual(try tokenStore.read(), "fresh-token")
  }

  func testSignInRejectsMismatchedState() async throws {
    stubSignedInRoutes()
    let (store, tokenStore) = makeStore(token: nil)

    _ = try store.beginSignIn()
    let callback = try XCTUnwrap(
      URL(string: "putio://auth#access_token=fresh-token&state=forged-state")
    )
    await store.completeSignIn(callbackURL: callback)

    guard case .signedOut(.authenticationFailed) = store.state else {
      return XCTFail("expected authenticationFailed, got \(store.state)")
    }
    XCTAssertNil(try tokenStore.read())
  }

  func testSignOutClearsSessionState() async {
    stubSignedInRoutes()
    let (store, tokenStore) = makeStore(token: "stored-token")
    await store.restore()

    await store.signOut()

    XCTAssertEqual(store.state, .signedOut(.userSignedOut))
    XCTAssertNil(try tokenStore.read())
  }

  func testFailedCredentialRemovalBlocksSessionRecoveryUntilRetry() async throws {
    stubSignedInRoutes()
    let tokenStore = FailingClearTokenStore()
    let (store, sdk) = makeStore(tokenStore: tokenStore)
    await store.restore()
    await store.signOut()

    XCTAssertEqual(store.state, .signOutFailed(.credentialRemoval))
    XCTAssertEqual(try tokenStore.read(), "stored-token")
    XCTAssertTrue(sdk.config.token.isEmpty)
    await store.restore()
    XCTAssertThrowsError(try store.beginSignIn())
    store.cancelSignIn()
    store.failSignIn(URLError(.cancelled))
    XCTAssertEqual(store.state, .signOutFailed(.credentialRemoval))

    tokenStore.allowClear()
    await store.signOut()
    XCTAssertEqual(store.state, .signedOut(.userSignedOut))
    XCTAssertNil(try tokenStore.read())
    XCTAssertEqual(
      fixtures.requests.filter {
        $0.url?.path == "/v2/oauth/grants/logout"
      }.count, 1, "successful revocation must not be repeated for a local cleanup retry")
  }

  func testFailedRevocationRetainsOnlyAnInactiveCredentialForRetry() async throws {
    stubSignedInRoutes()
    let tokenStore = PutioInMemoryTokenStore(token: "stored-token")
    let (store, sdk) = makeStore(tokenStore: tokenStore)
    await store.restore()
    fixtures.networkFailureRoutes = ["POST /v2/oauth/grants/logout"]
    await store.signOut()

    XCTAssertEqual(store.state, .signOutFailed(.revocation))
    XCTAssertNil(try tokenStore.read())
    XCTAssertTrue(sdk.config.token.isEmpty)
    fixtures.networkFailureRoutes = []
    await store.signOut()
    XCTAssertEqual(store.state, .signedOut(.userSignedOut))
    XCTAssertEqual(
      fixtures.requests.last?.value(forHTTPHeaderField: "Authorization"),
      "token stored-token")
    XCTAssertTrue(sdk.config.token.isEmpty)
  }

  func testCombinedSignOutFailureRemainsExplicitAndRetainedTokenCanRestoreInANewInstance()
    async throws
  {
    stubSignedInRoutes()
    let tokenStore = FailingClearTokenStore()
    let (store, sdk) = makeStore(tokenStore: tokenStore)
    await store.restore()
    fixtures.networkFailureRoutes = ["POST /v2/oauth/grants/logout"]
    await store.signOut()

    XCTAssertEqual(store.state, .signOutFailed(.credentialRemovalAndRevocation))
    XCTAssertTrue(sdk.config.token.isEmpty)
    await store.restore()
    XCTAssertEqual(store.state, .signOutFailed(.credentialRemovalAndRevocation))

    let (relaunched, _) = makeStore(tokenStore: tokenStore)
    await relaunched.restore()
    guard case .signedIn = relaunched.state else {
      return XCTFail("without durable sign-out intent, a still-valid persisted token can restore")
    }
    tokenStore.allowClear()
    fixtures.networkFailureRoutes = []
    await store.signOut()
    XCTAssertEqual(store.state, .signedOut(.userSignedOut))
    let (afterCleanup, _) = makeStore(tokenStore: tokenStore)
    await afterCleanup.restore()
    XCTAssertEqual(afterCleanup.state, .signedOut(nil))
  }

  func testRejectedTokenCompletesRevocationDuringRetry() async {
    stubSignedInRoutes()
    let (store, _) = makeStore(token: "stored-token")
    await store.restore()
    fixtures.networkFailureRoutes = ["POST /v2/oauth/grants/logout"]
    await store.signOut()
    fixtures.networkFailureRoutes = []
    fixtures.fixtures["POST /v2/oauth/grants/logout"] =
      (401, #"{"status":"ERROR","error_type":"invalid_grant"}"#)
    await store.signOut()
    XCTAssertEqual(store.state, .signedOut(.userSignedOut))
  }

  func testCancelSignInReturnsToSignedOutWithoutError() async throws {
    let (store, _) = makeStore(token: nil)
    _ = try store.beginSignIn()
    store.cancelSignIn()
    XCTAssertEqual(store.state, .signedOut(nil))
  }

  func testStrayCallbackWhileSignedInIsIgnored() async throws {
    stubSignedInRoutes()
    let (store, tokenStore) = makeStore(token: "stored-token")
    await store.restore()
    guard case .signedIn = store.state else {
      return XCTFail("expected signedIn, got \(store.state)")
    }

    let callback = try XCTUnwrap(
      URL(string: "putio://auth#access_token=stray-token&state=stray-state")
    )
    await store.completeSignIn(callbackURL: callback)

    guard case .signedIn = store.state else {
      return XCTFail("stray callback must not disturb a signed-in session")
    }
    XCTAssertEqual(try tokenStore.read(), "stored-token")
  }

  func testStrayCallbackAfterCancelIsIgnored() async throws {
    let (store, _) = makeStore(token: nil)
    _ = try store.beginSignIn()
    store.cancelSignIn()

    let callback = try XCTUnwrap(
      URL(string: "putio://auth#access_token=stray-token&state=stray-state")
    )
    await store.completeSignIn(callbackURL: callback)

    XCTAssertEqual(store.state, .signedOut(nil))
  }

  // MARK: - Device code

  private static let pendingCode = #"{"oauth_token": null}"#
  private static let expiredCode =
    #"{"status":"ERROR","status_code":404,"error_type":"code_not_found"}"#
  private static let approvedCode = #"{"oauth_token": "device-token"}"#

  private func stubDeviceCodeIssue(_ codes: [String]) {
    fixtures.sequences["GET /v2/oauth2/oob/code"] = codes.map {
      (200, #"{"code": "\#($0)", "qr_code_url": null}"#)
    }
  }

  private func waitUntil(
    _ condition: @MainActor () -> Bool, timeout: TimeInterval = 5
  ) async -> Bool {
    let deadline = ContinuousClock.now + .seconds(timeout)
    while ContinuousClock.now < deadline {
      if condition() { return true }
      try? await Task.sleep(for: .milliseconds(20))
    }
    return condition()
  }

  func testDeviceCodeSignInShowsTheCodeThenSignsInAfterApproval() async throws {
    stubSignedInRoutes()
    stubDeviceCodeIssue(["ABCD1"])
    fixtures.sequences["GET /v2/oauth2/oob/code/ABCD1"] = [
      (200, Self.pendingCode), (200, Self.approvedCode),
    ]
    let (store, tokenStore) = makeStore(token: nil)
    let signIn = Task { await store.signInWithDeviceCode() }
    let reached1 = await waitUntil { store.deviceCodeSignIn == .awaitingApproval(code: "ABCD1") }
    XCTAssertTrue(reached1)
    XCTAssertEqual(store.state, .authenticating)
    await signIn.value
    guard case .signedIn(let account) = store.state else {
      return XCTFail("expected signedIn, got \(store.state)")
    }
    XCTAssertEqual(account.username, "moviebuff")
    XCTAssertNil(store.deviceCodeSignIn)
    XCTAssertEqual(try tokenStore.read(), "device-token")
    XCTAssertEqual(fixtures.requestCount(route: "GET /v2/oauth2/oob/code/ABCD1"), 2)
    let accountRequest = try XCTUnwrap(
      fixtures.requests.last { $0.url?.path == "/v2/account/info" })
    XCTAssertEqual(accountRequest.value(forHTTPHeaderField: "Authorization"), "token device-token")
  }

  func testExpiredDeviceCodeStaysAuthenticatingUntilANewCodeIsRequested() async throws {
    stubSignedInRoutes()
    stubDeviceCodeIssue(["OLD01", "NEW02"])
    fixtures.sequences["GET /v2/oauth2/oob/code/OLD01"] = [
      (200, Self.pendingCode), (404, Self.expiredCode),
    ]
    fixtures.sequences["GET /v2/oauth2/oob/code/NEW02"] = [
      (200, Self.pendingCode), (200, Self.approvedCode),
    ]
    let (store, _) = makeStore(token: nil)
    await store.signInWithDeviceCode()
    XCTAssertEqual(store.state, .authenticating)
    XCTAssertEqual(store.deviceCodeSignIn, .expired(code: "OLD01"))
    XCTAssertThrowsError(try store.beginSignIn())

    let renewal = Task { await store.signInWithDeviceCode() }
    let reached2 = await waitUntil { store.deviceCodeSignIn == .awaitingApproval(code: "NEW02") }
    XCTAssertTrue(reached2)
    await renewal.value
    guard case .signedIn = store.state else {
      return XCTFail("expected signedIn after the renewed code, got \(store.state)")
    }
    XCTAssertEqual(fixtures.requestCount(route: "GET /v2/oauth2/oob/code"), 2)
    XCTAssertEqual(fixtures.requestCount(route: "GET /v2/oauth2/oob/code/OLD01"), 2)
  }

  func testCancellingDeviceCodeSignInStopsPollingAndReturnsSignedOut() async throws {
    stubDeviceCodeIssue(["WAIT1"])
    fixtures.fixtures["GET /v2/oauth2/oob/code/WAIT1"] = (200, Self.pendingCode)
    let (store, tokenStore) = makeStore(token: nil)
    let signIn = Task { await store.signInWithDeviceCode() }
    let reached3 = await waitUntil { store.deviceCodeSignIn == .awaitingApproval(code: "WAIT1") }
    XCTAssertTrue(reached3)
    let reached4 = await waitUntil {
      fixtures.requestCount(route: "GET /v2/oauth2/oob/code/WAIT1") >= 1
    }
    XCTAssertTrue(reached4)
    let pollsAtCancel = fixtures.requestCount(route: "GET /v2/oauth2/oob/code/WAIT1")
    store.cancelSignIn()
    XCTAssertEqual(store.state, .signedOut(nil))
    XCTAssertNil(store.deviceCodeSignIn)
    await signIn.value
    XCTAssertEqual(store.state, .signedOut(nil))
    XCTAssertEqual(
      fixtures.requestCount(route: "GET /v2/oauth2/oob/code/WAIT1"), pollsAtCancel,
      "polling must stop with the cancelled sign-in")
    XCTAssertNil(try tokenStore.read())
  }

  func testLateApprovalAfterCancellationDoesNotSignIn() async throws {
    stubSignedInRoutes()
    stubDeviceCodeIssue(["LATE1"])
    let route = "GET /v2/oauth2/oob/code/LATE1"
    fixtures.gate(route)
    defer { fixtures.release(route) }
    fixtures.fixtures["GET /v2/oauth2/oob/code/LATE1"] = (200, Self.approvedCode)
    let (store, tokenStore) = makeStore(token: nil)
    let signIn = Task { await store.signInWithDeviceCode() }
    let reached5 = await waitUntil { fixtures.requestCount(route: route) == 1 }
    guard reached5 else {
      signIn.cancel()
      return XCTFail("approval request did not reach the response gate")
    }
    store.cancelSignIn()
    fixtures.release(route)
    await signIn.value
    XCTAssertEqual(store.state, .signedOut(nil))
    XCTAssertNil(try tokenStore.read())
  }

  func testDeviceCodeFetchFailureLandsSignedOutWithAMessage() async {
    fixtures.networkFailureRoutes = ["GET /v2/oauth2/oob/code"]
    let (store, _) = makeStore(token: nil)
    await store.signInWithDeviceCode()
    XCTAssertEqual(
      store.state,
      .signedOut(
        .authenticationFailed("put.io is unreachable. Check your connection and try again.")))
    XCTAssertNil(store.deviceCodeSignIn)
  }

  func testDeviceCodePollFailureLandsSignedOutWithAMessage() async {
    stubDeviceCodeIssue(["FAIL1"])
    fixtures.fixtures["GET /v2/oauth2/oob/code/FAIL1"] =
      (500, #"{"status":"ERROR","status_code":500,"error_type":"SERVER"}"#)
    let (store, _) = makeStore(token: nil)
    await store.signInWithDeviceCode()
    XCTAssertEqual(
      store.state,
      .signedOut(.authenticationFailed("put.io could not complete the request. Try again.")))
    XCTAssertNil(store.deviceCodeSignIn)
  }

  func testDeviceCodeSignInIsIgnoredWhileSignedIn() async {
    stubSignedInRoutes()
    let (store, _) = makeStore(token: "stored-token")
    await store.restore()
    await store.signInWithDeviceCode()
    guard case .signedIn = store.state else {
      return XCTFail("expected signedIn, got \(store.state)")
    }
    XCTAssertEqual(fixtures.requestCount(route: "GET /v2/oauth2/oob/code"), 0)
  }

  func testSignOutAfterDeviceCodeSignInReturnsToSignedOutAndClearsTheToken() async throws {
    stubSignedInRoutes()
    stubDeviceCodeIssue(["DONE1"])
    fixtures.fixtures["GET /v2/oauth2/oob/code/DONE1"] = (200, Self.approvedCode)
    let (store, tokenStore) = makeStore(token: nil)
    await store.signInWithDeviceCode()
    guard case .signedIn = store.state else {
      return XCTFail("expected signedIn, got \(store.state)")
    }
    await store.signOut()
    XCTAssertEqual(store.state, .signedOut(.userSignedOut))
    XCTAssertNil(try tokenStore.read())
  }

  private func oauthState(from url: URL) -> String? {
    URLComponents(url: url, resolvingAgainstBaseURL: false)?
      .queryItems?
      .first(where: { $0.name == "state" })?
      .value
  }
}
