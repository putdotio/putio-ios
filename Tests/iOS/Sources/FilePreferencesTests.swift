import Foundation
import Observation
import PutioCore
import XCTest

@testable import Putio

@MainActor
final class FilePreferencesTests: XCTestCase {
  func testValuesFollowAuthoritativeSnapshotWithoutLocalPreferenceCopies() {
    let session = PreferencesSessionFixture()
    let model = model(session: session)
    XCTAssertEqual(model.account?.defaultSort, .nameAscending)
    session.account = Self.account(sort: .sizeDescending, trash: false, history: false)
    XCTAssertEqual(model.account?.defaultSort, .sizeDescending)
    XCTAssertEqual(model.account?.trashEnabled, false)
    XCTAssertEqual(model.account?.historyEnabled, false)
    session.account = nil
    XCTAssertNil(model.account)
    XCTAssertFalse(model.canSave)
  }

  func testFailedSavePreservesSnapshotAndExplicitRetryRepeatsOnlyFailedIntent() async {
    let session = PreferencesSessionFixture()
    let original = session.account
    var attempts: [PutioAccountPreferenceMutation] = []
    let model = model(
      session: session,
      save: { intent in
        attempts.append(intent)
        if attempts.count == 1 { throw PutioRuntimeError.transient }
        session.account = Self.account(trash: false)
        return PutioAccountPreferencesMutationResult(accountRefreshed: true)
      })
    await model.save(.trash(false))
    XCTAssertEqual(session.account, original)
    XCTAssertNotNil(model.failure)
    XCTAssertEqual(model.failedMutation, .trash(false))
    await model.retrySave()
    XCTAssertEqual(attempts, [.trash(false), .trash(false)])
    XCTAssertEqual(model.account?.trashEnabled, false)
    XCTAssertNil(model.failedMutation)
  }

  func testCommittedDisableWithFailedRefreshOnlyRetriesAccountRead() async {
    let session = PreferencesSessionFixture()
    var mutations = 0
    var reads = 0
    let model = model(
      session: session,
      save: { _ in
        mutations += 1
        session.account = Self.account(history: false)
        session.isStale = true
        return PutioAccountPreferencesMutationResult(accountRefreshed: false)
      },
      refresh: {
        reads += 1
        if reads == 1 { return false }
        session.account = Self.account(history: false)
        session.isStale = false
        return true
      })
    await model.save(.history(false))
    XCTAssertNil(model.failedMutation)
    XCTAssertTrue(model.isStale)
    XCTAssertFalse(model.canSave)
    XCTAssertEqual(model.account?.historyEnabled, false)
    await model.retrySave()
    await model.save(.resetFolderSorts)
    await model.retryRefresh()
    XCTAssertTrue(model.isStale)
    XCTAssertNotNil(model.failure)
    await model.retryRefresh()
    XCTAssertFalse(model.isStale)
    XCTAssertEqual(model.account?.historyEnabled, false)
    XCTAssertEqual(mutations, 1)
    XCTAssertEqual(reads, 2)
  }

  func testUnknownSaveOutcomeOffersRefreshWithoutRepeatingDestructiveWrite() async {
    let session = PreferencesSessionFixture()
    var writes = 0
    let model = model(
      session: session,
      save: { _ in
        writes += 1
        session.isStale = true
        throw PutioRuntimeError.transient
      },
      refresh: {
        session.account = Self.account(trash: false)
        session.isStale = false
        return true
      })
    await model.save(.trash(false))
    XCTAssertTrue(model.isStale)
    XCTAssertNil(model.failedMutation)
    XCTAssertFalse(model.canSave)
    XCTAssertFalse(model.failure?.contains("Saved") ?? true)
    await model.retrySave()
    await model.retryRefresh()
    XCTAssertEqual(writes, 1)
    XCTAssertFalse(model.isStale)
    XCTAssertEqual(model.account?.trashEnabled, false)
  }

  func testUnknownDisableDoesNotReportCommittedWhenRefreshShowsTrashStillEnabled() async {
    let session = PreferencesSessionFixture()
    let model = model(
      session: session,
      save: { _ in
        session.isStale = true
        throw PutioRuntimeError.transient
      },
      refresh: {
        session.isStale = false
        return true
      })
    await model.save(.trash(false))
    await model.retryRefresh()
    XCTAssertEqual(model.account?.trashEnabled, true)
    XCTAssertTrue(model.canSave)
  }

