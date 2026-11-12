import Foundation
import XCTest

@testable import PutioCore

extension PutioRuntimeTests {
  private static let pinsReadRoute = "GET /v2/config/pinned_files"
  private static let pinsWriteRoute = "PUT /v2/config/pinned_files"

  func testPinnedFilesRoundTripThroughTheirConfigKey() async throws {
    let (runtime, _) = await makeSignedInRuntime()
    fixtures.setFixture(#"{"status":"OK"}"#, for: Self.pinsWriteRoute)
    try await runtime.setPinnedFileIDs([PutioFileID(rawValue: 12), PutioFileID(rawValue: 7)])
    let write = try XCTUnwrap(
      fixtures.capturedRequests().last { $0.url?.path == "/v2/config/pinned_files" })
    XCTAssertEqual(write.httpMethod, "PUT")
    XCTAssertEqual(
      String(data: try XCTUnwrap(requestBodyData(for: write)), encoding: .utf8),
      #"{"value":[12,7]}"#)

    fixtures.setFixture(#"{"status":"OK","value":[12,7]}"#, for: Self.pinsReadRoute)
    let stored = try await runtime.pinnedFileIDs()
    XCTAssertEqual(stored, [PutioFileID(rawValue: 12), PutioFileID(rawValue: 7)])
  }

  func testPinnedFilesReadKeepsOnlyDistinctPositiveIDs() async throws {
    let (runtime, _) = await makeSignedInRuntime()
    fixtures.setFixture(
      #"{"value":[12,"7",12,-1,0,null,1.5,{"id":3},9]}"#, for: Self.pinsReadRoute)
    let mixed = try await runtime.pinnedFileIDs()
    XCTAssertEqual(mixed, [PutioFileID(rawValue: 12), PutioFileID(rawValue: 9)])

    for body in [#"{"value":null}"#, #"{"value":"12"}"#, #"{"value":{}}"#] {
      fixtures.setFixture(body, for: Self.pinsReadRoute)
      let ids = try await runtime.pinnedFileIDs()
      XCTAssertEqual(ids, [], body)
    }
  }

  func testAccountWithoutAConfigDocumentHasNoPins() async throws {
    let (runtime, _) = await makeSignedInRuntime()
    fixtures.setFixture(
      #"{"status":"ERROR","error_type":"NotFound"}"#, statusCode: 404, for: Self.pinsReadRoute)
    let ids = try await runtime.pinnedFileIDs()
    XCTAssertEqual(ids, [])
  }

  func testPinnedFilesFailuresReachTheCaller() async {
    let (runtime, _) = await makeSignedInRuntime()
    fixtures.setFixture(
      #"{"status":"ERROR","error_type":"Unavailable"}"#, statusCode: 503, for: Self.pinsReadRoute)
    await assertRuntimeError(.transient) { _ = try await runtime.pinnedFileIDs() }

    fixtures.setFixture(#"{"status":"ERROR"}"#, for: Self.pinsWriteRoute)
    await assertRuntimeError(.invalidResponse) { try await runtime.setPinnedFileIDs([]) }
  }
}
