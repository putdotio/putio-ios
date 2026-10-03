import PutioSDK
import Security
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
    fileprivate var requestObservers: [String: @Sendable () -> Void] = [:]

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

    /// Runs `observer` for each request on `route`, after a gated response is held.
    func onRequest(_ route: String, _ observer: @escaping @Sendable () -> Void) {
      lock.withLock { requestObservers[route] = observer }
    }

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
    let (gated, observer) = fixtures.lock.withLock {
      let observer = fixtures.requestObservers[route]
      guard fixtures.gatedRoutes.contains(route) else { return (false, observer) }
      fixtures.responses[route] = deliver
      return (true, observer)
    }
    observer?()
    if !gated { deliver() }
  }

  override func stopLoading() { cancelled.withLock { $0 = true } }
}

/// Signals once the SDK has produced a request failure, before the caller resumes.
private final class SDKFailureSignal: PutioSDKDelegate, @unchecked Sendable {
  private let failed = DispatchSemaphore(value: 0)

  func onPutioSDKError(error: PutioSDKError) { failed.signal() }

  func wait(seconds: TimeInterval) -> Bool {
    failed.wait(timeout: .now() + seconds) == .success
  }
}

private final class FailingClearTokenStore: PutioTokenStore {
  private let storage = PutioInMemoryTokenStore(token: "stored-token")
  private let clearFails = Mutex(true)

  func allowClear() {
    clearFails.withLock { $0 = false }
  }

  func read() throws -> String? { try storage.read() }
  func write(_ token: String) throws { try storage.write(token) }
  func clear() throws {
    try clearFails.withLock { clearFails in
      if clearFails { throw URLError(.cannotWriteToFile) }
      try storage.clear()
    }
  }
}

/// Fails reads or writes the way a locked or unavailable keychain does.
private final class KeychainFailureTokenStore: PutioTokenStore {
  private struct Failures {
    var read = false
    var write = false
    var clear = false
  }

  private let storage: PutioInMemoryTokenStore
  private let failures: Mutex<Failures>

  init(
    token: String?, failingReads: Bool = false, failingWrites: Bool = false,
    failingClears: Bool = false
  ) {
    storage = PutioInMemoryTokenStore(token: token)
    failures = Mutex(Failures(read: failingReads, write: failingWrites, clear: failingClears))
  }

  func allowReads() { failures.withLock { $0.read = false } }

  func storedToken() -> String? { try? storage.read() }

  func read() throws -> String? {
    if failures.withLock({ $0.read }) {
      throw PutioTokenStoreError.keychainFailure(errSecInteractionNotAllowed)
    }
    return try storage.read()
  }

  func write(_ token: String) throws {
    if failures.withLock({ $0.write }) {
      throw PutioTokenStoreError.keychainFailure(errSecInteractionNotAllowed)
    }
    try storage.write(token)
  }

