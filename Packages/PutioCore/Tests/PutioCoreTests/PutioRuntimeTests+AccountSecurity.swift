import Foundation
import XCTest

@testable import PutioCore

extension PutioRuntimeTests {
  func testAuthorizedAppsFlagTheCurrentClientAndRejectDuplicates() async throws {
    let (runtime, _) = await makeSignedInRuntime()
    fixtures.setFixture(
      """
      {"apps":[{"id":3001,"name":"put.io iOS","description":"This app"},
               {"id":42,"name":"Living Room TV","description":"Apple TV","website":"https://put.io"}]}
      """, for: "GET /v2/oauth/grants")
    let apps = try await runtime.listAuthorizedApps()
    XCTAssertEqual(
      apps,
      [
        PutioAuthorizedApp(
          id: 3001, name: "put.io iOS", description: "This app", isCurrentClient: true),
        PutioAuthorizedApp(
          id: 42, name: "Living Room TV", description: "Apple TV", isCurrentClient: false),
      ])
    fixtures.setFixture(
      #"{"apps":[{"id":42,"name":"A","description":""},{"id":42,"name":"B","description":""}]}"#,
      for: "GET /v2/oauth/grants")
    await assertRuntimeError(.invalidResponse) { _ = try await runtime.listAuthorizedApps() }

    fixtures.setFixture(#"{"status":"OK"}"#, for: "POST /v2/oauth/grants/42/delete")
    try await runtime.revokeAuthorizedApp(id: 42)
    XCTAssertEqual(
      fixtures.capturedRequests().last?.url?.path, "/v2/oauth/grants/42/delete")
    await assertRuntimeError(.invalidResponse) { try await runtime.revokeAuthorizedApp(id: 0) }
  }

  func testLinkDeviceMapsCodeRejectionsAndKeepsSession() async throws {
    let (runtime, _) = await makeSignedInRuntime()
    let route = "POST /v2/oauth2/oob/code"
    fixtures.setFixture(
      #"{"status":"ERROR","error_type":"code_not_found","message":"no"}"#, statusCode: 400,
      for: route)
    await assertSecurityError(.invalidDeviceCode) { _ = try await runtime.linkDevice(code: "ABCD") }
    await assertSecurityError(.invalidDeviceCode) { _ = try await runtime.linkDevice(code: "  ") }
    guard case .signedIn = runtime.session.state else { return XCTFail("rejection ended session") }
    fixtures.setFixture(
      #"{"app":{"id":77,"name":"Apple TV","description":"Living room"}}"#, for: route)
    let app = try await runtime.linkDevice(code: " ABCD ")
    XCTAssertEqual(
      app,
      PutioAuthorizedApp(
        id: 77, name: "Apple TV", description: "Living room", isCurrentClient: false))
    let request = try XCTUnwrap(fixtures.capturedRequests().last)
    let body = try JSONSerialization.jsonObject(with: try XCTUnwrap(requestBodyData(for: request)))
    XCTAssertEqual(body as? [String: String], ["code": "ABCD"])
  }

  func testTwoFactorEnrollmentAcknowledgesTheFlagAndMapsInvalidCodes() async throws {
    let (runtime, _) = await makeSignedInRuntime()
    fixtures.setFixture(
      #"{"secret":" JBSWY3DP ","uri":"otpauth://x","recovery_codes":{"created_at":"","codes":[]}}"#,
      for: "POST /v2/two_factor/generate/totp")
    let secret = try await runtime.generateTwoFactorSecret()
    XCTAssertEqual(secret, "JBSWY3DP")

    let settings = "POST /v2/account/settings"
    fixtures.setFixture(
      #"{"status":"ERROR","error_type":"invalid_code","message":"bad"}"#, statusCode: 400,
      for: settings)
    await assertSecurityError(.invalidTwoFactorCode) {
      _ = try await runtime.setTwoFactorEnabled(true, code: "000000")
    }
    guard case .signedIn(let before) = runtime.session.state else { return XCTFail("signed out") }
    XCTAssertFalse(before.twoFactorEnabled)
    XCTAssertFalse(runtime.session.isUpdatingAccountPreferences)

    fixtures.setFixture(#"{"status":"OK"}"#, for: settings)
    fixtures.setFixture(
      Self.accountInfo.replacingOccurrences(
        of: "\"two_factor_enabled\": false", with: "\"two_factor_enabled\": true"),
      for: "GET /v2/account/info")
    let result = try await runtime.setTwoFactorEnabled(true, code: "123456")
    XCTAssertTrue(result.accountRefreshed)
    guard case .signedIn(let after) = runtime.session.state else { return XCTFail("signed out") }
    XCTAssertTrue(after.twoFactorEnabled)
    let request = try XCTUnwrap(
      fixtures.capturedRequests().last { $0.url?.path == "/v2/account/settings" })
    let body = try XCTUnwrap(
      JSONSerialization.jsonObject(with: try XCTUnwrap(requestBodyData(for: request)))
        as? [String: [String: Any]])
    XCTAssertEqual(body["two_factor_enabled"]?["code"] as? String, "123456")
    XCTAssertEqual(body["two_factor_enabled"]?["enable"] as? Bool, true)

    fixtures.setFixture(
      #"{"recovery_codes":{"created_at":"2026-09-01","codes":[{"code":"aaaa-1111","used_at":null},{"code":"bbbb-2222","used_at":"2026-09-02"}]}}"#,
      for: "GET /v2/two_factor/recovery_codes")
    let codes = try await runtime.recoveryCodes()
    XCTAssertEqual(
      codes,
      [
        PutioTwoFactorRecoveryCode(code: "aaaa-1111", isUsed: false),
        PutioTwoFactorRecoveryCode(code: "bbbb-2222", isUsed: true),
      ])
    fixtures.setFixture(
      #"{"recovery_codes":{"created_at":"","codes":[]}}"#,
      for: "POST /v2/two_factor/recovery_codes/refresh")
    await assertRuntimeError(.invalidResponse) { _ = try await runtime.regenerateRecoveryCodes() }
    for payload in [
      #"[{"code":"dup","used_at":null},{"code":"dup","used_at":null}]"#,
      #"[{"code":"ok","used_at":null},{"code":"  ","used_at":null}]"#,
    ] {
      fixtures.setFixture(
        #"{"recovery_codes":{"created_at":"","codes":\#(payload)}}"#,
        for: "GET /v2/two_factor/recovery_codes")
      await assertRuntimeError(.invalidResponse) { _ = try await runtime.recoveryCodes() }
    }
  }

  func testLostTwoFactorResponseReconcilesAgainstTheAccountBeforeFailing() async throws {
    let (runtime, _) = await makeSignedInRuntime()
    let settings = "POST /v2/account/settings"
    fixtures.setFixture(#"{"status":"ERROR"}"#, statusCode: 503, for: settings)
    await assertRuntimeError(.transient) {
      _ = try await runtime.setTwoFactorEnabled(true, code: "123456")
    }
    XCTAssertFalse(runtime.session.isUpdatingAccountPreferences)
    fixtures.setFixture(
      Self.accountInfo.replacingOccurrences(
        of: "\"two_factor_enabled\": false", with: "\"two_factor_enabled\": true"),
      for: "GET /v2/account/info")
    let result = try await runtime.setTwoFactorEnabled(true, code: "123456")
    XCTAssertTrue(
      result.accountRefreshed, "a committed write with a lost response was not reconciled")
    guard case .signedIn(let account) = runtime.session.state else { return XCTFail("signed out") }
    XCTAssertTrue(account.twoFactorEnabled)
    XCTAssertFalse(runtime.session.isAccountPreferencesStale)
    // A retry of a committed write can only fail as a stale code.
    fixtures.setFixture(
      #"{"status":"ERROR","error_type":"invalid_code","message":"stale"}"#, statusCode: 400,
      for: settings)
    let retried = try await runtime.setTwoFactorEnabled(true, code: "654321")
    XCTAssertTrue(
      retried.accountRefreshed, "a stale code after a committed write was not reconciled")
    await assertSecurityError(.invalidTwoFactorCode) {
      _ = try await runtime.setTwoFactorEnabled(false, code: "000000")
    }
  }

  func testClearDataSendsEveryFlagAndDestroyEndsTheSessionWithoutRevocation() async throws {
    let (runtime, tokenStore) = await makeSignedInRuntime()
    fixtures.setFixture(
      #"{"status":"ERROR"}"#, statusCode: 503, for: "POST /v2/account/clear")
    await assertRuntimeError(.transient) { _ = try await runtime.clearAccountData([.files]) }
    XCTAssertTrue(
      fixtures.capturedRequests().suffix(1).allSatisfy {
        $0.url?.path == "/v2/account/info"
      }, "a lost clear response did not reload the account")
    fixtures.setFixture(#"{"status":"OK"}"#, for: "POST /v2/account/clear")
    await assertRuntimeError(.invalidResponse) { _ = try await runtime.clearAccountData([]) }
    let refreshed = try await runtime.clearAccountData([.history, .trash])
    XCTAssertTrue(refreshed)
    let clear = try XCTUnwrap(
      fixtures.capturedRequests().last { $0.url?.path == "/v2/account/clear" })
    let body = try XCTUnwrap(
      JSONSerialization.jsonObject(with: try XCTUnwrap(requestBodyData(for: clear)))
        as? [String: Bool])
    XCTAssertEqual(
      body,
      [
        "files": false, "finished_transfers": false, "active_transfers": false, "rss_feeds": false,
        "rss_logs": false, "history": true, "trash": true, "friends": false,
      ])

    let destroy = "POST /v2/account/destroy"
    fixtures.setFixture(
      #"{"status":"ERROR","error_type":"INVALID_CURRENT_PASSWORD","message":"no"}"#,
      statusCode: 400, for: destroy)
    await assertSecurityError(.invalidPassword) { try await runtime.destroyAccount(password: "x") }
    await assertSecurityError(.invalidPassword) {
      try await runtime.destroyAccount(password: " \n")
    }
    guard case .signedIn = runtime.session.state else { return XCTFail("rejection ended session") }
    fixtures.setFixture(#"{"status":"OK"}"#, for: destroy)
    try await runtime.destroyAccount(password: " correct ")
    let sent = try XCTUnwrap(
      fixtures.capturedRequests().last { $0.url?.path == "/v2/account/destroy" })
    XCTAssertEqual(
      try JSONSerialization.jsonObject(with: try XCTUnwrap(requestBodyData(for: sent)))
        as? [String: String], ["current_password": " correct "],
      "the password was not sent as typed")
    XCTAssertEqual(runtime.session.state, .signedOut(.userSignedOut))
    XCTAssertNil(try tokenStore.read())
    XCTAssertFalse(
      fixtures.capturedRequests().contains {
        $0.url?.path == "/v2/oauth/grants/logout"
      })
    await assertRuntimeError(.authenticationRequired) { _ = try await runtime.listAuthorizedApps() }
  }

  func testLostDestroyResponseEndsTheSessionOnlyWhenTheCredentialIsDead() async throws {
    let (runtime, tokenStore) = await makeSignedInRuntime()
    let destroy = "POST /v2/account/destroy"
    fixtures.setFixture(#"{"status":"ERROR"}"#, statusCode: 503, for: destroy)
    await assertRuntimeError(.transient) { try await runtime.destroyAccount(password: "pw") }
    guard case .signedIn = runtime.session.state else {
      return XCTFail("a live credential ended the session")
    }
    fixtures.setFixture(
      #"{"status":"ERROR","error_type":"invalid_grant"}"#, statusCode: 401,
      for: "GET /v2/account/info")
    try await runtime.destroyAccount(password: "pw")
    XCTAssertEqual(runtime.session.state, .signedOut(.userSignedOut))
    XCTAssertNil(try tokenStore.read())
  }

  func testLostDestroyResponseCannotEndANewerSession() async throws {
    let (runtime, tokenStore) = await makeSignedInRuntime()
    let accountRoute = "GET /v2/account/info"
    fixtures.setFixture(
      #"{"status":"ERROR"}"#, statusCode: 503, for: "POST /v2/account/destroy")
    fixtures.gateFixture(
      #"{"status":"ERROR","error_type":"invalid_grant"}"#, statusCode: 401,
      for: accountRoute)
    let destruction = Task { try await runtime.destroyAccount(password: "pw") }
    defer {
      fixtures.releaseFixture(for: accountRoute)
      destruction.cancel()
    }
    guard await waitForRequest(accountRoute, count: 2) else {
      return XCTFail("credential validation did not start")
    }

    await runtime.session.signOut()
    fixtures.setFixture(Self.accountInfo, for: accountRoute)
    let request = try runtime.session.beginSignIn()
    let state = try XCTUnwrap(oauthState(from: request.url))
    let callback = try XCTUnwrap(
      URL(string: "putio://auth#access_token=fresh-token&state=\(state)"))
    await runtime.session.completeSignIn(callbackURL: callback)
    guard case .signedIn = runtime.session.state else {
      return XCTFail("fresh session did not sign in")
    }
    let generation = runtime.session.authenticationGeneration

    fixtures.releaseFixture(for: accountRoute)
    await assertRuntimeError(.transient) { try await destruction.value }
    guard case .signedIn = runtime.session.state else {
      return XCTFail("old credential validation ended the fresh session")
    }
    XCTAssertEqual(runtime.session.authenticationGeneration, generation)
    XCTAssertEqual(try tokenStore.read(), "fresh-token")
  }

  private func assertSecurityError(
    _ expected: PutioAccountSecurityError, file: StaticString = #filePath, line: UInt = #line,
    operation: () async throws -> Void
  ) async {
    do {
      try await operation()
      XCTFail("expected \(expected)", file: file, line: line)
    } catch let error as PutioAccountSecurityError {
      XCTAssertEqual(error, expected, file: file, line: line)
    } catch {
      XCTFail("expected \(expected), got \(error)", file: file, line: line)
    }
  }
}
