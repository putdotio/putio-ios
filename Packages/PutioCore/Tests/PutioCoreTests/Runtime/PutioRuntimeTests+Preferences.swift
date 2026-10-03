import Foundation
import XCTest

@testable import PutioCore

extension PutioRuntimeTests {
  func testPlaybackRoutesRejectAmbiguousIdentityAndPreserveDescriptions() async throws {
    let (runtime, _) = await makeSignedInRuntime()
    let route = "GET /v2/tunnel/routes"
    fixtures.setFixture(
      #"{"routes":[{"name":"default","description":"Default proxy"},{"name":"edge","description":"Nearby proxy"}]}"#,
      for: route)
    let routes = try await runtime.listPlaybackRoutes()
    XCTAssertEqual(
      routes,
      [
        PutioPlaybackRoute(name: "default", description: "Default proxy"),
        PutioPlaybackRoute(name: "edge", description: "Nearby proxy"),
      ])
    for body in [#"{"routes":[{"name":""}]}"#, #"{"routes":[{"name":"same"},{"name":"same"}]}"#] {
      fixtures.setFixture(body, for: route)
      await assertRuntimeError(.invalidResponse) { _ = try await runtime.listPlaybackRoutes() }
    }
    let before = fixtures.capturedRequests().count
    await assertRuntimeError(.invalidResponse) { _ = try await runtime.setPlaybackRoute(name: " ") }
    XCTAssertEqual(fixtures.capturedRequests().count, before)
  }

