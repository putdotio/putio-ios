import Foundation
import XCTest

@testable import PutioCore

extension PutioRuntimeTests {
  func testPublicLinksCarryOnlyTheShareTokenAndReadPutioExpiries() async throws {
    let (runtime, _) = await makeSignedInRuntime()
    fixtures.setFixture(
      """
      {"status":"OK","public_shares":[
        {"id":7,"token":"a/b?é","push_token":"p7","created_at":"2026-10-04T19:36:01",
         "expiration_date":"2026-10-07T19:36:01.325208","owner":{"name":"moviebuff"},
         "user_file":{"id":70,"name":"Sintel.2010.1080p.mkv","file_type":"VIDEO"}},
        {"id":8,"token":"aB3-x_9","push_token":"p8","created_at":"2026-10-04T19:36:01",
         "expiration_date":null,"owner":{"name":"moviebuff"},
         "user_file":{"id":80,"name":"IMG_4392.HEIC","file_type":"IMAGE"}}
      ]}
      """, for: "GET /v2/public_share/list")
    let links = try await runtime.listPublicLinks()
    XCTAssertEqual(
      links.map(\.url.absoluteString),
      [
        "https://app.put.io/exclusive-access/a%2Fb%3F%C3%A9",
        "https://app.put.io/exclusive-access/aB3-x_9",
      ])
    XCTAssertFalse(links.contains { $0.url.absoluteString.contains("stored-token") })
    XCTAssertEqual(
      links.first?.expiresAt,
      ISO8601DateFormatter().date(from: "2026-10-07T19:36:01Z")?.addingTimeInterval(0.325208))
    XCTAssertNil(links.last?.expiresAt)
    XCTAssertEqual(links.map(\.kind), [.video, .image])
    XCTAssertEqual(links.map(\.fileName), ["Sintel.2010.1080p.mkv", "IMG_4392.HEIC"])

    fixtures.setFixture(
      """
      {"status":"OK","public_shares":[
        {"id":7,"token":"t","push_token":"p","created_at":"","expiration_date":null,
         "owner":{"name":"m"},"user_file":{"id":70,"name":"A","file_type":"VIDEO"}},
        {"id":7,"token":"u","push_token":"p","created_at":"","expiration_date":null,
         "owner":{"name":"m"},"user_file":{"id":71,"name":"B","file_type":"VIDEO"}}
      ]}
      """, for: "GET /v2/public_share/list")
    let deduplicated = try await runtime.listPublicLinks()
    XCTAssertEqual(deduplicated.map(\.fileName), ["A"], "a repeated share id hid every link")

    fixtures.setFixture(#"{"status":"OK"}"#, for: "DELETE /v2/public_share/7")
    try await runtime.revokePublicLink(id: 7)
    let request = try XCTUnwrap(fixtures.capturedRequests().last)
    XCTAssertEqual(request.httpMethod, "DELETE")
    XCTAssertEqual(request.url?.path, "/v2/public_share/7")
    await assertRuntimeError(.invalidResponse) { try await runtime.revokePublicLink(id: 0) }
  }

  func testCreatingALinkReturnsTheShareAddressAndRefusalsKeepTheSession() async throws {
    let (runtime, _) = await makeSignedInRuntime()
    let route = "POST /v2/public_share/442"
    fixtures.setFixture(
      """
      {"status":"OK","public_share":{"id":9,"token":"8f3KxQ2mVt7","push_token":"p9",
       "created_at":"2026-11-12T10:00:00","expiration_date":null,"owner":{"name":"moviebuff"},
       "user_file":{"id":442,"name":"Blue.Lights.S04E02.mkv","file_type":"VIDEO"}}}
      """, for: route)
    let url = try await runtime.createPublicLink(fileID: PutioFileID(rawValue: 442))
    XCTAssertEqual(url.absoluteString, "https://app.put.io/exclusive-access/8f3KxQ2mVt7")
    XCTAssertEqual(fixtures.capturedRequests().last?.httpMethod, "POST")

    fixtures.setFixture(
      #"{"status":"ERROR","status_code":403,"error_type":"PUBLIC_SHARE_NOT_ALLOWED_PLAN"}"#,
      statusCode: 403, for: route)
    do {
      _ = try await runtime.createPublicLink(fileID: PutioFileID(rawValue: 442))
      XCTFail("a refused link was created")
    } catch {
      XCTAssertEqual(error as? PutioPublicLinkRefusal, .plan)
    }
    guard case .signedIn = runtime.session.state else {
      return XCTFail("a refusal signed the user out")
    }

    fixtures.setFixture(
      #"{"status":"ERROR","status_code":403,"error_type":"PUBLIC_SHARE_FOLDER_ROOT_NOT_ALLOWED"}"#,
      statusCode: 403, for: route)
    await assertRuntimeError(.unknown) {
      _ = try await runtime.createPublicLink(fileID: PutioFileID(rawValue: 442))
    }
    guard case .signedIn = runtime.session.state else {
      return XCTFail("an unknown refusal signed the user out")
    }

    fixtures.setFixture(
      """
      {"status":"OK","public_share":{"id":9,"token":"t","push_token":"p","created_at":"",
       "expiration_date":null,"owner":{"name":"m"},
       "user_file":{"id":1,"name":"Other","file_type":"VIDEO"}}}
      """, for: route)
    await assertRuntimeError(.invalidResponse) {
      _ = try await runtime.createPublicLink(fileID: PutioFileID(rawValue: 442))
    }
  }

  func testPublicLinkExpiriesAcceptOffsetsAndRejectGarbage() {
    let utc = ISO8601DateFormatter().date(from: "2026-10-07T19:36:01Z")
    XCTAssertEqual(PutioPublicLink.expiryDate("2026-10-07T19:36:01"), utc)
    XCTAssertEqual(PutioPublicLink.expiryDate("2026-10-07T21:36:01+02:00"), utc)
    XCTAssertEqual(PutioPublicLink.expiryDate("2026-10-07 19:36:01Z"), utc)
    XCTAssertNil(PutioPublicLink.expiryDate("next week"))
    XCTAssertNil(PutioPublicLink.expiryDate(""))
  }
}
