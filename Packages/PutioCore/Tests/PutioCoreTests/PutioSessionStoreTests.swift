import PutioSDK
import XCTest

@testable import PutioCore

final class SessionMockURLProtocol: URLProtocol {
  nonisolated(unsafe) static var fixtures: [String: (Int, String)] = [:]
  nonisolated(unsafe) static var networkFailureRoutes: Set<String> = []

  static func reset() {
    fixtures = [:]
    networkFailureRoutes = []
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
    let routeKey = "\(request.httpMethod ?? "GET") \(url.path)"
    if Self.networkFailureRoutes.contains(routeKey) {
      client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
      return
    }
    let (statusCode, body) =
      Self.fixtures[routeKey]
      ?? (404, #"{"status":"ERROR","status_code":404,"error_type":"FIXTURE_NOT_FOUND"}"#)
    let response = HTTPURLResponse(
      url: url,
      statusCode: statusCode,
      httpVersion: nil,
      headerFields: ["Content-Type": "application/json"]
    )!
    client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
    client?.urlProtocol(self, didLoad: Data(body.utf8))
    client?.urlProtocolDidFinishLoading(self)
  }

  override func stopLoading() {}
}

@MainActor
final class PutioSessionStoreTests: XCTestCase {
  private static let validValidation =
    #"{"result": true, "token_id": 1, "token_scope": "default", "user_id": 1001}"#
  private static let rejectedValidation = #"{"result": false}"#
  private static func accountInfo(
    rememberVideoTime: Bool,
    suggestNextVideo: Bool = true
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
  }

  override func setUp() {
    super.setUp()
    SessionMockURLProtocol.reset()
  }

  private func makeStore(token: String?) -> (PutioSessionStore, PutioInMemoryTokenStore) {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [SessionMockURLProtocol.self]
    let sdk = PutioSDK(
      config: PutioSDKConfig(clientID: "3001", clientName: "tests"),
      urlSession: URLSession(configuration: configuration)
    )
    let tokenStore = PutioInMemoryTokenStore(token: token)
    return (PutioSessionStore(sdk: sdk, tokenStore: tokenStore), tokenStore)
  }

  private func stubSignedInRoutes() {
    SessionMockURLProtocol.fixtures["GET /v2/oauth2/validate"] = (200, Self.validValidation)
    SessionMockURLProtocol.fixtures["GET /v2/account/info"] = (
      200,
      Self.accountInfo(rememberVideoTime: true)
    )
    SessionMockURLProtocol.fixtures["POST /v2/oauth/grants/logout"] = (200, #"{"status":"OK"}"#)
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
        storage: PutioAccountSnapshot.Storage(
          availableBytes: 10,
          totalBytes: 30,
          usedBytes: 20
        )
      )
    )
  }

  func testRestoreMapsDisabledRememberVideoTimeSetting() async {
    SessionMockURLProtocol.fixtures["GET /v2/oauth2/validate"] = (200, Self.validValidation)
    SessionMockURLProtocol.fixtures["GET /v2/account/info"] = (
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

  func testRestoreMapsDisabledNextVideoSetting() async {
    SessionMockURLProtocol.fixtures["GET /v2/oauth2/validate"] = (200, Self.validValidation)
    SessionMockURLProtocol.fixtures["GET /v2/account/info"] = (
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
    SessionMockURLProtocol.fixtures["GET /v2/oauth2/validate"] = (200, Self.rejectedValidation)
    let (store, tokenStore) = makeStore(token: "revoked-token")
    await store.restore()
    XCTAssertEqual(store.state, .signedOut(.sessionExpired))
    XCTAssertNil(try tokenStore.read())
  }

  func testRestoreWithUnauthorizedResponseClearsAndExpires() async {
    SessionMockURLProtocol.fixtures["GET /v2/oauth2/validate"] = (
      401, #"{"status":"ERROR","status_code":401,"error_type":"invalid_grant"}"#
    )
    let (store, tokenStore) = makeStore(token: "revoked-token")
    await store.restore()
    XCTAssertEqual(store.state, .signedOut(.sessionExpired))
    XCTAssertNil(try tokenStore.read())
  }

  func testRestoreNetworkFailureKeepsTokenForRetry() async {
    SessionMockURLProtocol.networkFailureRoutes.insert("GET /v2/oauth2/validate")
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

  private func oauthState(from url: URL) -> String? {
    URLComponents(url: url, resolvingAgainstBaseURL: false)?
      .queryItems?
      .first(where: { $0.name == "state" })?
      .value
  }
}