  func testLateAccountRefreshReconcilesFoldersAfterPreferencesModelIsReleased() async throws {
    let session = PreferencesSessionFixture()
    let previous = try XCTUnwrap(session.account)
    let folders = PutioFolderRefreshRequests()
    let owner = UUID()
    folders.register(folderID: .root, owner: owner)
    var preferences: PutioAccountPreferencesModel? = model(
      session: session,
      save: { _ in
        session.isStale = true
        throw PutioRuntimeError.transient
      })
    weak var releasedModel = preferences
    await preferences?.save(.defaultSort(.sizeDescending))
    preferences = nil
    XCTAssertNil(releasedModel)

    // An account refresh from a different screen resolves the lost response.
    session.account = Self.account(sort: .sizeDescending)
    session.isStale = false
    PutioAccountPreferencesReconciliation.apply(
      previous: previous, current: try XCTUnwrap(session.account),
      folders: folders, trash: PutioTrashReconciliation())
    XCTAssertNotNil(folders.sequence(for: .root, owner: owner))
  }

  func testLateTrashDisablePrunesPreviouslyLoadedRowsWithoutMutationCallback() {
    let folders = PutioFolderRefreshRequests()
    let trash = PutioTrashReconciliation()
    let item = PutioTrashItem(
      id: PutioFileID(rawValue: 42), parentID: .root, name: "Old movie", kind: .video,
      sizeBytes: 100, deletedAt: Date(timeIntervalSince1970: 100),
      expiresAt: Date(timeIntervalSince1970: 200))
    let page = PutioTrashPage(items: [item], nextCursor: nil, totalCount: 1, sizeBytes: 100)
    XCTAssertEqual(trash.prune(page).items, [item])
    PutioAccountPreferencesReconciliation.apply(
      previous: Self.account(), current: Self.account(trash: false),
      folders: folders, trash: trash)
    XCTAssertTrue(trash.prune(page).items.isEmpty)
  }

  func testUnchangedPreferencesAndDifferentAccountsDoNotReconcileOldState() {
    let folders = PutioFolderRefreshRequests()
    let owner = UUID()
    folders.register(folderID: .root, owner: owner)
    let trash = PutioTrashReconciliation()
    PutioAccountPreferencesReconciliation.apply(
      previous: Self.account(), current: Self.account(), folders: folders, trash: trash)
    PutioAccountPreferencesReconciliation.apply(
      previous: Self.account(), current: Self.account(id: 11, sort: .sizeDescending, trash: false),
      folders: folders, trash: trash)
    XCTAssertNil(folders.sequence(for: .root, owner: owner))
    XCTAssertFalse(trash.isEmptyingPending)
  }

  func testReturningToScreenUsesSessionOwnedStaleMarker() async {
    let session = PreferencesSessionFixture()
    session.isStale = true
    var mutations = 0
    let model = model(
      session: session,
      save: { _ in
        mutations += 1
        return PutioAccountPreferencesMutationResult(accountRefreshed: true)
      },
      refresh: {
        session.isStale = false
        return true
      })
    XCTAssertTrue(model.isStale)
    await model.save(.resetFolderSorts)
    XCTAssertEqual(mutations, 0)
    await model.retryRefresh()
    XCTAssertTrue(model.canSave)
  }

  func testRecreatedScreenBlocksWritesAndRefreshDuringSessionOwnedMutation() async {
    let session = PreferencesSessionFixture()
    session.isUpdating = true
    var writes = 0
    var reads = 0
    let model = model(
      session: session,
      save: { _ in
        writes += 1
        return PutioAccountPreferencesMutationResult(accountRefreshed: true)
      },
      refresh: {
        reads += 1
        return true
      })
    XCTAssertTrue(model.isSaving)
    XCTAssertTrue(model.isBusy)
    XCTAssertFalse(model.canSave)
    await model.save(.resetFolderSorts)
    await model.save(.trash(false))
    await model.retryRefresh()
    XCTAssertEqual(writes, 0)
    XCTAssertEqual(reads, 0)
    session.isUpdating = false
    XCTAssertFalse(model.isSaving)
    XCTAssertTrue(model.canSave)
    await model.save(.resetFolderSorts)
    XCTAssertEqual(writes, 1)
  }

