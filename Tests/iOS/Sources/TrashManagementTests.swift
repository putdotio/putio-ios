import Foundation
import PutioCore
import XCTest

@testable import Putio

@MainActor
private final class SuspendedTrashRefresh {
  private let initialPage: PutioTrashPage
  private var continuation: CheckedContinuation<PutioTrashPage, any Error>?
  private(set) var requestCount = 0

  init(initialPage: PutioTrashPage) {
    self.initialPage = initialPage
  }

  func load(cursor: String?) async throws -> PutioTrashPage {
    requestCount += 1
    if requestCount == 1 { return initialPage }
    return try await withCheckedThrowingContinuation { continuation = $0 }
  }

  func resume(with page: PutioTrashPage) {
    continuation?.resume(returning: page)
    continuation = nil
  }

  func fail(with error: any Error) {
    continuation?.resume(throwing: error)
    continuation = nil
  }
}

@MainActor
private final class SuspendedStorageRefresh {
  private var continuation: CheckedContinuation<Bool, Never>?
  private(set) var requestCount = 0
  private(set) var isStale = false

  func markStale() { isStale = true }

  func refresh() async -> Bool {
    requestCount += 1
    let refreshed = await withCheckedContinuation { continuation = $0 }
    if refreshed { isStale = false }
    return refreshed
  }

  func resume(with refreshed: Bool) {
    continuation?.resume(returning: refreshed)
    continuation = nil
  }
}

@MainActor
private final class ControlledTrashLoader {
  private var pending: [Int: CheckedContinuation<PutioTrashPage, any Error>] = [:]
  private(set) var requestCount = 0

  func load(cursor: String?) async throws -> PutioTrashPage {
    let request = requestCount
    requestCount += 1
    return try await withCheckedThrowingContinuation { pending[request] = $0 }
  }

  func succeed(request: Int, with page: PutioTrashPage) {
    pending.removeValue(forKey: request)?.resume(returning: page)
  }

  func fail(request: Int, with error: any Error) {
    pending.removeValue(forKey: request)?.resume(throwing: error)
  }
}

extension PutioTrashMutationResult {
  fileprivate static let refreshed = PutioTrashMutationResult(storageRefreshed: true)
  fileprivate static let storageStale = PutioTrashMutationResult(storageRefreshed: false)
}

@MainActor
private final class TrashActionsStub {
  var pages: [Result<PutioTrashPage, PutioRuntimeError>]
  var restoreResults: [Result<PutioTrashRestoreResult, PutioRuntimeError>]
  var deleteResults: [Result<PutioTrashMutationResult, PutioRuntimeError>]
  var emptyResults: [Result<PutioTrashMutationResult, PutioRuntimeError>]
  var storageRefreshResults: [Bool]
  private(set) var isStorageStale = false
  private(set) var loadedCursors: [String?] = []
  private(set) var restoredIDs: [PutioFileID] = []
  private(set) var deletedIDs: [PutioFileID] = []
  private(set) var emptyRequests = 0
  private(set) var storageRefreshRequests = 0

  init(
    pages: [Result<PutioTrashPage, PutioRuntimeError>],
    restoreResults: [Result<PutioTrashRestoreResult, PutioRuntimeError>] = [],
    deleteResults: [Result<PutioTrashMutationResult, PutioRuntimeError>] = [],
    emptyResults: [Result<PutioTrashMutationResult, PutioRuntimeError>] = [],
    storageRefreshResults: [Bool] = []
  ) {
    self.pages = pages
    self.restoreResults = restoreResults
    self.deleteResults = deleteResults
    self.emptyResults = emptyResults
    self.storageRefreshResults = storageRefreshResults
  }

  func load(cursor: String?) async throws -> PutioTrashPage {
    loadedCursors.append(cursor)
    guard !pages.isEmpty else { throw PutioRuntimeError.unknown }
    return try pages.removeFirst().get()
  }

  func restore(fileID: PutioFileID) async throws -> PutioTrashRestoreResult {
    restoredIDs.append(fileID)
    guard !restoreResults.isEmpty else { throw PutioRuntimeError.unknown }
    return try restoreResults.removeFirst().get()
  }

  func permanentlyDelete(fileID: PutioFileID) async throws -> PutioTrashMutationResult {
    deletedIDs.append(fileID)
    guard !deleteResults.isEmpty else { throw PutioRuntimeError.unknown }
    return record(try deleteResults.removeFirst().get())
  }

  func empty() async throws -> PutioTrashMutationResult {
    emptyRequests += 1
    guard !emptyResults.isEmpty else { throw PutioRuntimeError.unknown }
    return record(try emptyResults.removeFirst().get())
  }

  func refreshStorage() async -> Bool {
    storageRefreshRequests += 1
    let refreshed = storageRefreshResults.isEmpty ? true : storageRefreshResults.removeFirst()
    if refreshed { isStorageStale = false }
    return refreshed
  }

