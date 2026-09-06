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
    XCTAssertNil(cursor)
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
    return try deleteResults.removeFirst().get()
  }

  func empty() async throws -> PutioTrashMutationResult {
    emptyRequests += 1
    guard !emptyResults.isEmpty else { throw PutioRuntimeError.unknown }
    return try emptyResults.removeFirst().get()
  }

  func refreshStorage() async -> Bool {
    storageRefreshRequests += 1
    guard !storageRefreshResults.isEmpty else { return true }
    return storageRefreshResults.removeFirst()
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
    while loader.requestCount < 2 { await Task.yield() }

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

  func testRemovingLoadedPrefixKeepsContinuationAndEmptyTrashFeedback() async {
    let item = trashItem(id: 91, name: "First.pdf", kind: .pdf)
    let stub = TrashActionsStub(
      pages: [.success(page(items: [item], cursor: "next", totalCount: 2))],
      deleteResults: [.success(.refreshed)],
      emptyResults: [.success(.refreshed)]
    )
    let model = model(stub)

    await model.loadIfNeeded()
    await model.permanentlyDelete(item)

    XCTAssertEqual(model.page?.items, [])
    XCTAssertEqual(model.page?.nextCursor, "next")
    XCTAssertEqual(model.page?.totalCount, 1)

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
    while loader.requestCount < 2 { await Task.yield() }
    XCTAssertNil(model.refreshFailure, "the in-flight retry hides the failure")
    retry.cancel()
    loader.fail(with: CancellationError())
    await retry.value

    XCTAssertEqual(model.page, original)
    XCTAssertEqual(model.refreshFailure?.title, "Could not refresh Trash")
    XCTAssertTrue(model.canMutate)
  }

  private func model(
    _ stub: TrashActionsStub,
    onRestored: @escaping PutioTrashDidRestore = { _ in }
  ) -> PutioTrashModel {
    PutioTrashModel(
      actions: PutioTrashActions(
        load: { try await stub.load(cursor: $0) },
        restore: { try await stub.restore(fileID: $0) },
        permanentlyDelete: { try await stub.permanentlyDelete(fileID: $0) },
        empty: { try await stub.empty() },
        refreshStorage: { await stub.refreshStorage() }
      ),
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
    parentID: Int = 7
  ) -> PutioTrashItem {
    PutioTrashItem(
      id: PutioFileID(rawValue: id),
      parentID: PutioFileID(rawValue: parentID),
      name: name,
      kind: kind,
      sizeBytes: 2_048,
      deletedAt: Date(timeIntervalSince1970: 1_756_723_200),
      expiresAt: Date(timeIntervalSince1970: 1_759_315_200)
    )
  }

}
