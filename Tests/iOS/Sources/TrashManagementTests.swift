import Foundation
import PutioCore
import XCTest

@testable import Putio

@MainActor
private final class TrashActionsStub {
  var pages: [Result<PutioTrashPage, PutioRuntimeError>]
  var restoreResults: [Result<PutioFileItem, PutioRuntimeError>]
  var deleteResults: [Result<Void, PutioRuntimeError>]
  var emptyResults: [Result<Void, PutioRuntimeError>]
  private(set) var loadedCursors: [String?] = []
  private(set) var restoredIDs: [PutioFileID] = []
  private(set) var deletedIDs: [PutioFileID] = []
  private(set) var emptyRequests = 0

  init(
    pages: [Result<PutioTrashPage, PutioRuntimeError>],
    restoreResults: [Result<PutioFileItem, PutioRuntimeError>] = [],
    deleteResults: [Result<Void, PutioRuntimeError>] = [],
    emptyResults: [Result<Void, PutioRuntimeError>] = []
  ) {
    self.pages = pages
    self.restoreResults = restoreResults
    self.deleteResults = deleteResults
    self.emptyResults = emptyResults
  }

  func load(cursor: String?) async throws -> PutioTrashPage {
    loadedCursors.append(cursor)
    guard !pages.isEmpty else { throw PutioRuntimeError.unknown }
    return try pages.removeFirst().get()
  }

  func restore(fileID: PutioFileID) async throws -> PutioFileItem {
    restoredIDs.append(fileID)
    guard !restoreResults.isEmpty else { throw PutioRuntimeError.unknown }
    return try restoreResults.removeFirst().get()
  }

  func permanentlyDelete(fileID: PutioFileID) async throws {
    deletedIDs.append(fileID)
    guard !deleteResults.isEmpty else { throw PutioRuntimeError.unknown }
    try deleteResults.removeFirst().get()
  }

  func empty() async throws {
    emptyRequests += 1
    guard !emptyResults.isEmpty else { throw PutioRuntimeError.unknown }
    try emptyResults.removeFirst().get()
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
    let restoredItem = fileItem(id: 91, name: "Restored.mkv", parentID: 7)
    let stub = TrashActionsStub(
      pages: [.success(page(items: [trashedItem], totalCount: 1))],
      restoreResults: [.success(restoredItem)]
    )
    let model = model(stub)

    await model.loadIfNeeded()
    await model.restore(trashedItem)

    XCTAssertEqual(model.page?.items, [])
    XCTAssertEqual(stub.restoredIDs, [trashedItem.id])
    XCTAssertEqual(
      model.mutationOutcome, .restored(trashedItem, destinationID: restoredItem.parentID))
  }

  func testPermanentDeleteFailurePreservesItemAndCanBeRetried() async {
    let item = trashItem(id: 91, name: "Keep.pdf", kind: .pdf)
    let stub = TrashActionsStub(
      pages: [.success(page(items: [item], totalCount: 1))],
      deleteResults: [.failure(.transient), .success(())]
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

  func testEmptyTrashRequiresSuccessfulMutationBeforeClearingItems() async {
    let item = trashItem(id: 91, name: "Last.mkv")
    let stub = TrashActionsStub(
      pages: [.success(page(items: [item], totalCount: 1))],
      emptyResults: [.failure(.rateLimited), .success(())]
    )
    let model = model(stub)

    await model.loadIfNeeded()
    await model.empty()

    XCTAssertEqual(model.page?.items, [item])
    guard case .failed(.empty, let failure) = model.mutationOutcome else {
      return XCTFail("expected empty-Trash failure")
    }
    XCTAssertEqual(failure.message, "put.io is receiving too many requests. Try again shortly.")

    await model.empty()

    XCTAssertEqual(model.page, page(items: [], totalCount: 0, sizeBytes: 0))
    XCTAssertEqual(stub.emptyRequests, 2)
    XCTAssertEqual(model.mutationOutcome, .emptied)
  }

  private func model(_ stub: TrashActionsStub) -> PutioTrashModel {
    PutioTrashModel(
      actions: PutioTrashActions(
        load: { try await stub.load(cursor: $0) },
        restore: { try await stub.restore(fileID: $0) },
        permanentlyDelete: { try await stub.permanentlyDelete(fileID: $0) },
        empty: { try await stub.empty() }
      )
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

  private func fileItem(
    id: Int,
    name: String,
    parentID: Int
  ) -> PutioFileItem {
    PutioFileItem(
      id: PutioFileID(rawValue: id),
      parentID: PutioFileID(rawValue: parentID),
      name: name,
      kind: .video,
      sizeBytes: 2_048,
      createdAt: Date(timeIntervalSince1970: 1_756_723_200),
      updatedAt: Date(timeIntervalSince1970: 1_756_723_200),
      resumePositionSeconds: 0
    )
  }
}
