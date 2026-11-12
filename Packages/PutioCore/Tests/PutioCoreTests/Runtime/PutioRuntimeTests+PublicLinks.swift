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
    await assertRuntimeError(.invalidResponse) { _ = try await runtime.listPublicLinks() }

    fixtures.setFixture(#"{"status":"OK"}"#, for: "DELETE /v2/public_share/7")
    try await runtime.revokePublicLink(id: 7)
    let request = try XCTUnwrap(fixtures.capturedRequests().last)
    XCTAssertEqual(request.httpMethod, "DELETE")
    XCTAssertEqual(request.url?.path, "/v2/public_share/7")
    await assertRuntimeError(.invalidResponse) { try await runtime.revokePublicLink(id: 0) }
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