  // Mirrors PutioSessionStore: a committed mutation marks storage stale until
  // any later refresh succeeds.
  private func record(_ result: PutioTrashMutationResult) -> PutioTrashMutationResult {
    isStorageStale = !result.storageRefreshed
    return result
  }
}

@MainActor
final class TrashManagementTests: XCTestCase {
  func testInitialLoadAndContinuationDeduplicateItems() async {
    let first = trashItem(id: 91, name: "First.mkv")
    let second = trashItem(id: 92, name: "Second.pdf", kind: .pdf)
    let stub = TrashActionsStub(
      pages: [
        .success(page(items: [first], cursor: "next", totalCount: 2)),
        .success(page(items: [first, second], totalCount: 2)),
      ]
    )
    let model = model(stub)

    await model.loadIfNeeded()
    await model.loadMore()

    XCTAssertEqual(model.page?.items, [first, second])
    XCTAssertEqual(model.page?.nextCursor, nil)
    XCTAssertEqual(stub.loadedCursors.count, 2)
    XCTAssertNil(stub.loadedCursors[0])
    XCTAssertEqual(stub.loadedCursors[1], "next")
  }

  func testRestoreRemovesTrashItemAndReturnsAuthoritativeDestination() async {
    let trashedItem = trashItem(id: 91, name: "Restored.mkv", parentID: 5)
    var destinations: [PutioFileID?] = []
    let stub = TrashActionsStub(
      pages: [.success(page(items: [trashedItem], totalCount: 1))],
      restoreResults: [.success(.restored(destinationID: PutioFileID(rawValue: 7)))]
    )
    let model = model(stub) { destinations.append($0) }

    await model.loadIfNeeded()
    await model.restore(trashedItem)

    XCTAssertEqual(model.page?.items, [])
    XCTAssertEqual(stub.restoredIDs, [trashedItem.id])
    XCTAssertEqual(destinations, [PutioFileID(rawValue: 7)])
    XCTAssertEqual(model.mutationOutcome, .restored(trashedItem))
  }

  func testRestoreWithUnknownDestinationStillRemovesItemAndRequestsGlobalRefresh() async {
    let item = trashItem(id: 91, name: "Restored.mkv")
    var destinations: [PutioFileID?] = []
    let stub = TrashActionsStub(
      pages: [.success(page(items: [item], totalCount: 1))],
      restoreResults: [.success(.restoredDestinationUnknown)]
    )
    let model = model(stub) { destinations.append($0) }

    await model.loadIfNeeded()
    await model.restore(item)

    XCTAssertEqual(model.page?.items, [])
    XCTAssertEqual(destinations.count, 1)
    XCTAssertNil(destinations[0])
    XCTAssertEqual(model.mutationOutcome, .restored(item))
  }

  func testRestoreFailurePreservesItemAndDoesNotRequestBrowserRefresh() async {
    let item = trashItem(id: 91, name: "Keep.mkv")
    var destinations: [PutioFileID?] = []
    let stub = TrashActionsStub(
      pages: [.success(page(items: [item], totalCount: 1))],
      restoreResults: [.failure(.transient)]
    )
    let model = model(stub) { destinations.append($0) }

    await model.loadIfNeeded()
    await model.restore(item)

    XCTAssertEqual(model.page?.items, [item])
    XCTAssertTrue(destinations.isEmpty)
    guard case .failed(.restore(let failedItem), _) = model.mutationOutcome else {
      return XCTFail("expected restore failure")
    }
    XCTAssertEqual(failedItem, item)
  }

  func testPermanentDeleteFailurePreservesItemAndCanBeRetried() async {
    let item = trashItem(id: 91, name: "Keep.pdf", kind: .pdf)
    let stub = TrashActionsStub(
      pages: [.success(page(items: [item], totalCount: 1))],
      deleteResults: [.failure(.transient), .success(.refreshed)]
    )
    let model = model(stub)

    await model.loadIfNeeded()
    await model.permanentlyDelete(item)

    XCTAssertEqual(model.page?.items, [item])
    guard case .failed(.permanentlyDelete(let failedItem), let failure) = model.mutationOutcome
    else { return XCTFail("expected permanent-delete failure") }
    XCTAssertEqual(failedItem, item)
    XCTAssertEqual(failure.title, "Could not permanently delete item")

    await model.permanentlyDelete(item)

    XCTAssertEqual(model.page?.items, [])
    XCTAssertEqual(stub.deletedIDs, [item.id, item.id])
    XCTAssertEqual(model.mutationOutcome, .permanentlyDeleted(item))
  }

