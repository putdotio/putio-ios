import Foundation
import XCTest

@testable import PutioCore

extension PutioRuntimeTests {
  private static let trashListRoute = "GET /v2/trash/list"
  private static let trashContinueRoute = "POST /v2/trash/list/continue"
  private static let trashRestoreRoute = "POST /v2/trash/restore"
  private static let trashDeleteRoute = "POST /v2/trash/delete"
  private static let trashEmptyRoute = "POST /v2/trash/empty"
  private static let restoredTrashFileRoute = "GET /v2/files/91"

  func testListTrashMapsAppOwnedPageAndItemValues() async throws {
    let (runtime, _) = await makeSignedInRuntime()
    fixtures.setFixture(
      """
      {
        "cursor": "trash-page-2",
        "total": 3,
        "trash_size": 4096,
        "files": [
          {
            "id": 91,
            "name": "Old episode.mkv",
            "file_type": "VIDEO",
            "parent_id": 7,
            "size": 2048,
            "created_at": "2026-08-28T10:00:00Z",
            "deleted_at": "2026-09-01T11:00:00Z",
            "expiration_date": "2026-10-01T11:00:00Z"
          }
        ]
      }
      """,
      for: Self.trashListRoute
    )

    let page = try await runtime.listTrash()

    XCTAssertEqual(page.nextCursor, "trash-page-2")
    XCTAssertEqual(page.totalCount, 3)
    XCTAssertEqual(page.sizeBytes, 4_096)
    let item = try XCTUnwrap(page.items.first)
    XCTAssertEqual(item.id, PutioFileID(rawValue: 91))
    XCTAssertEqual(item.parentID, PutioFileID(rawValue: 7))
    XCTAssertEqual(item.name, "Old episode.mkv")
    XCTAssertEqual(item.kind, .video)
    XCTAssertEqual(item.sizeBytes, 2_048)
    XCTAssertEqual(
      item.deletedAt,
      try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-09-01T11:00:00Z"))
    )
    XCTAssertEqual(
      item.expiresAt,
      try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-10-01T11:00:00Z"))
    )
  }

  func testListTrashContinuationUsesCursorRequestAndDropsEmptyNextCursor() async throws {
    let (runtime, _) = await makeSignedInRuntime()
    fixtures.setFixture(
      #"{"cursor":"","trash_size":0,"files":[]}"#,
      for: Self.trashContinueRoute
    )

    let page = try await runtime.listTrash(cursor: "trash-page-2")

    XCTAssertNil(page.nextCursor)
    let request = try XCTUnwrap(fixtures.capturedRequests().last)
    XCTAssertEqual(request.httpMethod, "POST")
    XCTAssertEqual(request.url?.path, "/v2/trash/list/continue")
    let body = try XCTUnwrap(requestBodyData(for: request))
    let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
    XCTAssertEqual(json["cursor"] as? String, "trash-page-2")
  }