  func clear() throws {
    if failures.withLock({ $0.clear }) {
      throw PutioTokenStoreError.keychainFailure(errSecInteractionNotAllowed)
    }
    try storage.clear()
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
    trashEnabled: Bool = true,
    avatarURL: String = "",
    trashSize: Int64 = 0
  ) -> String {
    """
    {
      "info": {
        "user_id": 1001,
        "username": "moviebuff",
        "mail": "tests@example.com",
        "avatar_url": "\(avatarURL)",
        "user_hash": "hash",
        "features": {},
        "download_token": "token",
        "trash_size": \(trashSize),
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

  func testAvatarAndTrashSizeSurvivePreferenceAcknowledgement() async {
    fixtures.fixtures["GET /v2/oauth2/validate"] = (200, Self.validValidation)
    fixtures.fixtures["GET /v2/account/info"] = (
      200,
      Self.accountInfo(
        rememberVideoTime: true, avatarURL: "https://static.put.io/avatar.png",
        trashSize: 4096)
    )
    let (store, _) = makeStore(token: "stored-token")
    await store.restore()
    store.applyAcknowledgedPreferences(hideSubtitles: true)

    guard case .signedIn(let account) = store.state else {
      return XCTFail("expected signedIn, got \(store.state)")
    }
    XCTAssertTrue(account.hideSubtitles)
    XCTAssertEqual(account.avatarURL, URL(string: "https://static.put.io/avatar.png"))
    XCTAssertEqual(account.trashSizeBytes, 4096)
  }

  func testNonHTTPSAvatarIsDropped() async {
    fixtures.fixtures["GET /v2/oauth2/validate"] = (200, Self.validValidation)
    fixtures.fixtures["GET /v2/account/info"] = (
      200, Self.accountInfo(rememberVideoTime: true, avatarURL: "http://example.com/a.png")
    )
    let (store, _) = makeStore(token: "stored-token")
    await store.restore()

    guard case .signedIn(let account) = store.state else {
      return XCTFail("expected signedIn, got \(store.state)")
    }
    XCTAssertNil(account.avatarURL)
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

  private static let keychainUnavailable =
    PutioSignedOutReason.authenticationFailed("This device's keychain is unavailable. Try again.")

  func testUnreadableStoredTokenFailsRestoreAndKeepsItForRetry() async {
    stubSignedInRoutes()
    let tokenStore = KeychainFailureTokenStore(token: "stored-token", failingReads: true)
    let (store, sdk) = makeStore(tokenStore: tokenStore)

    await store.restore()

    XCTAssertEqual(
      store.state, .signedOut(.restoreFailed("This device's keychain is unavailable. Try again.")))
    XCTAssertEqual(tokenStore.storedToken(), "stored-token")
    XCTAssertTrue(sdk.config.token.isEmpty)
    XCTAssertTrue(fixtures.requests.isEmpty)

    tokenStore.allowReads()
    await store.restore()
    guard case .signedIn = store.state else {
      return XCTFail("a readable token must restore on retry, got \(store.state)")
    }
  }

  func testRestoreFailureBlocksFreshSignInUntilRetrySucceeds() async {
    stubSignedInRoutes()
    let tokenStore = KeychainFailureTokenStore(token: "stored-token", failingReads: true)
    let (store, sdk) = makeStore(tokenStore: tokenStore)
    await store.restore()
    let recoveryState = store.state

    do {
      _ = try store.beginSignIn()
      XCTFail("restore recovery must block a fresh OAuth flow")
    } catch {
      XCTAssertEqual(error as? PutioSessionOperationError, .signInUnavailable)
      store.failSignIn(error)
    }
    XCTAssertEqual(store.state, recoveryState)

    await store.signInWithDeviceCode()
    XCTAssertEqual(store.state, recoveryState)
    XCTAssertNil(store.deviceCodeSignIn)
    XCTAssertTrue(fixtures.requests.isEmpty)
    XCTAssertTrue(sdk.config.token.isEmpty)
    XCTAssertEqual(tokenStore.storedToken(), "stored-token")

    tokenStore.allowReads()
    await store.restore()
    guard case .signedIn = store.state else {
      return XCTFail("the retained credential must restore on retry, got \(store.state)")
    }
    XCTAssertEqual(sdk.config.token, "stored-token")
  }

  func testChoosingToDiscardAnUnrestoredCredentialReturnsToSignIn() async throws {
    stubSignedInRoutes()
    let tokenStore = KeychainFailureTokenStore(token: "stored-token", failingReads: true)
    let (store, sdk) = makeStore(tokenStore: tokenStore)
    await store.restore()
    guard case .signedOut(.restoreFailed) = store.state else {
      return XCTFail("expected restoreFailed, got \(store.state)")
    }

    store.discardUnrestoredCredential()

    XCTAssertEqual(store.state, .signedOut(nil))
    XCTAssertNil(tokenStore.storedToken(), "the unreadable credential was kept")
    XCTAssertTrue(sdk.config.token.isEmpty)
    XCTAssertTrue(fixtures.requests.isEmpty)
    _ = try store.beginSignIn()
    XCTAssertEqual(store.state, .authenticating)
  }

  func testDiscardingAnUnrestoredCredentialThatCannotBeRemovedKeepsRestoreRecovery() async {
    stubSignedInRoutes()
    let tokenStore = KeychainFailureTokenStore(
      token: "stored-token", failingReads: true, failingClears: true)
    let (store, _) = makeStore(tokenStore: tokenStore)
    await store.restore()

    store.discardUnrestoredCredential()

    XCTAssertEqual(
      store.state, .signedOut(.restoreFailed("This device's keychain is unavailable. Try again.")))
    XCTAssertEqual(tokenStore.storedToken(), "stored-token")
    XCTAssertThrowsError(try store.beginSignIn())
  }

  func testDiscardingACredentialOutsideRestoreRecoveryDoesNothing() async {
    stubSignedInRoutes()
    let (store, tokenStore) = makeStore(token: "stored-token")
    await store.restore()
    guard case .signedIn = store.state else {
      return XCTFail("expected signedIn, got \(store.state)")
    }

    store.discardUnrestoredCredential()

    guard case .signedIn = store.state else {
      return XCTFail("a signed-in session was discarded, got \(store.state)")
    }
    XCTAssertEqual(try tokenStore.read(), "stored-token")
    store.expireSession()
    try? tokenStore.write("stored-token")
    store.discardUnrestoredCredential()
    XCTAssertEqual(store.state, .signedOut(.sessionExpired))
    XCTAssertEqual(try tokenStore.read(), "stored-token")
  }

  func testWebSignInRevokesTheGrantWhenTheTokenCannotBeSaved() async throws {
    stubSignedInRoutes()
    let tokenStore = KeychainFailureTokenStore(token: nil, failingWrites: true)
    let (store, sdk) = makeStore(tokenStore: tokenStore)

    let request = try store.beginSignIn()
    let oauthState = try XCTUnwrap(oauthState(from: request.url))
    let callback = try XCTUnwrap(
      URL(string: "putio://auth#access_token=fresh-token&state=\(oauthState)"))
    await store.completeSignIn(callbackURL: callback)

    XCTAssertEqual(store.state, .signedOut(Self.keychainUnavailable))
    XCTAssertTrue(sdk.config.token.isEmpty)
    XCTAssertNil(tokenStore.storedToken())
    assertOnlyRevocationSent(token: "fresh-token")
  }

  func testDeviceCodeSignInRevokesTheGrantWhenTheTokenCannotBeSaved() async throws {
    stubSignedInRoutes()
    stubDeviceCodeIssue(["SAVE1"])
    fixtures.fixtures["GET /v2/oauth2/oob/code/SAVE1"] = (200, Self.approvedCode)
    let tokenStore = KeychainFailureTokenStore(token: nil, failingWrites: true)
    let (store, sdk) = makeStore(tokenStore: tokenStore)

    await store.signInWithDeviceCode()

    XCTAssertEqual(store.state, .signedOut(Self.keychainUnavailable))
    XCTAssertNil(store.deviceCodeSignIn)
    XCTAssertTrue(sdk.config.token.isEmpty)
    assertOnlyRevocationSent(token: "device-token")
  }

  private func assertOnlyRevocationSent(
    token: String, file: StaticString = #filePath, line: UInt = #line
  ) {
    let authorized = fixtures.requests.filter {
      $0.value(forHTTPHeaderField: "Authorization") == "token \(token)"
    }
    XCTAssertEqual(
      authorized.map { "\($0.httpMethod ?? "GET") \($0.url?.path ?? "")" },
      ["POST /v2/oauth/grants/logout"], file: file, line: line)
  }

  func testExpiredCredentialThatCouldNotBeRemovedIsRemovedByTheNextRestore() async {
    stubSignedInRoutes()
    let tokenStore = FailingClearTokenStore()
    let (store, _) = makeStore(tokenStore: tokenStore)
    await store.restore()

    store.expireSession()
    XCTAssertEqual(store.state, .signedOut(.sessionExpired))
    XCTAssertEqual(try tokenStore.read(), "stored-token")

    tokenStore.allowClear()
    fixtures.fixtures["GET /v2/oauth2/validate"] = (200, Self.rejectedValidation)
    let (relaunched, _) = makeStore(tokenStore: tokenStore)
    await relaunched.restore()
    XCTAssertEqual(relaunched.state, .signedOut(.sessionExpired))
    XCTAssertNil(try tokenStore.read())
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

  func testAccountRefreshRejectionSeenByACancelledTaskStillExpiresTheSession() async {
    stubSignedInRoutes()
    let tokenStore = PutioInMemoryTokenStore(token: "stored-token")
    let (store, sdk) = makeStore(tokenStore: tokenStore)
    await store.restore()
    let route = "GET /v2/account/info"
    fixtures.fixtures[route] = (401, #"{"status":"ERROR","error_type":"invalid_grant"}"#)
    fixtures.gate(route)
    let requested = expectRequest(route)
    let rejected = SDKFailureSignal()
    sdk.delegate = rejected
    let refresh = Task { await store.refreshAccount() }
    await fulfillment(of: [requested], timeout: 5)

    // Holding the main actor until the SDK has the 401 makes the store
    // resume with both the rejection and the cancellation.
    fixtures.release(route)
    let sawRejection = rejected.wait(seconds: 5)
    refresh.cancel()
    XCTAssertTrue(sawRejection, "the SDK never reported the 401")

    let refreshed = await refresh.value
    XCTAssertFalse(refreshed)
    XCTAssertEqual(store.state, .signedOut(.sessionExpired))
    XCTAssertNil(try tokenStore.read())
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

  private func expectRequest(_ route: String) -> XCTestExpectation {
    let requested = expectation(description: "\(route) requested")
    fixtures.onRequest(route) { requested.fulfill() }
    return requested
  }

  private func waitForDeviceCodeRequest(
    _ requested: XCTestExpectation,
    store: PutioSessionStore,
    task: Task<Void, Never>,
    route: String,
    timeout: TimeInterval = 5
  ) async -> XCTWaiter.Result {
    let result = await XCTWaiter.fulfillment(of: [requested], timeout: timeout)
    if result != .completed {
      store.cancelSignIn()
      task.cancel()
      fixtures.release(route)
      await task.value
    }
    return result
  }

  func testDeviceCodeRequestTimeoutCancelsSignInBeforePollingStarts() async {
    stubDeviceCodeIssue(["STALL"])
    let issue = "GET /v2/oauth2/oob/code"
    fixtures.gate(issue)
    defer { fixtures.release(issue) }
    let issued = expectRequest(issue)
    let poll = "GET /v2/oauth2/oob/code/STALL"
    fixtures.gate(poll)
    let polled = expectRequest(poll)
    let (store, tokenStore) = makeStore(token: nil)
    let signIn = Task { await store.signInWithDeviceCode() }
    await fulfillment(of: [issued], timeout: 5)

    let result = await waitForDeviceCodeRequest(
      polled, store: store, task: signIn, route: poll, timeout: 0.01)

    XCTAssertEqual(result, .timedOut)
    XCTAssertTrue(signIn.isCancelled)
    XCTAssertEqual(store.state, .signedOut(nil))
    XCTAssertNil(store.deviceCodeSignIn)
    XCTAssertNil(try tokenStore.read())
    XCTAssertEqual(fixtures.requestCount(route: poll), 0)
  }

  func testDeviceCodeSignInShowsTheCodeThenSignsInAfterApproval() async throws {
    stubSignedInRoutes()
    stubDeviceCodeIssue(["ABCD1"])
    // The held poll stands in for pending ones; the SDK owns re-polling and its
    // minimum one-second interval.
    let poll = "GET /v2/oauth2/oob/code/ABCD1"
    fixtures.fixtures[poll] = (200, Self.approvedCode)
    fixtures.gate(poll)
    let polled = expectRequest(poll)
    let (store, tokenStore) = makeStore(token: nil)
    let signIn = Task { await store.signInWithDeviceCode() }
    let result = await waitForDeviceCodeRequest(
      polled, store: store, task: signIn, route: poll)
    XCTAssertEqual(result, .completed)
    guard result == .completed else { return }
    XCTAssertEqual(store.deviceCodeSignIn, .awaitingApproval(code: "ABCD1"))
    XCTAssertEqual(store.state, .authenticating)
    fixtures.release(poll)
    await signIn.value
    guard case .signedIn(let account) = store.state else {
      return XCTFail("expected signedIn, got \(store.state)")
    }
    XCTAssertEqual(account.username, "moviebuff")
    XCTAssertNil(store.deviceCodeSignIn)
    XCTAssertEqual(try tokenStore.read(), "device-token")
    XCTAssertEqual(fixtures.requestCount(route: poll), 1)
    let accountRequest = try XCTUnwrap(
      fixtures.requests.last { $0.url?.path == "/v2/account/info" })
    XCTAssertEqual(accountRequest.value(forHTTPHeaderField: "Authorization"), "token device-token")
  }

  func testExpiredDeviceCodeStaysAuthenticatingUntilANewCodeIsRequested() async throws {
    stubSignedInRoutes()
    stubDeviceCodeIssue(["OLD01", "NEW02"])
    fixtures.fixtures["GET /v2/oauth2/oob/code/OLD01"] = (404, Self.expiredCode)
    let renewedPoll = "GET /v2/oauth2/oob/code/NEW02"
    fixtures.fixtures[renewedPoll] = (200, Self.approvedCode)
    let (store, _) = makeStore(token: nil)
    await store.signInWithDeviceCode()
    XCTAssertEqual(store.state, .authenticating)
    XCTAssertEqual(store.deviceCodeSignIn, .expired(code: "OLD01"))
    XCTAssertThrowsError(try store.beginSignIn())

    fixtures.gate(renewedPoll)
    let polled = expectRequest(renewedPoll)
    let renewal = Task { await store.signInWithDeviceCode() }
    let result = await waitForDeviceCodeRequest(
      polled, store: store, task: renewal, route: renewedPoll)
    XCTAssertEqual(result, .completed)
    guard result == .completed else { return }
    XCTAssertEqual(store.deviceCodeSignIn, .awaitingApproval(code: "NEW02"))
    fixtures.release(renewedPoll)
    await renewal.value
    guard case .signedIn = store.state else {
      return XCTFail("expected signedIn after the renewed code, got \(store.state)")
    }
    XCTAssertEqual(fixtures.requestCount(route: "GET /v2/oauth2/oob/code"), 2)
    XCTAssertEqual(fixtures.requestCount(route: "GET /v2/oauth2/oob/code/OLD01"), 1)
  }

  func testCancellingDeviceCodeSignInStopsPollingAndReturnsSignedOut() async throws {
    stubDeviceCodeIssue(["WAIT1"])
    fixtures.fixtures["GET /v2/oauth2/oob/code/WAIT1"] = (200, Self.pendingCode)
    let polled = expectRequest("GET /v2/oauth2/oob/code/WAIT1")
    let (store, tokenStore) = makeStore(token: nil)
    let signIn = Task { await store.signInWithDeviceCode() }
    let result = await waitForDeviceCodeRequest(
      polled, store: store, task: signIn, route: "GET /v2/oauth2/oob/code/WAIT1")
    XCTAssertEqual(result, .completed)
    guard result == .completed else { return }
    XCTAssertEqual(store.deviceCodeSignIn, .awaitingApproval(code: "WAIT1"))
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
    let polled = expectRequest(route)
    let (store, tokenStore) = makeStore(token: nil)
    let signIn = Task { await store.signInWithDeviceCode() }
    let result = await waitForDeviceCodeRequest(
      polled, store: store, task: signIn, route: route)
    XCTAssertEqual(result, .completed)
    guard result == .completed else { return }
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