  func testRefreshSerializesMutationAndCannotResurrectRemovedRows() async {
    let item = trashItem(id: 91, name: "Keep.pdf", kind: .pdf)
    let refreshedItem = trashItem(id: 92, name: "Refreshed.pdf", kind: .pdf)
    let initialPage = page(items: [item], totalCount: 1)
    let refreshedPage = page(items: [refreshedItem], totalCount: 1)
    let loader = SuspendedTrashRefresh(initialPage: initialPage)
    var deletedIDs: [PutioFileID] = []
    let model = PutioTrashModel(
      actions: PutioTrashActions(
        load: { try await loader.load(cursor: $0) },
        restore: { _ in throw PutioRuntimeError.unknown },
        permanentlyDelete: {
          deletedIDs.append($0)
          return .refreshed
        },
        empty: { .refreshed }
      )
    )

    await model.loadIfNeeded()
    let refresh = Task { await model.refresh() }
    await waitUntil("the suspended refresh started") { loader.requestCount >= 2 }

    XCTAssertTrue(model.isRefreshing)
    XCTAssertFalse(model.canMutate)
    await model.permanentlyDelete(item)
    XCTAssertTrue(deletedIDs.isEmpty)
    XCTAssertEqual(model.page, initialPage)

    loader.resume(with: refreshedPage)
    await refresh.value

    XCTAssertFalse(model.isRefreshing)
    XCTAssertEqual(model.page, refreshedPage)
  }

  func testRefreshFailureRetainsLoadedPageAndRetryClearsFailure() async {
    for items in [[], [trashItem(id: 91, name: "Keep.pdf", kind: .pdf)]] {
      let original = page(
        items: items, cursor: items.isEmpty ? nil : "next", totalCount: items.isEmpty ? 0 : 2)
      let replacement = page(items: [trashItem(id: 92, name: "New.pdf")], totalCount: 1)
      let stub = TrashActionsStub(pages: [
        .success(original), .failure(.transient), .success(replacement),
      ])
      let model = model(stub)

      await model.loadIfNeeded()
      await model.refresh()

      XCTAssertEqual(model.page, original)
      XCTAssertEqual(model.refreshFailure?.title, "Could not refresh Trash")
      XCTAssertTrue(model.canMutate)

      await model.refresh()

      XCTAssertEqual(model.page, replacement)
      XCTAssertNil(model.refreshFailure)
    }
  }

  func testRemovingWithPendingContinuationReloadsInsteadOfReusingTheCursor() async {
    let item = trashItem(id: 91, name: "First.pdf", kind: .pdf)
    let second = trashItem(id: 92, name: "Second.pdf", kind: .pdf)
    let reloaded = page(items: [second], cursor: "fresh", totalCount: 1)
    let stub = TrashActionsStub(
      pages: [.success(page(items: [item], cursor: "next", totalCount: 2)), .success(reloaded)],
      deleteResults: [.success(.refreshed)],
      emptyResults: [.success(.refreshed)]
    )
    let model = model(stub)

    await model.loadIfNeeded()
    await model.permanentlyDelete(item)

    XCTAssertEqual(stub.loadedCursors, [nil, nil], "the pre-mutation cursor must not be replayed")
    XCTAssertEqual(model.page, reloaded)
    XCTAssertEqual(model.mutationOutcome, .permanentlyDeleted(item))

    await model.empty()

    XCTAssertEqual(stub.emptyRequests, 1)
    XCTAssertEqual(model.page, page(items: [], totalCount: 0, sizeBytes: 0))
    XCTAssertEqual(model.mutationOutcome, .emptied())
  }

  func testEmptyTrashRequiresSuccessfulMutationBeforeClearingItems() async {
    let item = trashItem(id: 91, name: "Last.mkv")
    let stub = TrashActionsStub(
      pages: [
        .success(page(items: [item], cursor: "next", totalCount: 2)),
        .failure(.transient), .failure(.transient),
      ],
      emptyResults: [.failure(.rateLimited), .success(.refreshed)]
    )
    let model = model(stub)

    await model.loadIfNeeded()
    await model.refresh()
    await model.loadMore()
    XCTAssertNotNil(model.refreshFailure)
    XCTAssertNotNil(model.paginationFailure)
    await model.empty()

    XCTAssertEqual(model.page?.items, [item])
    guard case .failed(.empty, let failure) = model.mutationOutcome else {
      return XCTFail("expected empty-Trash failure")
    }
    XCTAssertEqual(failure.message, "put.io is receiving too many requests. Try again shortly.")

    await model.empty()

    XCTAssertEqual(model.page, page(items: [], totalCount: 0, sizeBytes: 0))
    XCTAssertEqual(stub.emptyRequests, 2)
    XCTAssertEqual(model.mutationOutcome, .emptied())
    XCTAssertNil(model.refreshFailure)
    XCTAssertNil(model.paginationFailure)
  }