  func testListTrashContinuationRejectsANonadvancingCursor() async {
    let (runtime, _) = await makeSignedInRuntime()
    fixtures.setFixture(
      #"{"cursor":"trash-page-2","trash_size":0,"files":[]}"#, for: Self.trashContinueRoute)
    await assertRuntimeError(.invalidResponse) {
      _ = try await runtime.listTrash(cursor: "trash-page-2")
    }
  }

  func testTrashMutationsUseSingleItemSDKRequests() async throws {
    let (runtime, _) = await makeSignedInRuntime()
    fixtures.setFixture(#"{"status":"OK"}"#, for: Self.trashRestoreRoute)
    fixtures.setFixture(
      """
      {
        "file": {
          "id": 91,
          "name": "Old episode.mkv",
          "file_type": "VIDEO",
          "parent_id": 7,
          "size": 2048,
          "created_at": "2026-08-28T10:00:00Z",
          "updated_at": "2026-09-03T10:00:00Z"
        }
      }
      """,
      for: Self.restoredTrashFileRoute
    )
    fixtures.setFixture(#"{"status":"OK"}"#, for: Self.trashDeleteRoute)
    fixtures.setFixture(#"{"status":"OK"}"#, for: Self.trashEmptyRoute)
    let fileID = PutioFileID(rawValue: 91)

    let restoredItem = try await runtime.restoreTrashItem(fileID: fileID)
    fixtures.setFixture(
      Self.accountInfo.replacingOccurrences(of: "\"used\": 20", with: "\"used\": 10"),
      for: "GET /v2/account/info"
    )
    let deleteOutcome = try await runtime.permanentlyDeleteTrashItem(fileID: fileID)
    XCTAssertTrue(deleteOutcome.storageRefreshed)
    guard case .signedIn(let afterDelete) = runtime.session.state else {
      return XCTFail("expected account after deletion")
    }
    XCTAssertEqual(afterDelete.storage.usedBytes, 10)
    fixtures.setFixture(
      Self.accountInfo.replacingOccurrences(of: "\"used\": 20", with: "\"used\": 0"),
      for: "GET /v2/account/info"
    )
    let emptyOutcome = try await runtime.emptyTrash()
    XCTAssertTrue(emptyOutcome.storageRefreshed)
    guard case .signedIn(let afterEmpty) = runtime.session.state else {
      return XCTFail("expected account after emptying Trash")
    }
    XCTAssertEqual(afterEmpty.storage.usedBytes, 0)

    XCTAssertEqual(restoredItem, .restored(destinationID: PutioFileID(rawValue: 7)))
    let requests = fixtures.capturedRequests().suffix(6)
    XCTAssertEqual(
      requests.compactMap { $0.url?.path },
      [
        "/v2/trash/restore", "/v2/files/91", "/v2/trash/delete", "/v2/account/info",
        "/v2/trash/empty", "/v2/account/info",
      ]
    )
    XCTAssertEqual(requests.map(\.httpMethod), ["POST", "GET", "POST", "GET", "POST", "GET"])
    for request in [
      requests[requests.startIndex], requests[requests.index(requests.startIndex, offsetBy: 2)],
    ] {
      let body = try XCTUnwrap(requestBodyData(for: request))
      let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
      XCTAssertEqual(json["file_ids"] as? String, "91")
      XCTAssertNil(json["cursor"])
    }
  }

  func testRestoreSurfacesCancellationDuringDestinationLookup() async throws {
    let (runtime, _) = await makeSignedInRuntime()
    fixtures.setFixture(#"{"status":"OK"}"#, for: Self.trashRestoreRoute)
    fixtures.gateFixture(#"{"status":"OK"}"#, for: Self.restoredTrashFileRoute)

    let restore = Task { try await runtime.restoreTrashItem(fileID: PutioFileID(rawValue: 91)) }
    guard await waitForRequest(Self.restoredTrashFileRoute) else {
      restore.cancel()
      fixtures.releaseFixture(for: Self.restoredTrashFileRoute)
      return XCTFail("the destination lookup did not start")
    }
    restore.cancel()
    fixtures.releaseFixture(for: Self.restoredTrashFileRoute)

    let result = try await restore.value
    XCTAssertEqual(result, .restoredLookupCancelled, "the restore itself is committed")
  }

  func testRestoreCancelledBeforeCommitThrows() async throws {
    let (runtime, _) = await makeSignedInRuntime()
    fixtures.gateFixture(#"{"status":"OK"}"#, for: Self.trashRestoreRoute)

    let restore = Task { try await runtime.restoreTrashItem(fileID: PutioFileID(rawValue: 91)) }
    guard await waitForRequest(Self.trashRestoreRoute) else {
      restore.cancel()
      fixtures.releaseFixture(for: Self.trashRestoreRoute)
      return XCTFail("the restore request did not start")
    }
    restore.cancel()
    fixtures.releaseFixture(for: Self.trashRestoreRoute)

    do {
      let result = try await restore.value
      XCTFail("expected an error before commit, got \(result)")
    } catch is CancellationError {
      // The runtime normalizes URLSession cancellation to CancellationError,
      // so callers only ever classify one representation.
    } catch {
      XCTFail("expected CancellationError, got \(error)")
    }
  }

  func testRestorePreservesCommittedMutationWhenDestinationLookupFails() async throws {
    let (runtime, _) = await makeSignedInRuntime()
    fixtures.setFixture(#"{"status":"OK"}"#, for: Self.trashRestoreRoute)
    fixtures.setFixture(
      #"{"error_type":"service_unavailable"}"#,
      statusCode: 503,
      for: Self.restoredTrashFileRoute
    )

    let result = try await runtime.restoreTrashItem(fileID: PutioFileID(rawValue: 91))

    XCTAssertEqual(result, .restoredDestinationUnknown)
    XCTAssertEqual(
      fixtures.capturedRequests().suffix(2).compactMap { $0.url?.path },
      ["/v2/trash/restore", "/v2/files/91"]
    )
  }

  func testTrashMutationSuccessSurvivesAccountRefreshFailure() async throws {
    let (runtime, _) = await makeSignedInRuntime()
    let originalState = runtime.session.state
    fixtures.setFixture(#"{"status":"OK"}"#, for: Self.trashDeleteRoute)
    fixtures.setFixture(#"{"status":"OK"}"#, for: Self.trashEmptyRoute)
    fixtures.setFixture(
      #"{"status":"ERROR","error_type":"TEMPORARY_ERROR"}"#,
      statusCode: 503,
      for: "GET /v2/account/info"
    )

    XCTAssertFalse(runtime.session.isAccountStorageStale)
    let deleteResult = try await runtime.permanentlyDeleteTrashItem(
      fileID: PutioFileID(rawValue: 91))
    XCTAssertEqual(runtime.session.state, originalState)
    XCTAssertFalse(deleteResult.storageRefreshed)
    XCTAssertTrue(runtime.session.isAccountStorageStale, "the session remembers stale storage")
    let emptyResult = try await runtime.emptyTrash()
    XCTAssertEqual(runtime.session.state, originalState)
    XCTAssertFalse(emptyResult.storageRefreshed)

    fixtures.setFixture(
      Self.accountInfo.replacingOccurrences(of: "\"used\": 20", with: "\"used\": 5"),
      for: "GET /v2/account/info"
    )
    let refreshed = await runtime.refreshAccount()
    XCTAssertTrue(refreshed)
    XCTAssertFalse(runtime.session.isAccountStorageStale)
    guard case .signedIn(let account) = runtime.session.state else {
      return XCTFail("expected a signed-in account after the storage retry")
    }
    XCTAssertEqual(account.storage.usedBytes, 5)
  }

  func testStaleStorageDoesNotOutliveTheSession() async throws {
    let (runtime, _) = await makeSignedInRuntime()
    fixtures.setFixture(#"{"status":"OK"}"#, for: Self.trashEmptyRoute)
    fixtures.setFixture(
      #"{"status":"ERROR","error_type":"TEMPORARY_ERROR"}"#,
      statusCode: 503,
      for: "GET /v2/account/info"
    )
    _ = try await runtime.emptyTrash()
    XCTAssertTrue(runtime.session.isAccountStorageStale)

    await runtime.session.signOut()
    XCTAssertFalse(runtime.session.isAccountStorageStale)
  }

  func testRefreshStartedBeforeAMutationCannotClearStaleStorage() async throws {
    let route = "GET /v2/account/info"
    let (runtime, _) = await makeSignedInRuntime()
    fixtures.gateFixture(Self.accountInfo, for: route)
    let preMutation = Task { await runtime.refreshAccount() }
    guard await waitForRequest(route, count: 2) else {
      preMutation.cancel()
      fixtures.releaseFixture(for: route)
      return XCTFail("the gated account refresh did not start")
    }

    fixtures.setFixture(#"{"status":"OK"}"#, for: Self.trashEmptyRoute)
    fixtures.setFixture(
      #"{"status":"ERROR","error_type":"TEMPORARY_ERROR"}"#, statusCode: 503, for: route)
    let emptied = try await runtime.emptyTrash()
    XCTAssertFalse(emptied.storageRefreshed)
    XCTAssertTrue(runtime.session.isAccountStorageStale)

    fixtures.releaseFixture(for: route)
    let preMutationResult = await preMutation.value
    XCTAssertFalse(preMutationResult, "a pre-mutation snapshot does not satisfy the retry")
    XCTAssertTrue(runtime.session.isAccountStorageStale, "stale storage stays visible")

    fixtures.setFixture(
      Self.accountInfo.replacingOccurrences(of: "\"used\": 20", with: "\"used\": 0"), for: route)
    let retried = await runtime.refreshAccount()
    XCTAssertTrue(retried)
    XCTAssertFalse(runtime.session.isAccountStorageStale)
  }

  func testOlderSuccessfulRefreshAppliesWhenTheNewerRefreshFailed() async throws {
    let route = "GET /v2/account/info"
    let (runtime, _) = await makeSignedInRuntime()
    fixtures.gateFixture(
      Self.accountInfo.replacingOccurrences(of: "\"used\": 20", with: "\"used\": 99"),
      for: route
    )
    let older = Task { await runtime.refreshAccount() }
    guard await waitForRequest(route, count: 2) else {
      older.cancel()
      fixtures.releaseFixture(for: route)
      return XCTFail("the gated account refresh did not start")
    }

    fixtures.setFixture(
      #"{"status":"ERROR","error_type":"TEMPORARY_ERROR"}"#, statusCode: 503, for: route)
    let newer = await runtime.refreshAccount()
    XCTAssertFalse(newer)

    fixtures.releaseFixture(for: route)
    let olderResult = await older.value
    XCTAssertTrue(olderResult)
    guard case .signedIn(let account) = runtime.session.state else {
      return XCTFail("expected a signed-in account")
    }
    XCTAssertEqual(account.storage.usedBytes, 99, "the only successful response is the truth")
  }

  func testOlderAccountRefreshCannotOverwriteANewerSnapshotInTheSameSession() async throws {
    let route = "GET /v2/account/info"
    let (runtime, _) = await makeSignedInRuntime()
    fixtures.gateFixture(
      Self.accountInfo.replacingOccurrences(of: "\"used\": 20", with: "\"used\": 99"),
      for: route
    )
    let older = Task { await runtime.refreshAccount() }
    guard await waitForRequest(route, count: 2) else {
      older.cancel()
      fixtures.releaseFixture(for: route)
      return XCTFail("the gated account refresh did not start")
    }

    fixtures.setFixture(
      Self.accountInfo.replacingOccurrences(of: "\"used\": 20", with: "\"used\": 5"),
      for: route
    )
    let newer = await runtime.refreshAccount()
    XCTAssertTrue(newer)

    fixtures.releaseFixture(for: route)
    let olderResult = await older.value
    XCTAssertTrue(olderResult, "the older refresh still succeeded for its caller")

    guard case .signedIn(let account) = runtime.session.state else {
      return XCTFail("expected a signed-in account")
    }
    XCTAssertEqual(account.storage.usedBytes, 5, "the slower older response must not win")
  }

  func testTrashAccountRefreshAuthFailureExpiresSessionWithoutFailingMutation() async throws {
    let (runtime, tokenStore) = await makeSignedInRuntime()
    fixtures.setFixture(#"{"status":"OK"}"#, for: Self.trashEmptyRoute)
    fixtures.setFixture(
      #"{"status":"ERROR","error_type":"invalid_grant"}"#,
      statusCode: 401,
      for: "GET /v2/account/info"
    )

    _ = try await runtime.emptyTrash()

    XCTAssertEqual(runtime.session.state, .signedOut(.sessionExpired))
    XCTAssertNil(try tokenStore.read())
  }

  func testOldTrashAccountRefreshCannotChangeANewerSession() async throws {
    let route = "GET /v2/account/info"
    for (statusCode, body) in [
      (200, Self.accountInfo),
      (401, #"{"status":"ERROR","error_type":"invalid_grant"}"#),
    ] {
      fixtures.reset()
      let (runtime, tokenStore) = await makeSignedInRuntime()
      fixtures.setFixture(#"{"status":"OK"}"#, for: Self.trashEmptyRoute)
      fixtures.gateFixture(body, statusCode: statusCode, for: route)
      let mutation = Task { try await runtime.emptyTrash() }
      guard await waitForRequest(route, count: 2) else {
        mutation.cancel()
        fixtures.releaseFixture(for: route)
        return XCTFail("post-mutation account refresh did not start")
      }

      await runtime.session.signOut()
      fixtures.setFixture(
        Self.accountInfo.replacingOccurrences(of: "moviebuff", with: "fresh-user"), for: route)
      let request = try runtime.session.beginSignIn()
      let oauthState = try XCTUnwrap(oauthState(from: request.url))
      let callback = try XCTUnwrap(
        URL(string: "putio://auth#access_token=fresh-token&state=\(oauthState)"))
      await runtime.session.completeSignIn(callbackURL: callback)
      fixtures.releaseFixture(for: route)
      _ = try await mutation.value

      guard case .signedIn(let account) = runtime.session.state else {
        return XCTFail("old account HTTP \(statusCode) response expired the new session")
      }
      XCTAssertEqual(account.username, "fresh-user")
      XCTAssertEqual(try tokenStore.read(), "fresh-token")
    }
  }

  func testTrashMutationsRejectNonOKStatuses() async {
    let (runtime, _) = await makeSignedInRuntime()
    fixtures.setFixture(#"{"status":"ERROR"}"#, for: Self.trashRestoreRoute)
    fixtures.setFixture(#"{"status":"ERROR"}"#, for: Self.trashDeleteRoute)
    fixtures.setFixture(#"{"status":"ERROR"}"#, for: Self.trashEmptyRoute)

    await assertRuntimeError(.invalidResponse) {
      _ = try await runtime.restoreTrashItem(fileID: PutioFileID(rawValue: 91))
    }
    await assertRuntimeError(.invalidResponse) {
      _ = try await runtime.permanentlyDeleteTrashItem(fileID: PutioFileID(rawValue: 91))
    }
    await assertRuntimeError(.invalidResponse) {
      _ = try await runtime.emptyTrash()
    }
  }
}
