import Foundation
import XCTest

@testable import PutioCore

extension PutioRuntimeTests {
  private static let historyReadRoute = "GET /v2/config/searchHistory"
  private static let historyWriteRoute = "PUT /v2/config/searchHistory"
  private static let enabledReadRoute = "GET /v2/config/searchHistoryEnabled"

  func testRecentSearchesRoundTripThroughTheirConfigKeys() async throws {
    let (runtime, _) = await makeSignedInRuntime()
    fixtures.setFixture(#"{"status":"OK"}"#, for: Self.historyWriteRoute)
    try await runtime.setRecentSearches(["blue lights", "sintel"])
    let write = try XCTUnwrap(
      fixtures.capturedRequests().last { $0.url?.path == "/v2/config/searchHistory" })
    XCTAssertEqual(write.httpMethod, "PUT")
    XCTAssertEqual(
      String(data: try XCTUnwrap(requestBodyData(for: write)), encoding: .utf8),
      #"{"value":["blue lights","sintel"]}"#)

    fixtures.setFixture(
      #"{"status":"OK","value":["blue lights",3,null,"sintel"]}"#, for: Self.historyReadRoute)
    fixtures.setFixture(#"{"status":"OK","value":false}"#, for: Self.enabledReadRoute)
    let stored = try await runtime.recentSearches()
    XCTAssertEqual(stored, PutioRecentSearches(enabled: false, terms: ["blue lights", "sintel"]))
  }

  func testMissingRecentSearchKeysReadAsOnAndEmpty() async throws {
    let (runtime, _) = await makeSignedInRuntime()
    fixtures.setFixture(#"{"status":"OK","value":null}"#, for: Self.historyReadRoute)
    fixtures.setFixture(
      #"{"status":"ERROR","error_type":"NotFound"}"#, statusCode: 404, for: Self.enabledReadRoute)
    let stored = try await runtime.recentSearches()
    XCTAssertEqual(stored, PutioRecentSearches(enabled: true, terms: []))

    fixtures.setFixture(#"{"status":"OK","value":"sintel"}"#, for: Self.historyReadRoute)
    fixtures.setFixture(#"{"status":"OK","value":"false"}"#, for: Self.enabledReadRoute)
    let malformed = try await runtime.recentSearches()
    XCTAssertEqual(malformed, PutioRecentSearches(enabled: true, terms: []))
  }

  func testRecentSearchFailuresReachTheCaller() async {
    let (runtime, _) = await makeSignedInRuntime()
    fixtures.setFixture(#"{"status":"OK","value":true}"#, for: Self.enabledReadRoute)
    fixtures.setFixture(
      #"{"status":"ERROR","error_type":"Unavailable"}"#, statusCode: 503,
      for: Self.historyReadRoute)
    await assertRuntimeError(.transient) { _ = try await runtime.recentSearches() }

    fixtures.setFixture(#"{"status":"ERROR"}"#, for: Self.historyWriteRoute)
    await assertRuntimeError(.invalidResponse) { try await runtime.setRecentSearches([]) }
  }
}