  func testStaleStorageAfterDeletionIsReportedAndRetriedOnRefresh() async {
    let item = trashItem(id: 91, name: "Keep.pdf", kind: .pdf)
    let remaining = page(items: [], totalCount: 0)
    let stub = TrashActionsStub(
      pages: [
        .success(page(items: [item], totalCount: 1)), .success(remaining), .success(remaining),
      ],
      deleteResults: [.success(.storageStale)],
      storageRefreshResults: [false, true]
    )
    let model = model(stub)

    await model.loadIfNeeded()
    await model.permanentlyDelete(item)

    XCTAssertEqual(model.page?.items, [])
    XCTAssertEqual(model.mutationOutcome, .permanentlyDeleted(item, storageRefreshed: false))
    XCTAssertTrue(model.isStorageStale)

    await model.refresh()
    XCTAssertEqual(stub.storageRefreshRequests, 1)
    XCTAssertTrue(model.isStorageStale, "a failed storage retry stays pending")

    await model.refresh()
    XCTAssertEqual(stub.storageRefreshRequests, 2)
    XCTAssertFalse(model.isStorageStale)

    await model.refresh()
    XCTAssertEqual(stub.storageRefreshRequests, 2, "refresh stops retrying once storage is current")
  }

  func testReentryDuringCancelledInitialLoadRestartsTheLoad() async {
    let loader = ControlledTrashLoader()
    let loaded = page(items: [trashItem(id: 91, name: "A.pdf", kind: .pdf)], totalCount: 1)
    let model = PutioTrashModel(
      actions: PutioTrashActions(
        load: { try await loader.load(cursor: $0) },
        restore: { _ in throw PutioRuntimeError.unknown },
        permanentlyDelete: { _ in .refreshed },
        empty: { .refreshed }
      )
    )

    let firstVisit = Task { await model.loadIfNeeded() }
    await waitUntil("the first load started") { loader.requestCount >= 1 }
    firstVisit.cancel()

    // The next visit starts before the cancelled attempt finishes unwinding.
    let secondVisit = Task { await model.loadIfNeeded() }
    await waitUntil("the second load started") { loader.requestCount >= 2 }
    loader.succeed(request: 1, with: loaded)
    await secondVisit.value
    XCTAssertEqual(model.state, .loaded(loaded))

    loader.fail(request: 0, with: CancellationError())
    await firstVisit.value
    XCTAssertEqual(model.state, .loaded(loaded), "the late unwind must not clobber the result")
    XCTAssertFalse(model.isRefreshing)
    XCTAssertTrue(model.canMutate)
  }

  func testTombstonesSurviveUntilACompleteListingConfirmsTheRemoval() async {
    let a = trashItem(id: 91, name: "A.pdf", kind: .pdf)
    let b = trashItem(id: 92, name: "B.pdf", kind: .pdf)
    let c = trashItem(id: 93, name: "C.pdf", kind: .pdf)
    let stub = TrashActionsStub(
      pages: [
        .success(page(items: [a], cursor: "n1", totalCount: 3)),
        .success(page(items: [b], cursor: "n2", totalCount: 3)),
        // Fresh first page after deleting b, then a lagging continuation.
        .success(page(items: [a], cursor: "f1", totalCount: 2)),
        .success(page(items: [b, c], totalCount: 2)),
        // A lagging full refresh still lists b.
        .success(page(items: [a, b, c], totalCount: 3)),
        // The server catches up and omits b: the tombstone is released.
        .success(page(items: [a, c], totalCount: 2)),
        // If b is trashed again later it may show up again.
        .success(page(items: [a, b, c], totalCount: 3)),
      ],
      deleteResults: [.success(.refreshed)]
    )
    let model = model(stub)

    await model.loadIfNeeded()
    await model.loadMore()
    XCTAssertEqual(model.page?.items, [a, b])

    await model.permanentlyDelete(b)
    XCTAssertEqual(model.page?.items, [a])
    XCTAssertEqual(model.page?.nextCursor, "f1")

    await model.loadMore()
    XCTAssertEqual(model.page?.items, [a, c], "a lagging continuation cannot resurrect b")
    XCTAssertEqual(model.page?.totalCount, 2, "aggregates are the server's, not row counts")

    await model.refresh()
    XCTAssertEqual(model.page?.items, [a, c], "a lagging refresh cannot resurrect b either")

    await model.refresh()
    XCTAssertEqual(model.page?.items, [a, c])

    await model.refresh()
    XCTAssertEqual(model.page?.items, [a, b, c], "a confirmed removal no longer hides b")
    XCTAssertEqual(stub.loadedCursors, [nil, "n1", nil, "f1", nil, nil, nil])
  }

  func testEmptyingTombstonesUnloadedItemsAgainstALaggingRefresh() async {
    let a = trashItem(id: 91, name: "A.pdf", kind: .pdf)
    // Never loaded before emptying, but trashed before it.
    let unloaded = trashItem(id: 92, name: "B.pdf", kind: .pdf)
    // Trashed after emptying: a genuinely new item that must show up.
    let later = trashItem(
      id: 93, name: "C.pdf", kind: .pdf, deletedAt: Date(timeIntervalSince1970: 1_756_723_201))
    let stub = TrashActionsStub(
      pages: [
        .success(page(items: [a], cursor: "n1", totalCount: 2)),
        .success(page(items: [a, unloaded], totalCount: 2)),
        .success(page(items: [later], totalCount: 1)),
        .success(page(items: [later], totalCount: 1)),
      ],
      emptyResults: [.success(.refreshed)]
    )
    let model = model(stub)

    await model.loadIfNeeded()
    await model.empty()
    XCTAssertEqual(model.page?.items, [])

    await model.refresh()
    XCTAssertEqual(model.page?.items, [], "a lagging refresh cannot resurrect unloaded rows")

    await model.refresh()
    XCTAssertEqual(model.page?.items, [], "the second listing still counts as lag")

    await model.refresh()
    XCTAssertEqual(model.page?.items, [later], "items trashed after emptying appear once trusted")
  }

