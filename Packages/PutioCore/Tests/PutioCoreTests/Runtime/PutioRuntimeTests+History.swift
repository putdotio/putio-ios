import Foundation
import XCTest

@testable import PutioCore

extension PutioRuntimeTests {
  func testHistoryMapsSupportedEventsAndUsesRawPageBoundary() async throws {
    let (runtime, _) = await makeSignedInRuntime()
    fixtures.setFixture(
      Self.historyFixture(
        [
          Self.historyEvent(
            99, type: "upload", fields: #""file_name":"Movie","file_size":42,"file_id":411"#),
          Self.historyEvent(
            98, type: "file_shared",
            fields: #""file_name":"Shared","sharing_user_name":"alice","file_id":410"#),
          Self.historyEvent(
            97, type: "transfer_completed",
            fields: #""transfer_name":"Complete","transfer_size":12,"file_id":0"#),
          Self.historyEvent(
            96, type: "transfer_error",
            fields: #""transfer_name":"Failed","source":"private-source""#),
          Self.historyEvent(
            95, type: "file_from_rss_deleted_for_space", fields: #""file_name":"Old","file_size":6"#
          ),
          Self.historyEvent(94, type: "rss_filter_paused", fields: #""rss_filter_title":"Feed""#),
          Self.historyEvent(93, type: "transfer_from_rss_error", fields: #""transfer_name":"RSS""#),
          Self.historyEvent(
            92, type: "transfer_callback_error",
            fields: #""transfer_name":"Callback","message":"private-callback""#),
          Self.historyEvent(91, type: "future_event"),
        ], hasMore: true), for: "GET /v2/events/list")
    let page = try await runtime.listHistory(before: 100)
    XCTAssertEqual(page.nextBefore, 91)
    XCTAssertEqual(page.items.map(\.id), Array((92...99).reversed()))
    XCTAssertEqual(
      page.items.map(\.kind),
      [
        .upload(name: "Movie", sizeBytes: 42, fileID: PutioFileID(rawValue: 411)),
        .fileShared(name: "Shared", sharingUserName: "alice", fileID: PutioFileID(rawValue: 410)),
        .transferCompleted(name: "Complete", sizeBytes: 12, fileID: nil),
        .transferError(name: "Failed"), .fileFromRSSDeleted(name: "Old", sizeBytes: 6),
        .rssFilterPaused(title: "Feed"), .transferFromRSSError(name: "RSS"),
        .transferCallbackError(name: "Callback"),
      ])
    XCTAssertEqual(page.items.first?.fileID, PutioFileID(rawValue: 411))
    XCTAssertNil(page.items[2].fileID)
    XCTAssertFalse(String(reflecting: page).contains("private-"))
    let request = try XCTUnwrap(fixtures.capturedRequests().last)
    let components = try XCTUnwrap(
      request.url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false) })
    XCTAssertEqual(components.queryItems?.first { $0.name == "before" }?.value, "100")
    XCTAssertEqual(components.queryItems?.first { $0.name == "per_page" }?.value, "50")
  }

  func testHistoryFilteredPageRetainsContinuationAndFinalPageEndsIt() async throws {
    let (runtime, _) = await makeSignedInRuntime()
    fixtures.setFixture(
      Self.historyFixture(
        [
          Self.historyEvent(90, type: "voucher"), Self.historyEvent(89, type: "zip_created"),
        ], hasMore: true), for: "GET /v2/events/list")
    let filtered = try await runtime.listHistory()
    XCTAssertEqual(filtered, PutioHistoryPage(items: [], nextBefore: 89))
    fixtures.setFixture(
      Self.historyFixture([], hasMore: false), for: "GET /v2/events/list")
    let final = try await runtime.listHistory(before: 89)
    XCTAssertEqual(final, PutioHistoryPage(items: [], nextBefore: nil))
  }

  func testHistoryRejectsMalformedPagination() async {
    let (runtime, _) = await makeSignedInRuntime()
    for events in [
      [], [Self.historyEvent(0, type: "upload")], [Self.historyEvent(100, type: "upload")],
    ] {
      fixtures.setFixture(
        Self.historyFixture(events, hasMore: true), for: "GET /v2/events/list")
      await assertRuntimeError(.invalidResponse) { _ = try await runtime.listHistory(before: 100) }
    }
    let count = fixtures.capturedRequests().count
    await assertRuntimeError(.invalidResponse) { _ = try await runtime.listHistory(before: 0) }
    await assertRuntimeError(.invalidResponse) { try await runtime.deleteHistoryEvent(id: -1) }
    XCTAssertEqual(fixtures.capturedRequests().count, count)
  }

  func testHistoryMutationsUseSDKRoutesAndPreserveSessionOnFailure() async throws {
    let (runtime, _) = await makeSignedInRuntime()
    fixtures.setFixture(#"{"status":"OK"}"#, for: "POST /v2/events/delete/99")
    fixtures.setFixture(#"{"status":"OK"}"#, for: "POST /v2/events/delete")
    try await runtime.deleteHistoryEvent(id: 99)
    try await runtime.clearHistory()
    XCTAssertEqual(
      fixtures.capturedRequests().suffix(2).compactMap { $0.url?.path },
      ["/v2/events/delete/99", "/v2/events/delete"])
    fixtures.setFixture(
      #"{"status":"ERROR"}"#, statusCode: 503, for: "POST /v2/events/delete")
    await assertRuntimeError(.transient) { try await runtime.clearHistory() }
    guard case .signedIn = runtime.session.state else {
      return XCTFail("transient failure expired session")
    }
  }

  func testHistoryRequiresAuthenticationAndExpiresRejectedSessions() async {
    let (signedOut, _) = makeRuntime(token: nil)
    await assertRuntimeError(.authenticationRequired) { _ = try await signedOut.listHistory() }
    await assertRuntimeError(.authenticationRequired) {
      try await signedOut.deleteHistoryEvent(id: 1)
    }
    await assertRuntimeError(.authenticationRequired) { try await signedOut.clearHistory() }
    XCTAssertTrue(fixtures.capturedRequests().isEmpty)
    let (runtime, store) = await makeSignedInRuntime()
    fixtures.setFixture(
      #"{"status":"ERROR"}"#, statusCode: 401, for: "GET /v2/events/list")
    await assertRuntimeError(.sessionExpired) { _ = try await runtime.listHistory() }
    XCTAssertEqual(runtime.session.state, .signedOut(.sessionExpired))
    XCTAssertNil(try? store.read())
  }

  private static func historyEvent(_ id: Int, type: String, fields: String = "") -> String {
    let extra = fields.isEmpty ? "" : "," + fields
    return """
      {"id":\(id),"user_id":1001,"type":"\(type)","created_at":"2026-09-08T10:00:00Z"\(extra)}
      """
  }

  private static func historyFixture(_ events: [String], hasMore: Bool) -> String {
    """
    {"status":"OK","has_more":\(hasMore),"events":[\(events.joined(separator: ","))]}
    """
  }
}
