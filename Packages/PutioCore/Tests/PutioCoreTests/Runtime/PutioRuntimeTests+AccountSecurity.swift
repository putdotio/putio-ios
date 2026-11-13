import Foundation
import XCTest

@testable import PutioCore

extension PutioRuntimeTests {
  func testAuthorizedAppsFlagTheCurrentClientAndRejectDuplicates() async throws {
    let (runtime, _) = await makeSignedInRuntime()
    fixtures.setFixture(
      """
      {"apps":[{"id":44,"name":"","description":""},
               {"id":42,"name":"Living Room TV","description":"Apple TV","has_icon":true},
               {"id":3001,"name":"put.io iOS","description":"This app","has_icon":true},
               {"id":45,"name":"Kodi","description":""},
               {"id":46,"name":"Plex","description":""}]}
      """, for: "GET /v2/oauth/grants")
    fixtures.setFixture(
      """
      {"status":"OK","clients":[
        {"id":1,"app_id":42,"last_used_at":"2026-11-01T10:00:00","active":false},
        {"id":2,"app_id":42,"last_used_at":"2026-11-09T18:30:00","active":false},
        {"id":3,"app_id":3001,"last_used_at":"2026-11-12T09:00:00","active":true},
        {"id":4,"app_id":44,"app_name":"Infuse","last_used_at":"2026-10-30T12:00:00"},
        {"id":5,"app_id":46,"last_used_at":"2026-11-10T08:00:00","active":true}]}
      """, for: "GET /v2/oauth/clients")
    let apps = try await runtime.listAuthorizedApps()
    let used = { (value: String) in PutioAccountSnapshot.timestamp(value) }
    XCTAssertEqual(
      apps,
      [
        PutioAuthorizedApp(
          id: 3001, name: "put.io iOS", lastUsedAt: used("2026-11-12T09:00:00"), hasIcon: true,
          isCurrentClient: true),
        PutioAuthorizedApp(
          id: 46, name: "Plex", lastUsedAt: used("2026-11-10T08:00:00"), isCurrentClient: false),
        PutioAuthorizedApp(
          id: 42, name: "Living Room TV", lastUsedAt: used("2026-11-09T18:30:00"), hasIcon: true,
          isCurrentClient: false),
        PutioAuthorizedApp(
          id: 44, name: "Infuse", lastUsedAt: used("2026-10-30T12:00:00"), isCurrentClient: false),
        PutioAuthorizedApp(id: 45, name: "Kodi", isCurrentClient: false),
      ])
    XCTAssertEqual(
      fixtures.capturedRequests().suffix(2).compactMap(\.url?.path),
      ["/v2/oauth/grants", "/v2/oauth/clients"])

    fixtures.setFixture(
      #"{"status":"ERROR","error_type":"Unavailable","message":"no"}"#, statusCode: 503,
      for: "GET /v2/oauth/clients")
    let withoutSessions = try await runtime.listAuthorizedApps()
    XCTAssertEqual(withoutSessions.map(\.id), [3001, 44, 45, 42, 46])
    XCTAssertTrue(withoutSessions.allSatisfy { $0.lastUsedAt == nil })
    XCTAssertEqual(withoutSessions.first { $0.id == 44 }?.name, "")

    fixtures.setFixture("PNGDATA", for: "GET /v2/oauth/apps/42/icon")
    let icon = try await runtime.authorizedAppIcon(id: 42)
    XCTAssertEqual(icon, Data("PNGDATA".utf8))
    await assertRuntimeError(.invalidResponse) { _ = try await runtime.authorizedAppIcon(id: 0) }

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
      PutioAuthorizedApp(id: 77, name: "Apple TV", isCurrentClient: false))
    let request = try XCTUnwrap(fixtures.capturedRequests().last)
    let body = try JSONSerialization.jsonObject(with: try XCTUnwrap(requestBodyData(for: request)))
    XCTAssertEqual(body as? [String: String], ["code": "ABCD"])
  }

  func testClearDataSendsEveryFlagAndReloadsALostResponse() async throws {
    let (runtime, _) = await makeSignedInRuntime()
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