  func testTombstonesSurviveReopeningTrashAndReleaseARetrashedGeneration() async {
    let a = trashItem(id: 91, name: "A.pdf", kind: .pdf)
    let b = trashItem(id: 92, name: "B.pdf", kind: .pdf)
    let bAgain = trashItem(
      id: 92, name: "B.pdf", kind: .pdf, deletedAt: Date(timeIntervalSince1970: 1_756_809_600))
    let shared = PutioTrashReconciliation()
    let first = TrashActionsStub(
      pages: [.success(page(items: [a, b], totalCount: 2))],
      deleteResults: [.success(.refreshed)]
    )
    let firstVisit = model(first, reconciliation: shared)
    await firstVisit.loadIfNeeded()
    await firstVisit.permanentlyDelete(b)
    XCTAssertEqual(firstVisit.page?.items, [a])

    // Pop and reopen: a new model, the same reconciliation state.
    let second = TrashActionsStub(pages: [
      .success(page(items: [a, b], totalCount: 2)),
      .success(page(items: [a, bAgain], totalCount: 2)),
    ])
    let secondVisit = model(second, reconciliation: shared)
    await secondVisit.loadIfNeeded()
    XCTAssertEqual(secondVisit.page?.items, [a], "a lagging listing cannot resurrect b")

    await secondVisit.refresh()
    XCTAssertEqual(
      secondVisit.page?.items, [a, bAgain], "the same file trashed again is a new generation")
  }

  func testRestoreCancelledDuringDestinationLookupStillReconciles() async {
    let item = trashItem(id: 91, name: "Restored.mkv")
    var destinations: [PutioFileID?] = []
    let stub = TrashActionsStub(
      pages: [.success(page(items: [item], totalCount: 1))],
      restoreResults: [.success(.restoredLookupCancelled)]
    )
    let model = model(stub) { destinations.append($0) }

    await model.loadIfNeeded()
    await model.restore(item)

    XCTAssertEqual(model.page?.items, [])
    XCTAssertEqual(destinations, [nil], "a committed restore still refreshes the browser")
    XCTAssertEqual(model.mutationOutcome, .restored(item))
  }

  func testRestoreCancelledBeforeCommitLeavesTheItemAlone() async {
    let item = trashItem(id: 91, name: "Restored.mkv")
    var destinations: [PutioFileID?] = []
    let shared = PutioTrashReconciliation()
    let model = PutioTrashModel(
      actions: PutioTrashActions(
        load: { _ in self.page(items: [item], totalCount: 1) },
        restore: { _ in throw CancellationError() },
        permanentlyDelete: { _ in .refreshed },
        empty: { .refreshed }
      ),
      reconciliation: shared
    ) { destinations.append($0) }

    await model.loadIfNeeded()
    await model.restore(item)

    XCTAssertEqual(model.page?.items, [item], "an uncommitted restore removes nothing")
    XCTAssertTrue(destinations.isEmpty)
    XCTAssertNil(model.mutationOutcome)
    XCTAssertFalse(shared.isRemoved(item), "no tombstone for an uncommitted restore")
  }

  func testRestoreNotifiesTheBrowserBeforeRepairingPagination() async {
    let item = trashItem(id: 91, name: "Restored.mkv")
    let loader = SuspendedTrashRefresh(
      initialPage: page(items: [item], cursor: "next", totalCount: 2))
    var destinations: [PutioFileID?] = []
    let model = PutioTrashModel(
      actions: PutioTrashActions(
        load: { try await loader.load(cursor: $0) },
        restore: { _ in .restored(destinationID: PutioFileID(rawValue: 7)) },
        permanentlyDelete: { _ in .refreshed },
        empty: { .refreshed }
      )
    ) { destinations.append($0) }

    await model.loadIfNeeded()
    let restore = Task { await model.restore(item) }
    await waitUntil("the pagination repair started") { loader.requestCount >= 2 }

    XCTAssertEqual(destinations, [PutioFileID(rawValue: 7)], "browser refresh is not blocked")
    loader.fail(with: PutioRuntimeError.transient)
    await restore.value
    XCTAssertEqual(model.mutationOutcome, .restored(item))
  }