  func testRejectedPlaybackPreferencesRemainFailuresWhenAccountValuesAreUnchanged() async {
    let (runtime, _) = await makeSignedInRuntime()
    fixtures.setFixture(
      #"{"status":"ERROR"}"#, statusCode: 503, for: "POST /v2/account/settings")
    await assertRuntimeError(.transient) { _ = try await runtime.setPlaybackRoute(name: "edge") }
    await assertRuntimeError(.transient) { _ = try await runtime.setSubtitlesVisible(false) }
    await assertRuntimeError(.transient) {
      _ = try await runtime.setSubtitleAutoSelectionDisabled(true)
    }
    XCTAssertFalse(runtime.session.isAccountPreferencesStale)
    guard case .signedIn(let account) = runtime.session.state else {
      return XCTFail("missing account")
    }
    XCTAssertEqual(account.routeName, "default")
    XCTAssertFalse(account.hideSubtitles)
    XCTAssertFalse(account.dontAutoSelectSubtitles)
  }

  func testLostPlaybackPreferenceResponsesAcceptAuthoritativelyAppliedValues() async throws {
    let (runtime, _) = await makeSignedInRuntime()
    fixtures.setFixture(
      #"{"status":"ERROR"}"#, statusCode: 503, for: "POST /v2/account/settings")
    fixtures.setFixture(
      Self.accountInfo
        .replacingOccurrences(
          of: #""tunnel_route_name": "default""#, with: #""tunnel_route_name": "edge""#
        )
        .replacingOccurrences(of: #""hide_subtitles": false"#, with: #""hide_subtitles": true"#)
        .replacingOccurrences(
          of: #""dont_autoselect_subtitles": false"#, with: #""dont_autoselect_subtitles": true"#),
      for: "GET /v2/account/info")
    let route = try await runtime.setPlaybackRoute(name: "edge")
    let visibility = try await runtime.setSubtitlesVisible(false)
    let selection = try await runtime.setSubtitleAutoSelectionDisabled(true)
    XCTAssertTrue(route.accountRefreshed)
    XCTAssertTrue(visibility.accountRefreshed)
    XCTAssertTrue(selection.accountRefreshed)
    XCTAssertFalse(runtime.session.isAccountPreferencesStale)
    XCTAssertEqual(
      fixtures.capturedRequests().filter { $0.url?.path == "/v2/account/settings" }
        .count, 3)
  }

  func testPlaybackPreferencesUseSingleFieldPatchesAndKeepAcknowledgedValues() async throws {
    let (runtime, _) = await makeSignedInRuntime()
    fixtures.setFixture(#"{"status":"OK"}"#, for: "POST /v2/account/settings")
    fixtures.setFixture(
      #"{"status":"ERROR"}"#, statusCode: 503, for: "GET /v2/account/info")
    _ = try await runtime.setPlaybackRoute(name: "edge")
    _ = try await runtime.setSubtitlesVisible(false)
    _ = try await runtime.setSubtitleAutoSelectionDisabled(true)
    _ = try await runtime.setTrashEnabled(false)
    guard case .signedIn(let account) = runtime.session.state else {
      return XCTFail("missing account")
    }
    XCTAssertEqual(account.routeName, "edge")
    XCTAssertTrue(account.hideSubtitles)
    XCTAssertTrue(account.dontAutoSelectSubtitles)
    XCTAssertFalse(account.trashEnabled)
    XCTAssertTrue(runtime.session.isAccountPreferencesStale)
    let writes = fixtures.capturedRequests().filter {
      $0.url?.path == "/v2/account/settings"
    }
    let bodies = try writes.map { request in
      try XCTUnwrap(
        JSONSerialization.jsonObject(with: XCTUnwrap(requestBodyData(for: request)))
          as? [String: Any])
    }
    XCTAssertEqual(bodies.count, 4)
    XCTAssertEqual(bodies[0]["tunnel_route_name"] as? String, "edge")
    XCTAssertEqual(bodies[1]["hide_subtitles"] as? Bool, true)
    XCTAssertEqual(bodies[2]["dont_autoselect_subtitles"] as? Bool, true)
    XCTAssertTrue(bodies.allSatisfy { $0.count == 1 })
    fixtures.setFixture(
      Self.accountInfo
        .replacingOccurrences(
          of: #""tunnel_route_name": "default""#, with: #""tunnel_route_name": "edge""#
        )
        .replacingOccurrences(of: #""hide_subtitles": false"#, with: #""hide_subtitles": true"#)
        .replacingOccurrences(
          of: #""dont_autoselect_subtitles": false"#, with: #""dont_autoselect_subtitles": true"#
        )
        .replacingOccurrences(of: #""trash_enabled": true"#, with: #""trash_enabled": false"#),
      for: "GET /v2/account/info")
    let refreshed = await runtime.refreshAccount()
    XCTAssertTrue(refreshed)
    XCTAssertEqual(runtime.session.state, .signedIn(account))

  }

  func testPreferenceWritesUseTypedSDKPatchesAndRefreshAuthoritativeSnapshot() async throws {
    let (runtime, _) = await makeSignedInRuntime()
    let settingsRoute = "POST /v2/account/settings"
    fixtures.setFixture(#"{"status":"OK"}"#, for: settingsRoute)
    fixtures.setFixture(
      Self.accountInfo.replacingOccurrences(of: "NAME_ASC", with: "SIZE_DESC"),
      for: "GET /v2/account/info")
    let sorted = try await runtime.setDefaultFolderSort(.sizeDescending)
    XCTAssertTrue(sorted.accountRefreshed)
    guard case .signedIn(let account) = runtime.session.state else {
      return XCTFail("missing account")
    }
    XCTAssertEqual(account.defaultSort, .sizeDescending)
    _ = try await runtime.setTrashEnabled(true)
    _ = try await runtime.setHistoryEnabled(false)
    let writes = fixtures.capturedRequests().filter {
      $0.url?.path == "/v2/account/settings"
    }
    let bodies = try writes.map { request in
      try XCTUnwrap(
        JSONSerialization.jsonObject(with: XCTUnwrap(requestBodyData(for: request)))
          as? [String: Any])
    }
    XCTAssertEqual(bodies.count, 3)
    XCTAssertEqual(bodies[0]["sort_by"] as? String, "SIZE_DESC")
    XCTAssertEqual(bodies[1]["trash_enabled"] as? Bool, true)
    XCTAssertEqual(bodies[2]["history_enabled"] as? Bool, false)
    XCTAssertTrue(bodies.allSatisfy { $0.count == 1 })
    fixtures.setFixture(
      #"{"status":"OK"}"#, for: "POST /v2/files/remove-sort-by-settings")
    let reset = try await runtime.resetFolderSorts()
    XCTAssertTrue(reset.accountRefreshed)
    XCTAssertEqual(runtime.session.folderSortsRevision, 1)
  }

  func testCommittedTrashDisableHasRefreshOnlyRecoveryAndKeepsAcknowledgedSetting() async throws {
    let (runtime, _) = await makeSignedInRuntime()
    fixtures.setFixture(#"{"status":"OK"}"#, for: "POST /v2/account/settings")
    fixtures.setFixture(
      #"{"status":"ERROR"}"#, statusCode: 503, for: "GET /v2/account/info")
    let result = try await runtime.setTrashEnabled(false)
    XCTAssertFalse(result.accountRefreshed)
    XCTAssertTrue(runtime.session.isAccountPreferencesStale)
    XCTAssertTrue(runtime.session.isAccountStorageStale)
    guard case .signedIn(let stale) = runtime.session.state else {
      return XCTFail("missing account")
    }
    XCTAssertFalse(stale.trashEnabled, "committed disable must not offer recoverable Trash")
    fixtures.setFixture(
      Self.accountInfo.replacingOccurrences(
        of: "\"trash_enabled\": true", with: "\"trash_enabled\": false"),
      for: "GET /v2/account/info")
    let refreshed = await runtime.refreshAccount()
    XCTAssertTrue(refreshed)
    XCTAssertFalse(runtime.session.isAccountPreferencesStale)
    XCTAssertFalse(runtime.session.isAccountStorageStale)
    guard case .signedIn(let current) = runtime.session.state else {
      return XCTFail("missing account")
    }
    XCTAssertFalse(current.trashEnabled)
    XCTAssertEqual(
      fixtures.capturedRequests().filter { $0.url?.path == "/v2/account/settings" }
        .count, 1)
  }

  func testPendingTrashDisableBlocksDeletionEvenAfterUnrelatedAccountRefresh() async throws {
    let (runtime, _) = await makeSignedInRuntime()
    let route = "POST /v2/account/settings"
    fixtures.gateFixture(#"{"status":"OK"}"#, for: route)
    let saving = Task { try await runtime.setTrashEnabled(false) }
    defer {
      saving.cancel()
      fixtures.releaseFixture(for: route)
    }
    guard await waitForRequest(route, count: 1) else {
      return XCTFail("preference write never started")
    }
    XCTAssertTrue(runtime.session.isUpdatingAccountPreferences)
    _ = await runtime.refreshAccount()
    XCTAssertTrue(runtime.session.isUpdatingAccountPreferences)
    let requests = fixtures.capturedRequests().count
    await assertRuntimeError(.transient) {
      try await runtime.deleteFile(fileID: PutioFileID(rawValue: 411))
    }
    await assertRuntimeError(.transient) { _ = try await runtime.resetFolderSorts() }
    XCTAssertEqual(runtime.session.folderSortsRevision, 0)
    XCTAssertEqual(fixtures.capturedRequests().count, requests)
    fixtures.setFixture(
      Self.accountInfo.replacingOccurrences(
        of: "\"trash_enabled\": true", with: "\"trash_enabled\": false"),
      for: "GET /v2/account/info")
    fixtures.releaseFixture(for: route)
    let result = try await saving.value
    XCTAssertTrue(result.accountRefreshed)
    XCTAssertFalse(runtime.session.isUpdatingAccountPreferences)
    guard case .signedIn(let account) = runtime.session.state else {
      return XCTFail("missing account")
    }
    XCTAssertFalse(account.trashEnabled)
  }

  func testPendingFolderSortResetSerializesSettingsWritesAndOtherResets() async throws {
    let (runtime, _) = await makeSignedInRuntime()
    let route = "POST /v2/files/remove-sort-by-settings"
    fixtures.gateFixture(#"{"status":"OK"}"#, for: route)
    let resetting = Task { try await runtime.resetFolderSorts() }
    defer {
      resetting.cancel()
      fixtures.releaseFixture(for: route)
    }
    guard await waitForRequest(route) else { return XCTFail("reset never started") }
    XCTAssertTrue(runtime.session.isUpdatingAccountPreferences)
    let requests = fixtures.capturedRequests().count
    await assertRuntimeError(.transient) { _ = try await runtime.setTrashEnabled(false) }
    await assertRuntimeError(.transient) { _ = try await runtime.resetFolderSorts() }
    XCTAssertEqual(fixtures.capturedRequests().count, requests)
    XCTAssertEqual(runtime.session.folderSortsRevision, 0)
    fixtures.releaseFixture(for: route)
    _ = try await resetting.value
    XCTAssertFalse(runtime.session.isUpdatingAccountPreferences)
    XCTAssertEqual(runtime.session.folderSortsRevision, 1)
  }

  func testFolderSortResetCompletionAfterSignOutDoesNotInvalidateAnotherSession() async {
    let (runtime, _) = await makeSignedInRuntime()
    let route = "POST /v2/files/remove-sort-by-settings"
    fixtures.gateFixture(#"{"status":"OK"}"#, for: route)
    let resetting = Task { try await runtime.resetFolderSorts() }
    defer {
      resetting.cancel()
      fixtures.releaseFixture(for: route)
    }
    guard await waitForRequest(route) else { return XCTFail("reset never started") }
    await runtime.session.signOut()
    fixtures.releaseFixture(for: route)
    await assertRuntimeError(.authenticationRequired) { _ = try await resetting.value }
    XCTAssertFalse(runtime.session.isUpdatingAccountPreferences)
    XCTAssertEqual(runtime.session.folderSortsRevision, 0)
  }

  func testRejectedFolderSortResetDoesNotReportSuccessFromUnchangedAccountSettings() async {
    let (runtime, _) = await makeSignedInRuntime()
    fixtures.setFixture(
      #"{"status":"ERROR"}"#, statusCode: 503, for: "POST /v2/files/remove-sort-by-settings")
    await assertRuntimeError(.transient) { _ = try await runtime.resetFolderSorts() }
    XCTAssertFalse(runtime.session.isAccountPreferencesStale)
    XCTAssertEqual(runtime.session.folderSortsRevision, 1)
    XCTAssertFalse(runtime.session.isUpdatingAccountPreferences)
  }

  func testAmbiguousTrashDisableBlocksDeletionUntilAccountCanBeReconciled() async throws {
    let (runtime, _) = await makeSignedInRuntime()
    fixtures.setFixture(
      #"{"status":"ERROR"}"#, statusCode: 503, for: "POST /v2/account/settings")
    fixtures.setFixture(
      #"{"status":"ERROR"}"#, statusCode: 503, for: "GET /v2/account/info")
    await assertRuntimeError(.transient) { _ = try await runtime.setTrashEnabled(false) }
    XCTAssertTrue(runtime.session.isAccountPreferencesStale)
    XCTAssertTrue(runtime.session.isAccountStorageStale)
    let requests = fixtures.capturedRequests().count
    await assertRuntimeError(.transient) {
      try await runtime.deleteFile(fileID: PutioFileID(rawValue: 411))
    }
    XCTAssertEqual(fixtures.capturedRequests().count, requests)
    fixtures.setFixture(
      Self.accountInfo.replacingOccurrences(
        of: "\"trash_enabled\": true", with: "\"trash_enabled\": false"),
      for: "GET /v2/account/info")
    let refreshed = await runtime.refreshAccount()
    XCTAssertTrue(refreshed)
    guard case .signedIn(let account) = runtime.session.state else {
      return XCTFail("missing account")
    }
    XCTAssertFalse(account.trashEnabled)
    fixtures.setFixture(#"{"status":"OK"}"#, for: "POST /v2/files/delete")
    try await runtime.deleteFile(fileID: PutioFileID(rawValue: 411))
    XCTAssertEqual(
      fixtures.capturedRequests().filter { $0.url?.path == "/v2/account/settings" }
        .count, 1)
  }

  func testLostWriteResponseAcceptsAuthoritativelyAppliedPreference() async throws {
    let (runtime, _) = await makeSignedInRuntime()
    fixtures.setFixture(
      #"{"status":"ERROR"}"#, statusCode: 503, for: "POST /v2/account/settings")
    fixtures.setFixture(
      Self.accountInfo.replacingOccurrences(
        of: "\"trash_enabled\": true", with: "\"trash_enabled\": false"),
      for: "GET /v2/account/info")
    let result = try await runtime.setTrashEnabled(false)
    XCTAssertTrue(result.accountRefreshed)
    XCTAssertFalse(runtime.session.isAccountPreferencesStale)
    XCTAssertEqual(
      fixtures.capturedRequests().filter { $0.url?.path == "/v2/account/settings" }
        .count, 1)
  }

  func testOldAccountResponseCannotOverwritePreferencesAfterCommittedMutation() async throws {
    let (runtime, _) = await makeSignedInRuntime()
    let route = "GET /v2/account/info"
    fixtures.gateFixture(
      Self.accountInfo.replacingOccurrences(of: "NAME_ASC", with: "DATE_DESC"), for: route)
    let older = Task { await runtime.refreshAccount() }
    guard await waitForRequest(route, count: 2) else {
      older.cancel()
      fixtures.releaseFixture(for: route)
      return XCTFail("old refresh never started")
    }
    fixtures.setFixture(#"{"status":"OK"}"#, for: "POST /v2/account/settings")
    fixtures.setFixture(#"{"status":"ERROR"}"#, statusCode: 503, for: route)
    let saved = try await runtime.setHistoryEnabled(false)
    XCTAssertFalse(saved.accountRefreshed)
    fixtures.releaseFixture(for: route)
    let oldResult = await older.value
    XCTAssertFalse(oldResult)
    XCTAssertTrue(runtime.session.isAccountPreferencesStale)
    guard case .signedIn(let account) = runtime.session.state else {
      return XCTFail("missing account")
    }
    XCTAssertEqual(
      account.defaultSort, .nameAscending, "obsolete response must not apply any fields")
    await runtime.session.signOut()
    XCTAssertFalse(runtime.session.isAccountPreferencesStale)
  }

  func testRejectedPreferenceIsReconciledAndUnknownSortStaysNil() async {
    let (runtime, _) = await makeSignedInRuntime()
    fixtures.setFixture(
      #"{"status":"ERROR"}"#, statusCode: 503, for: "POST /v2/account/settings")
    await assertRuntimeError(.transient) { _ = try await runtime.setHistoryEnabled(false) }
    XCTAssertFalse(runtime.session.isAccountPreferencesStale)
    fixtures.setFixture(
      Self.accountInfo.replacingOccurrences(of: "NAME_ASC", with: "FUTURE_SORT"),
      for: "GET /v2/account/info")
    let refreshed = await runtime.refreshAccount()
    XCTAssertTrue(refreshed)
    guard case .signedIn(let account) = runtime.session.state else {
      return XCTFail("missing account")
    }
    XCTAssertNil(account.defaultSort)
  }
}