  func testMutationSerializesOtherOperationsAndSurvivesCallerCancellation() async throws {
    let session = PreferencesSessionFixture()
    let gate = PreferencesRequestGate()
    defer { gate.cancel() }
    var mutations = 0
    var refreshes = 0
    let model = model(
      session: session,
      save: { _ in
        mutations += 1
        try await gate.wait()
        session.account = Self.account(sort: .sizeDescending)
        return PutioAccountPreferencesMutationResult(accountRefreshed: true)
      },
      refresh: {
        refreshes += 1
        return true
      })
    let saving = Task { await model.save(.defaultSort(.sizeDescending)) }
    defer { saving.cancel() }
    try await gate.waitForRequest()
    XCTAssertTrue(model.isBusy)
    XCTAssertEqual(model.account?.defaultSort, .nameAscending)
    saving.cancel()
    await model.save(.resetFolderSorts)
    await model.retryRefresh()
    XCTAssertEqual(mutations, 1)
    XCTAssertEqual(refreshes, 0)
    gate.finish()
    await saving.value
    XCTAssertEqual(model.account?.defaultSort, .sizeDescending)
    XCTAssertFalse(model.isBusy)
  }

  func testRefreshSerializesSavesAndDoesNotRepeatMutation() async throws {
    let session = PreferencesSessionFixture()
    let gate = PreferencesRequestGate()
    defer { gate.cancel() }
    var mutations = 0
    let model = model(
      session: session,
      save: { _ in
        mutations += 1
        return PutioAccountPreferencesMutationResult(accountRefreshed: true)
      },
      refresh: {
        do { try await gate.wait() } catch { return false }
        return true
      })
    let refreshing = Task { await model.retryRefresh() }
    defer { refreshing.cancel() }
    try await gate.waitForRequest()
    await model.save(.trash(false))
    XCTAssertEqual(mutations, 0)
    gate.finish()
    await refreshing.value
    XCTAssertFalse(model.isRefreshing)
  }

  private func model(
    session: PreferencesSessionFixture,
    save:
      @escaping @MainActor @Sendable (PutioAccountPreferenceMutation) async throws ->
      PutioAccountPreferencesMutationResult = { _ in
        PutioAccountPreferencesMutationResult(accountRefreshed: true)
      },
    refresh: @escaping @MainActor @Sendable () async -> Bool = { true }
  ) -> PutioAccountPreferencesModel {
    PutioAccountPreferencesModel(
      actions: PutioAccountPreferenceActions(
        save: save, refresh: refresh, account: { session.account }, isStale: { session.isStale },
        isUpdating: { session.isUpdating }))
  }

  fileprivate static func account(
    id: Int = 10, sort: PutioFolderSort = .nameAscending, trash: Bool = true, history: Bool = true
  ) -> PutioAccountSnapshot {
    PutioAccountSnapshot(
      id: id, username: "fixture", email: "fixture@example.invalid", suggestNextVideo: false,
      rememberVideoTime: false, defaultSort: sort, historyEnabled: history, trashEnabled: trash,
      storage: .init(availableBytes: 100, totalBytes: 200, usedBytes: 100))
  }
}

@MainActor
@Observable
private final class PreferencesSessionFixture {
  var account: PutioAccountSnapshot? = FilePreferencesTests.account()
  var isStale = false
  var isUpdating = false
}

@MainActor
private final class PreferencesRequestGate {
  private var continuation: CheckedContinuation<Void, any Error>?
  private var cancelled = false

  func wait() async throws {
    guard !cancelled else { throw CancellationError() }
    try await withCheckedThrowingContinuation { continuation = $0 }
  }

  func waitForRequest() async throws {
    let deadline = ContinuousClock.now.advanced(by: .seconds(5))
    while continuation == nil {
      guard ContinuousClock.now < deadline else {
        throw NSError(
          domain: "FilePreferencesTests", code: 1,
          userInfo: [NSLocalizedDescriptionKey: "Timed out waiting for preference request"])
      }
      try await Task.sleep(for: .milliseconds(1))
    }
  }

  func finish() {
    continuation?.resume()
    continuation = nil
  }

  func cancel() {
    cancelled = true
    continuation?.resume(throwing: CancellationError())
    continuation = nil
  }
}