  func testTombstonesReleaseAfterTheServerConsistentlyReportsTheItem() async {
    let a = trashItem(id: 91, name: "A.pdf", kind: .pdf)
    let b = trashItem(id: 92, name: "B.pdf", kind: .pdf)
    let stub = TrashActionsStub(
      pages: [
        .success(page(items: [a, b], totalCount: 2)),
        .success(page(items: [a, b], totalCount: 2)),
        .success(page(items: [a, b], totalCount: 2)),
        .success(page(items: [a, b], totalCount: 2)),
      ],
      deleteResults: [.success(.refreshed)]
    )
    let model = model(stub)

    await model.loadIfNeeded()
    await model.permanentlyDelete(b)
    XCTAssertEqual(model.page?.items, [a])

    await model.refresh()
    XCTAssertEqual(model.page?.items, [a], "first consistent listing is still treated as lag")
    await model.refresh()
    XCTAssertEqual(model.page?.items, [a], "second listing releases the tombstone afterwards")
    await model.refresh()
    XCTAssertEqual(model.page?.items, [a, b], "the server is trusted; nothing hides forever")
  }

  func testEmptyingCutoffReleasesAfterConsistentListings() async {
    let a = trashItem(id: 91, name: "A.pdf", kind: .pdf)
    // Same second as the emptied rows: indistinguishable by timestamp.
    let sameSecond = trashItem(id: 95, name: "New.pdf", kind: .pdf)
    let stub = TrashActionsStub(
      pages: [
        .success(page(items: [a], totalCount: 1)),
        .success(page(items: [sameSecond], totalCount: 1)),
        .success(page(items: [sameSecond], totalCount: 1)),
        .success(page(items: [sameSecond], totalCount: 1)),
      ],
      emptyResults: [.success(.refreshed)]
    )
    let model = model(stub)

    await model.loadIfNeeded()
    await model.empty()

    await model.refresh()
    XCTAssertEqual(model.page?.items, [])
    await model.refresh()
    XCTAssertEqual(model.page?.items, [])
    await model.refresh()
    XCTAssertEqual(model.page?.items, [sameSecond], "a same-second new item is not hidden forever")
  }

  func testEmptyingAFilteredFirstPageStillProtectsUnloadedRows() async {
    let a = trashItem(id: 91, name: "A.pdf", kind: .pdf)
    let unloaded = trashItem(id: 92, name: "B.pdf", kind: .pdf)
    let stub = TrashActionsStub(
      pages: [
        .success(page(items: [a], cursor: "n1", totalCount: 2)),
        // After deleting a, the reload still lists a (lagging) with a cursor:
        // the visible page is empty but Trash is not.
        .success(page(items: [a], cursor: "l1", totalCount: 2)),
        // Lagging post-empty listing.
        .success(page(items: [a, unloaded], totalCount: 2)),
        .success(page(items: [], totalCount: 0)),
      ],
      deleteResults: [.success(.refreshed)],
      emptyResults: [.success(.refreshed)]
    )
    let model = model(stub)

    await model.loadIfNeeded()
    await model.permanentlyDelete(a)
    XCTAssertEqual(model.page?.items, [])
    XCTAssertEqual(model.page?.nextCursor, "l1")

    await model.empty()
    await model.refresh()
    XCTAssertEqual(model.page?.items, [], "filtered rows still bound the emptying cutoff")

    await model.refresh()
    XCTAssertEqual(model.page, page(items: [], totalCount: 0, sizeBytes: 0))
  }

  func testReappearanceSupersedesACancelledRefresh() async {
    let a = trashItem(id: 91, name: "A.pdf", kind: .pdf)
    let b = trashItem(id: 92, name: "B.pdf", kind: .pdf)
    let loader = ControlledTrashLoader()
    let model = PutioTrashModel(
      actions: PutioTrashActions(
        load: { try await loader.load(cursor: $0) },
        restore: { _ in throw PutioRuntimeError.unknown },
        permanentlyDelete: { _ in .refreshed },
        empty: { .refreshed }
      )
    )

    let firstAppearance = Task { await model.refreshOnAppear() }
    await waitUntil("the initial load started") { loader.requestCount >= 1 }
    loader.succeed(request: 0, with: page(items: [a], totalCount: 1))
    await firstAppearance.value

    // Leaving the tab cancels the appearance refresh mid-flight.
    let leaving = Task { await model.refreshOnAppear() }
    await waitUntil("the cancelled refresh started") { loader.requestCount >= 2 }
    leaving.cancel()

    // Returning before the cancelled request unwinds must still refresh.
    let returning = Task { await model.refreshOnAppear() }
    await waitUntil("the superseding refresh started") { loader.requestCount >= 3 }
    loader.succeed(request: 2, with: page(items: [a, b], totalCount: 2))
    await returning.value
    XCTAssertEqual(model.page?.items, [a, b])

    loader.fail(request: 1, with: CancellationError())
    await leaving.value
    XCTAssertEqual(model.page?.items, [a, b], "the late unwind must not clobber the result")
    XCTAssertFalse(model.isRefreshing)
  }

