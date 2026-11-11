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
    trashSize: Int64 = 0,
    accountStatus: String? = nil,
    accountActive: Bool = true,
    isSubAccount: Bool = false,
    filesWillBeDeletedAt: String = ""
  ) -> String {
    let status = accountStatus.map { #""account_status": "\#($0)","# } ?? ""
    return """
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
        \(status)
        "account_active": \(accountActive),
        "is_sub_account": \(isSubAccount),
        "files_will_be_deleted_at": "\(filesWillBeDeletedAt)",
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
    tokenStore: PutioTokenStore,
    signOutIntentStore: PutioSignOutIntentStore = PutioInMemorySignOutIntentStore(),
    supportIdentityPlatform: String? = nil
  ) -> (PutioSessionStore, PutioSDK) {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [SessionMockURLProtocol.self]
    SessionMockURLProtocol.registry.configure(configuration, fixture: fixtures)
    let sdk = PutioSDK(
      config: PutioSDKConfig(clientID: "3001", clientName: "tests"),
      urlSession: URLSession(configuration: configuration)
    )
    return (
      PutioSessionStore(
        sdk: sdk, tokenStore: tokenStore, signOutIntentStore: signOutIntentStore,
        supportIdentityPlatform: supportIdentityPlatform),
      sdk
    )
  }

  private func stubSignedInRoutes() {
    fixtures.fixtures["GET /v2/oauth2/validate"] = (200, Self.validValidation)
    fixtures.fixtures["GET /v2/account/info"] = (
      200,
      Self.accountInfo(rememberVideoTime: true)
    )
    fixtures.fixtures["POST /v2/oauth/grants/logout"] = (200, #"{"status":"OK"}"#)
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

  func testAccountStatusSubAccountAndDeletionDateMapIntoTheSnapshot() async {
    let account = await restoredAccount(
      Self.accountInfo(
        rememberVideoTime: true, accountStatus: "inactive", accountActive: false,
        isSubAccount: true, filesWillBeDeletedAt: "2026-10-15T08:00:00"))
    XCTAssertEqual(account?.status, .inactive)
    XCTAssertEqual(account?.isSubAccount, true)
    XCTAssertEqual(
      account?.filesDeletionDate, ISO8601DateFormatter().date(from: "2026-10-15T08:00:00Z"))
  }

  func testAccountStatusWinsOverTheActiveFlag() async {
    let inactive = await restoredAccount(
      Self.accountInfo(rememberVideoTime: true, accountStatus: "inactive", accountActive: true))
    XCTAssertEqual(inactive?.status, .inactive)
    let stranger = await restoredAccount(
      Self.accountInfo(rememberVideoTime: true, accountStatus: "stranger", accountActive: false))
    XCTAssertEqual(stranger?.status, .stranger)
  }

  func testMissingAccountStatusFallsBackToTheActiveFlag() async {
    let inactive = await restoredAccount(
      Self.accountInfo(rememberVideoTime: true, accountActive: false))
    XCTAssertEqual(inactive?.status, .inactive)
    let active = await restoredAccount(
      Self.accountInfo(rememberVideoTime: true, accountActive: true))
    XCTAssertEqual(active?.status, .active)
  }

  func testUnusableDeletionDateMapsToNoDate() async {
    let account = await restoredAccount(
      Self.accountInfo(
        rememberVideoTime: true, accountStatus: "inactive", filesWillBeDeletedAt: "soon"))
    XCTAssertEqual(account?.status, .inactive)
    XCTAssertNil(account?.filesDeletionDate)
  }

  func testRenewalClearsTheInactiveStatusOnTheNextRefresh() async {
    fixtures.fixtures["GET /v2/oauth2/validate"] = (200, Self.validValidation)
    fixtures.fixtures["GET /v2/account/info"] = (
      200,
      Self.accountInfo(
        rememberVideoTime: true, accountStatus: "inactive", accountActive: false,
        filesWillBeDeletedAt: "2026-10-15T08:00:00")
    )
    let (store, _) = makeStore(token: "stored-token")
    await store.restore()
    guard case .signedIn(let inactive) = store.state else {
      return XCTFail("expected signedIn, got \(store.state)")
    }
    XCTAssertNotNil(PutioInactiveAccountNotice(account: inactive))

    fixtures.fixtures["GET /v2/account/info"] = (
      200, Self.accountInfo(rememberVideoTime: true, accountStatus: "active")
    )
    let refreshed = await store.refreshAccount()

    XCTAssertTrue(refreshed)
    guard case .signedIn(let renewed) = store.state else {
      return XCTFail("expected signedIn, got \(store.state)")
    }
    XCTAssertEqual(renewed.status, .active)
    XCTAssertNil(PutioInactiveAccountNotice(account: renewed))
  }

  func testAccountStatusSurvivesPreferenceAcknowledgement() async {
    fixtures.fixtures["GET /v2/oauth2/validate"] = (200, Self.validValidation)
    fixtures.fixtures["GET /v2/account/info"] = (
      200,
      Self.accountInfo(
        rememberVideoTime: true, accountStatus: "inactive", isSubAccount: true,
        filesWillBeDeletedAt: "2026-10-15T08:00:00Z")
    )
    let (store, _) = makeStore(token: "stored-token")
    await store.restore()
    store.applyAcknowledgedPreferences(hideSubtitles: true)

    guard case .signedIn(let account) = store.state else {
      return XCTFail("expected signedIn, got \(store.state)")
    }
    XCTAssertEqual(account.status, .inactive)
    XCTAssertTrue(account.isSubAccount)
    XCTAssertNotNil(account.filesDeletionDate)
  }

  private func restoredAccount(_ info: String) async -> PutioAccountSnapshot? {
    fixtures.fixtures["GET /v2/oauth2/validate"] = (200, Self.validValidation)
    fixtures.fixtures["GET /v2/account/info"] = (200, info)
    let (store, _) = makeStore(token: "stored-token")
    await store.restore()
    guard case .signedIn(let account) = store.state else {
      XCTFail("expected signedIn, got \(store.state)")
      return nil
    }
    return account
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

  func testOfflineRestoreFailsTheSessionCheckAndRetriesWithTheSavedToken() async throws {
    stubSignedInRoutes()
    fixtures.networkFailureRoutes.insert("GET /v2/oauth2/validate")
    let (store, tokenStore) = makeStore(token: "stored-token")
    await store.restore()
    XCTAssertEqual(store.state, Self.sessionCheckFailed)
    XCTAssertEqual(try tokenStore.read(), "stored-token")
    XCTAssertThrowsError(try store.beginSignIn())

    fixtures.networkFailureRoutes = []
    await store.restore()
    guard case .signedIn = store.state else {
      return XCTFail("the saved token must restore once the fault clears, got \(store.state)")
    }
    let validation = try XCTUnwrap(fixtures.requests.last { $0.url?.path == "/v2/oauth2/validate" })
    XCTAssertEqual(
      validation.value(forHTTPHeaderField: "Authorization")?.lowercased(), "token stored-token")
  }

  func testAuthenticationRejectionDuringTheAccountCheckStillExpires() async {
    stubSignedInRoutes()
    fixtures.fixtures["GET /v2/account/info"] = (
      401, #"{"status":"ERROR","status_code":401,"error_type":"invalid_grant"}"#
    )
    let (store, tokenStore) = makeStore(token: "stored-token")
    await store.restore()
    XCTAssertEqual(store.state, .signedOut(.sessionExpired))
    XCTAssertNil(try tokenStore.read())
  }

  private static let keychainUnavailable =
    PutioSignedOutReason.authenticationFailed("This device's keychain is unavailable. Try again.")
  private static let secureStorageFailed = PutioSessionState.signedOut(
    .restoreFailed(.secureStorage, message: "This device's keychain is unavailable. Try again."))
  private static let sessionCheckFailed = PutioSessionState.signedOut(
    .restoreFailed(
      .sessionCheck, message: "put.io is unreachable. Check your connection and try again."))

  func testUnreadableStoredTokenFailsRestoreAndKeepsItForRetry() async {
    stubSignedInRoutes()
    let tokenStore = KeychainFailureTokenStore(token: "stored-token", failingReads: true)
    let (store, sdk) = makeStore(tokenStore: tokenStore)

    await store.restore()

    XCTAssertEqual(store.state, Self.secureStorageFailed)
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

  func testDiscardingACredentialTheSessionCheckFailedRemovesItWithoutRevoking() async throws {
    stubSignedInRoutes()
    fixtures.networkFailureRoutes = ["GET /v2/oauth2/validate"]
    let (store, tokenStore) = makeStore(token: "stored-token")
    await store.restore()
    XCTAssertEqual(store.state, Self.sessionCheckFailed)

    store.discardUnrestoredCredential()

    XCTAssertEqual(store.state, .signedOut(nil))
    XCTAssertNil(try tokenStore.read())
    XCTAssertEqual(fixtures.requestCount(route: "POST /v2/oauth/grants/logout"), 0)
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

    XCTAssertEqual(store.state, Self.secureStorageFailed)
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

  func testSignInBootstrapFailureKeepsTheSavedGrantForRestore() async throws {
    stubSignedInRoutes()
    fixtures.networkFailureRoutes = ["GET /v2/account/info"]
    let (store, tokenStore) = makeStore(token: nil)

    let request = try store.beginSignIn()
    let oauthState = try XCTUnwrap(oauthState(from: request.url))
    let callback = try XCTUnwrap(
      URL(string: "putio://auth#access_token=fresh-token&state=\(oauthState)")
    )
    await store.completeSignIn(callbackURL: callback)

    // A fresh sign-in would overwrite the saved grant and leave it live on put.io.
    XCTAssertEqual(store.state, Self.sessionCheckFailed)
    XCTAssertEqual(try tokenStore.read(), "fresh-token")
    XCTAssertThrowsError(try store.beginSignIn()) { error in
      XCTAssertEqual(error as? PutioSessionOperationError, .signInUnavailable)
    }

    fixtures.networkFailureRoutes = []
    await store.restore()
    guard case .signedIn = store.state else {
      return XCTFail("expected signedIn, got \(store.state)")
    }
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

  func testSupportIdentityComesFromThePlatformHashAndEndsWithTheSession() async throws {
    stubSignedInRoutes()
    let (unasked, _) = makeStore(
      tokenStore: PutioInMemoryTokenStore(token: "stored-token"))
    await unasked.restore()
    XCTAssertNil(unasked.supportIdentity, "a runtime that did not ask must not log anyone in")
    let unaskedQuery = try XCTUnwrap(fixtures.requests.last?.url?.query)
    XCTAssertFalse(unaskedQuery.contains("intercom"), unaskedQuery)

    let (store, _) = makeStore(
      tokenStore: PutioInMemoryTokenStore(token: "stored-token"), supportIdentityPlatform: "ios")
    await store.restore()
    let query = try XCTUnwrap(fixtures.requests.last?.url?.query)
    XCTAssertTrue(query.contains("intercom=1") && query.contains("platform=ios"), query)
    XCTAssertEqual(store.supportIdentity, PutioSupportIdentity(userID: "1001", userHash: "hash"))
    XCTAssertFalse(String(reflecting: store.supportIdentity).contains("\"hash\""))

    await store.signOut()
    XCTAssertNil(store.supportIdentity)
  }

  func testSignOutClearsSessionState() async {
    stubSignedInRoutes()
    let (store, tokenStore) = makeStore(token: "stored-token")
    await store.restore()

    await store.signOut()

    XCTAssertEqual(store.state, .signedOut(.userSignedOut))
    XCTAssertNil(try tokenStore.read())
  }

  func testSignOutPersistsItsIntentBeforeCleanupStarts() async {
    stubSignedInRoutes()
    let intent = PutioInMemorySignOutIntentStore()
    let (store, _) = makeStore(
      tokenStore: PutioInMemoryTokenStore(token: "stored-token"), signOutIntentStore: intent)
    await store.restore()
    let route = "POST /v2/oauth/grants/logout"
    fixtures.gate(route)
    let requested = expectRequest(route)

    let signOut = Task { await store.signOut() }
    await fulfillment(of: [requested], timeout: 5)
    XCTAssertTrue(intent.isPending)
    XCTAssertEqual(store.state, .signingOut)

    fixtures.release(route)
    await signOut.value
    XCTAssertFalse(intent.isPending)
    XCTAssertFalse(store.isSignOutCleanupPending)
  }

  func testFailedRevocationLandsSignedOutAndKeepsTheCredentialForTheNextLaunch() async throws {
    stubSignedInRoutes()
    let tokenStore = PutioInMemoryTokenStore(token: "stored-token")
    let intent = PutioInMemorySignOutIntentStore()
    let (store, sdk) = makeStore(tokenStore: tokenStore, signOutIntentStore: intent)
    await store.restore()
    fixtures.networkFailureRoutes = ["POST /v2/oauth/grants/logout"]

    await store.signOut()

    XCTAssertEqual(store.state, .signedOut(.userSignedOut))
    XCTAssertTrue(store.isSignOutCleanupPending)
    XCTAssertTrue(intent.isPending)
    XCTAssertEqual(try tokenStore.read(), "stored-token")
    XCTAssertTrue(sdk.config.token.isEmpty)

    fixtures.networkFailureRoutes = []
    let (relaunched, relaunchedSDK) = makeStore(tokenStore: tokenStore, signOutIntentStore: intent)
    XCTAssertTrue(relaunched.isSignOutCleanupPending)
    await relaunched.restore()

    XCTAssertEqual(relaunched.state, .signedOut(.userSignedOut))
    XCTAssertFalse(relaunched.isSignOutCleanupPending)
    XCTAssertFalse(intent.isPending)
    XCTAssertNil(try tokenStore.read())
    XCTAssertTrue(relaunchedSDK.config.token.isEmpty)
    XCTAssertEqual(
      fixtures.requests.last?.value(forHTTPHeaderField: "Authorization"), "token stored-token")
    XCTAssertEqual(fixtures.requestCount(route: "GET /v2/oauth2/validate"), 1)
  }

  func testFailedRemovalAndRevocationNeverRestoreTheSessionOnRelaunch() async throws {
    stubSignedInRoutes()
    let tokenStore = FailingClearTokenStore()
    let intent = PutioInMemorySignOutIntentStore()
    let (store, _) = makeStore(tokenStore: tokenStore, signOutIntentStore: intent)
    await store.restore()
    fixtures.networkFailureRoutes = ["POST /v2/oauth/grants/logout"]
    await store.signOut()
    XCTAssertEqual(store.state, .signedOut(.userSignedOut))

    let (relaunched, relaunchedSDK) = makeStore(tokenStore: tokenStore, signOutIntentStore: intent)
    await relaunched.restore()

    XCTAssertEqual(relaunched.state, .signedOut(.userSignedOut))
    XCTAssertTrue(relaunched.isSignOutCleanupPending)
    XCTAssertTrue(relaunchedSDK.config.token.isEmpty)
    XCTAssertEqual(try tokenStore.read(), "stored-token")
    XCTAssertEqual(
      fixtures.requestCount(route: "GET /v2/oauth2/validate"), 1,
      "a pending sign-out must not validate the saved credential")
    XCTAssertEqual(fixtures.requestCount(route: "GET /v2/account/info"), 1)

    fixtures.networkFailureRoutes = []
    let (stillFailing, _) = makeStore(tokenStore: tokenStore, signOutIntentStore: intent)
    await stillFailing.restore()
    XCTAssertEqual(stillFailing.state, .signedOut(.userSignedOut))
    XCTAssertTrue(intent.isPending, "the credential is still saved, so cleanup is not done")

    tokenStore.allowClear()
    let (cleaned, _) = makeStore(tokenStore: tokenStore, signOutIntentStore: intent)
    await cleaned.restore()
    XCTAssertEqual(cleaned.state, .signedOut(.userSignedOut))
    XCTAssertFalse(intent.isPending)
    XCTAssertNil(try tokenStore.read())

    let (afterCleanup, _) = makeStore(tokenStore: tokenStore, signOutIntentStore: intent)
    await afterCleanup.restore()
    XCTAssertEqual(afterCleanup.state, .signedOut(nil))
  }

  func testFailedRemovalAfterRevocationRetriesAtTheNextLaunch() async throws {
    stubSignedInRoutes()
    let tokenStore = FailingClearTokenStore()
    let intent = PutioInMemorySignOutIntentStore()
    let (store, _) = makeStore(tokenStore: tokenStore, signOutIntentStore: intent)
    await store.restore()

    await store.signOut()

    XCTAssertEqual(store.state, .signedOut(.userSignedOut))
    XCTAssertTrue(intent.isPending)
    XCTAssertEqual(try tokenStore.read(), "stored-token")

    tokenStore.allowClear()
    fixtures.fixtures["POST /v2/oauth/grants/logout"] =
      (401, #"{"status":"ERROR","error_type":"invalid_grant"}"#)
    let (relaunched, _) = makeStore(tokenStore: tokenStore, signOutIntentStore: intent)
    await relaunched.restore()
    XCTAssertEqual(relaunched.state, .signedOut(.userSignedOut))
    XCTAssertFalse(intent.isPending)
    XCTAssertNil(try tokenStore.read())
  }

  func testUnreadableCredentialKeepsAPendingSignOutQuiet() async {
    let tokenStore = KeychainFailureTokenStore(token: "stored-token", failingReads: true)
    let intent = PutioInMemorySignOutIntentStore(pending: true)
    let (store, _) = makeStore(tokenStore: tokenStore, signOutIntentStore: intent)

    await store.restore()

    XCTAssertEqual(store.state, .signedOut(.userSignedOut))
    XCTAssertTrue(intent.isPending)
    XCTAssertEqual(tokenStore.storedToken(), "stored-token")
    XCTAssertTrue(fixtures.requests.isEmpty)
  }

  func testSignInWhileASignOutIsPendingReplacesTheCredentialAndEndsTheCleanup() async throws {
    stubSignedInRoutes()
    let tokenStore = PutioInMemoryTokenStore(token: "stored-token")
    let intent = PutioInMemorySignOutIntentStore()
    let (store, _) = makeStore(tokenStore: tokenStore, signOutIntentStore: intent)
    await store.restore()
    fixtures.networkFailureRoutes = ["POST /v2/oauth/grants/logout"]
    await store.signOut()
    XCTAssertTrue(intent.isPending)

    let request = try store.beginSignIn()
    let oauthState = try XCTUnwrap(oauthState(from: request.url))
    let callback = try XCTUnwrap(
      URL(string: "putio://auth#access_token=fresh-token&state=\(oauthState)"))
    await store.completeSignIn(callbackURL: callback)

    guard case .signedIn = store.state else {
      return XCTFail("expected signedIn, got \(store.state)")
    }
    XCTAssertFalse(intent.isPending)
    XCTAssertFalse(store.isSignOutCleanupPending)
    XCTAssertEqual(try tokenStore.read(), "fresh-token")
  }

  func testUnsavedSignInKeepsTheSignOutPending() async throws {
    stubSignedInRoutes()
    let tokenStore = KeychainFailureTokenStore(token: "stored-token", failingWrites: true)
    let intent = PutioInMemorySignOutIntentStore(pending: true)
    let (store, _) = makeStore(tokenStore: tokenStore, signOutIntentStore: intent)

    let request = try store.beginSignIn()
    let oauthState = try XCTUnwrap(oauthState(from: request.url))
    let callback = try XCTUnwrap(
      URL(string: "putio://auth#access_token=fresh-token&state=\(oauthState)"))
    await store.completeSignIn(callbackURL: callback)

    XCTAssertEqual(store.state, .signedOut(Self.keychainUnavailable))
    XCTAssertTrue(intent.isPending)
    XCTAssertEqual(tokenStore.storedToken(), "stored-token")
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