  func testReloadAfterMutationNeverResurrectsTheCommittedItem() async {
    let item = trashItem(id: 91, name: "First.pdf", kind: .pdf)
    let second = trashItem(id: 92, name: "Second.pdf", kind: .pdf)
    let lagging = page(items: [item, second], cursor: "fresh", totalCount: 2, sizeBytes: 4096)
    let stub = TrashActionsStub(
      pages: [.success(page(items: [item], cursor: "next", totalCount: 2)), .success(lagging)],
      deleteResults: [.success(.refreshed)]
    )
    let model = model(stub)

    await model.loadIfNeeded()
    await model.permanentlyDelete(item)

    XCTAssertEqual(model.page?.items, [second])
    XCTAssertEqual(model.page?.nextCursor, "fresh")
    XCTAssertEqual(model.page?.totalCount, 2, "server aggregates pass through unchanged")
    XCTAssertEqual(model.page?.sizeBytes, 4096)
  }

  func testRemovingWithPendingContinuationDropsTheCursorWhenReloadFails() async {
    let item = trashItem(id: 91, name: "First.pdf", kind: .pdf)
    let stub = TrashActionsStub(
      pages: [.success(page(items: [item], cursor: "next", totalCount: 2)), .failure(.transient)],
      deleteResults: [.success(.refreshed)]
    )
    let model = model(stub)

    await model.loadIfNeeded()
    await model.permanentlyDelete(item)

    XCTAssertEqual(model.page?.items, [])
    XCTAssertNil(model.page?.nextCursor)
    XCTAssertEqual(model.page?.totalCount, 1)
    XCTAssertEqual(model.refreshFailure?.title, "Could not refresh Trash")
    XCTAssertEqual(model.mutationOutcome, .permanentlyDeleted(item))

    await model.loadMore()
    XCTAssertEqual(stub.loadedCursors, [nil, nil], "a dropped cursor cannot be loaded")
  }

  func testRemovingWithoutContinuationDoesNotReload() async {
    let item = trashItem(id: 91, name: "Only.pdf", kind: .pdf)
    let stub = TrashActionsStub(
      pages: [.success(page(items: [item], totalCount: 1))],
      deleteResults: [.success(.refreshed)]
    )
    let model = model(stub)

    await model.loadIfNeeded()
    await model.permanentlyDelete(item)

    XCTAssertEqual(stub.loadedCursors, [nil])
    XCTAssertEqual(model.page, page(items: [], totalCount: 0, sizeBytes: 0))
  }

  func testStorageRetryIsVisibleUntilItSucceedsAndLaterRefreshClearsIt() async {
    let first = trashItem(id: 91, name: "First.pdf", kind: .pdf)
    let second = trashItem(id: 92, name: "Second.pdf", kind: .pdf)
    let stub = TrashActionsStub(
      pages: [.success(page(items: [first, second], totalCount: 2))],
      deleteResults: [.success(.storageStale), .success(.refreshed)],
      storageRefreshResults: [false, true]
    )
    let model = model(stub)

    await model.loadIfNeeded()
    await model.permanentlyDelete(first)
    XCTAssertEqual(model.storageFailure?.title, "Storage totals are out of date")

    await model.retryStorageRefresh()
    XCTAssertEqual(stub.storageRefreshRequests, 1)
    XCTAssertNotNil(model.storageFailure, "a failed retry stays visible")

    await model.retryStorageRefresh()
    XCTAssertEqual(stub.storageRefreshRequests, 2)
    XCTAssertNil(model.storageFailure)

    await model.retryStorageRefresh()
    XCTAssertEqual(stub.storageRefreshRequests, 2, "no retry once storage is current")
  }

  func testStorageRetrySerializesAndLocksMutations() async {
    let item = trashItem(id: 91, name: "First.pdf", kind: .pdf)
    let gate = SuspendedStorageRefresh()
    var deletes = 0
    let model = PutioTrashModel(
      actions: PutioTrashActions(
        load: { _ in self.page(items: [item], totalCount: 1) },
        restore: { _ in throw PutioRuntimeError.unknown },
        permanentlyDelete: { _ in
          deletes += 1
          return .refreshed
        },
        empty: { .refreshed },
        refreshStorage: { await gate.refresh() },
        isStorageStale: { gate.isStale }
      )
    )

    await model.loadIfNeeded()
    gate.markStale()
    let first = Task { await model.retryStorageRefresh() }
    await waitUntil("the storage retry started") { gate.requestCount >= 1 }
    XCTAssertTrue(model.isRefreshingStorage)
    XCTAssertFalse(model.canMutate)

    await model.retryStorageRefresh()
    await model.permanentlyDelete(item)
    await model.refresh()
    XCTAssertEqual(gate.requestCount, 1, "overlapping retries must not start new requests")
    XCTAssertEqual(deletes, 0, "mutations wait for the storage retry")

    gate.resume(with: true)
    await first.value
    XCTAssertFalse(model.isRefreshingStorage)
    XCTAssertTrue(model.canMutate)
    XCTAssertNil(model.storageFailure)
  }

  func testLaterSuccessfulMutationClearsStaleStorage() async {
    let first = trashItem(id: 91, name: "First.pdf", kind: .pdf)
    let second = trashItem(id: 92, name: "Second.pdf", kind: .pdf)
    let stub = TrashActionsStub(
      pages: [.success(page(items: [first, second], totalCount: 2))],
      deleteResults: [.success(.storageStale), .success(.refreshed)]
    )
    let model = model(stub)

    await model.loadIfNeeded()
    await model.permanentlyDelete(first)
    XCTAssertTrue(model.isStorageStale)

    await model.permanentlyDelete(second)
    XCTAssertFalse(model.isStorageStale, "the latest snapshot covers earlier deletions")
    XCTAssertEqual(model.mutationOutcome, .permanentlyDeleted(second))

    await model.refresh()
    XCTAssertEqual(stub.storageRefreshRequests, 0)
  }

  func testEmptyingWithStaleStorageReportsIt() async {
    let item = trashItem(id: 91, name: "Keep.pdf", kind: .pdf)
    let stub = TrashActionsStub(
      pages: [.success(page(items: [item], totalCount: 1))],
      emptyResults: [.success(.storageStale)]
    )
    let model = model(stub)

    await model.loadIfNeeded()
    await model.empty()

    XCTAssertEqual(model.page?.items, [])
    XCTAssertEqual(model.mutationOutcome, .emptied(storageRefreshed: false))
    XCTAssertTrue(model.isStorageStale)
  }

  func testCancelledRefreshRetryKeepsTheVisibleFailure() async {
    let item = trashItem(id: 91, name: "Keep.pdf", kind: .pdf)
    let original = page(items: [item], totalCount: 1)
    let loader = SuspendedTrashRefresh(initialPage: original)
    var loads = 0
    let model = PutioTrashModel(
      actions: PutioTrashActions(
        load: { cursor in
          loads += 1
          if loads == 2 { throw PutioRuntimeError.transient }
          return try await loader.load(cursor: cursor)
        },
        restore: { _ in throw PutioRuntimeError.unknown },
        permanentlyDelete: { _ in .refreshed },
        empty: { .refreshed }
      )
    )

    await model.loadIfNeeded()
    await model.refresh()
    XCTAssertEqual(model.refreshFailure?.title, "Could not refresh Trash")

    let retry = Task { await model.refresh() }
    await waitUntil("the suspended refresh started") { loader.requestCount >= 2 }
    XCTAssertNil(model.refreshFailure, "the in-flight retry hides the failure")
    retry.cancel()
    loader.fail(with: CancellationError())
    await retry.value

    XCTAssertEqual(model.page, original)
    XCTAssertEqual(model.refreshFailure?.title, "Could not refresh Trash")
    XCTAssertTrue(model.canMutate)
  }

  /// Yields until `condition` holds, failing the test instead of hanging the
  /// job when the awaited asynchronous step never starts.
  private func waitUntil(
    _ description: String,
    file: StaticString = #filePath,
    line: UInt = #line,
    _ condition: () -> Bool
  ) async {
    for _ in 0..<2_000 where !condition() {
      await Task.yield()
    }
    XCTAssertTrue(condition(), "timed out waiting for \(description)", file: file, line: line)
  }

  private func model(
    _ stub: TrashActionsStub,
    reconciliation: PutioTrashReconciliation? = nil,
    onRestored: @escaping PutioTrashDidRestore = { _ in }
  ) -> PutioTrashModel {
    PutioTrashModel(
      actions: PutioTrashActions(
        load: { try await stub.load(cursor: $0) },
        restore: { try await stub.restore(fileID: $0) },
        permanentlyDelete: { try await stub.permanentlyDelete(fileID: $0) },
        empty: { try await stub.empty() },
        refreshStorage: { await stub.refreshStorage() },
        isStorageStale: { stub.isStorageStale }
      ),
      reconciliation: reconciliation,
      onRestored: onRestored
    )
  }

  private func page(
    items: [PutioTrashItem],
    cursor: String? = nil,
    totalCount: Int? = nil,
    sizeBytes: Int64? = nil
  ) -> PutioTrashPage {
    PutioTrashPage(
      items: items,
      nextCursor: cursor,
      totalCount: totalCount,
      sizeBytes: sizeBytes ?? items.reduce(0) { $0 + $1.sizeBytes }
    )
  }

  private func trashItem(
    id: Int,
    name: String,
    kind: PutioFileKind = .video,
    parentID: Int = 7,
    deletedAt: Date = Date(timeIntervalSince1970: 1_756_723_200)
  ) -> PutioTrashItem {
    PutioTrashItem(
      id: PutioFileID(rawValue: id),
      parentID: PutioFileID(rawValue: parentID),
      name: name,
      kind: kind,
      sizeBytes: 2_048,
      deletedAt: deletedAt,
      expiresAt: Date(timeIntervalSince1970: 1_759_315_200)
    )
  }

}
