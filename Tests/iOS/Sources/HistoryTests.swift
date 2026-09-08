import Foundation
import PutioCore
import XCTest

@testable import Putio

@MainActor
final class HistoryTests: XCTestCase {
  func testInitialFailureRetryAndRefreshFailureRetainsRows() async {
    var fail = true
    let model = model(list: { _ in
      if fail { throw PutioRuntimeError.transient }
      return Self.page([30], next: 20)
    })
    await model.loadIfNeeded()
    guard case .failed = model.state else { return XCTFail("Expected initial failure") }
    fail = false
    await model.refresh()
    XCTAssertEqual(model.page, Self.page([30], next: 20))
    fail = true
    await model.refresh()
    XCTAssertEqual(model.page, Self.page([30], next: 20))
    XCTAssertNotNil(model.refreshFailure)
  }

  func testUnsupportedOnlyPageContinuesAndDuplicatesAreRemoved() async {
    var cursors: [Int?] = []
    let model = model(list: { before in
      cursors.append(before)
      switch before {
      case nil: return Self.page([30], next: 20)
      case 20: return Self.page([], next: 10)
      default: return Self.page([30, 5, 5])
      }
    })
    await model.loadIfNeeded()
    await model.loadMore()
    XCTAssertEqual(model.page, Self.page([30], next: 10))
    await model.loadMore()
    XCTAssertEqual(model.page, Self.page([30, 5]))
    XCTAssertEqual(cursors, [nil, 20, 10])
  }

  func testNondecreasingCursorRetainsRowsAndCanRetry() async {
    var fail = true
    let model = model(list: { before in
      if before == nil { return Self.page([30], next: 20) }
      return Self.page([15], next: fail ? 20 : nil)
    })
    await model.loadIfNeeded()
    await model.loadMore()
    XCTAssertNotNil(model.loadMoreFailure)
    XCTAssertEqual(model.page, Self.page([30], next: 20))
    fail = false
    await model.loadMore()
    XCTAssertEqual(model.page, Self.page([30, 15]))
  }

  func testDeleteAndClearFailuresRetainPageAndRetryExactOperation() async {
    var failDelete = true
    var failClear = true
    var deleted: [Int] = []
    let model = model(
      list: { _ in Self.page([30, 20], next: 10) },
      delete: { id in
        deleted.append(id)
        if failDelete { throw PutioRuntimeError.transient }
      },
      clear: { if failClear { throw PutioRuntimeError.transient } })
    await model.loadIfNeeded()
    await model.delete(eventID: 30)
    XCTAssertEqual(model.page, Self.page([30, 20], next: 10))
    XCTAssertEqual(model.failedMutation, .delete(30))
    failDelete = false
    await model.retryMutation()
    XCTAssertEqual(deleted, [30, 30])
    XCTAssertEqual(model.page, Self.page([20], next: 10))
    await model.clear()
    XCTAssertEqual(model.failedMutation, .clear)
    XCTAssertEqual(model.page, Self.page([20], next: 10))
    failClear = false
    await model.retryMutation()
    XCTAssertEqual(model.page, Self.page([]))
  }

  func testClearSupersedesInflightPageAndLateResponseCannotRestoreDeletedEvents() async throws {
    let pending = PendingHistoryPage()
    defer { pending.cancel() }
    let model = model(list: { before in
      if before == nil { return Self.page([30], next: 20) }
      return try await pending.load()
    })
    await model.loadIfNeeded()
    let task = Task { await model.loadMore() }
    defer { task.cancel() }
    try await pending.waitForRequest()
    await model.clear()
    pending.finish(Self.page([15]))
    await task.value
    XCTAssertEqual(model.page, Self.page([]))
  }

  func testMutationSerializesRefreshAndSurvivesCallerCancellation() async throws {
    let pending = PendingHistoryPage()
    defer { pending.cancel() }
    var listCalls = 0
    var deletes: [Int] = []
    var clears = 0
    let model = model(
      list: { _ in
        listCalls += 1
        return Self.page([30, 20])
      },
      delete: { id in
        deletes.append(id)
        _ = try await pending.load()
      },
      clear: { clears += 1 })
    await model.loadIfNeeded()
    let task = Task { await model.delete(eventID: 30) }
    defer { task.cancel() }
    try await pending.waitForRequest()
    task.cancel()
    await model.refresh()
    await model.delete(eventID: 20)
    await model.clear()
    XCTAssertEqual(listCalls, 1)
    XCTAssertEqual(deletes, [30])
    XCTAssertEqual(clears, 0)
    pending.finish(Self.page([]))
    await task.value
    XCTAssertEqual(model.page, Self.page([20]))
    XCTAssertNil(model.mutation)
  }

  func testCancelledPageCanRestartAfterReappearance() async throws {
    let pending = PendingHistoryPage()
    defer { pending.cancel() }
    var requested = false
    let model = model(list: { before in
      if before == nil { return Self.page([30], next: 20) }
      if requested { return Self.page([15]) }
      requested = true
      return try await pending.load()
    })
    await model.loadIfNeeded()
    let epoch = model.paginationEpoch
    let task = Task { await model.loadMore() }
    defer { task.cancel() }
    try await pending.waitForRequest()
    task.cancel()
    await model.loadMore()
    pending.finish(Self.page([15]))
    await task.value
    XCTAssertNotEqual(model.paginationEpoch, epoch)
    XCTAssertEqual(model.page, Self.page([30], next: 20))
    await model.loadMore()
    XCTAssertEqual(model.page, Self.page([30, 15]))
  }

  func testFileLookupRetriesAndReturnsAuthoritativeSnapshot() async {
    var fail = true
    let item = BrowserTestFixtures.item(id: 10)
    let model = model(
      list: { _ in Self.page([]) },
      file: { id in
        XCTAssertEqual(id.rawValue, 10)
        if fail { throw PutioRuntimeError.notFound }
        return item
      })
    let event = PutioHistoryEventItem(
      id: 30, createdAt: .now,
      kind: .upload(name: "Old name", sizeBytes: 0, fileID: PutioFileID(rawValue: 10)))
    await model.openFile(event: event)
    XCTAssertNil(model.openedFile)
    XCTAssertNotNil(model.openFailure)
    fail = false
    await model.retryOpen()
    XCTAssertEqual(model.openedFile, item)
    XCTAssertNil(model.openFailure)
  }

  func testClearingHistoryRemovesFailedFileLookupAndItsRetry() async {
    var lookups = 0
    let event = PutioHistoryEventItem(
      id: 30, createdAt: .now,
      kind: .upload(name: "Missing file", sizeBytes: 0, fileID: PutioFileID(rawValue: 10)))
    let model = model(
      list: { _ in PutioHistoryPage(items: [event], nextBefore: nil) },
      file: { _ in
        lookups += 1
        throw PutioRuntimeError.notFound
      })
    await model.loadIfNeeded()
    await model.openFile(event: event)
    XCTAssertNotNil(model.openFailure)
    await model.clear()
    XCTAssertEqual(model.page?.items, [])
    XCTAssertNil(model.openFailure)
    await model.retryOpen()
    XCTAssertEqual(lookups, 1)
  }

  func testDeletingFailedLookupEventClearsOnlyItsNavigationFailure() async {
    let event = PutioHistoryEventItem(
      id: 30, createdAt: .now,
      kind: .upload(name: "Missing file", sizeBytes: 0, fileID: PutioFileID(rawValue: 10)))
    let model = model(list: { _ in
      PutioHistoryPage(items: [event, Self.event(20)], nextBefore: nil)
    })
    await model.loadIfNeeded()
    await model.openFile(event: event)
    await model.delete(eventID: 20)
    XCTAssertNotNil(model.openFailure)
    await model.delete(eventID: 30)
    XCTAssertNil(model.openFailure)
    await model.retryOpen()
    XCTAssertNil(model.openFailure)
  }

  func testLoadedEventsRegroupWhenCalendarDayAdvances() async throws {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "America/New_York"))
    let firstDay = try XCTUnwrap(
      calendar.date(from: DateComponents(year: 2026, month: 3, day: 8, hour: 23)))
    let nextDay = try XCTUnwrap(calendar.date(byAdding: .hour, value: 2, to: firstDay))
    let model = model(list: { _ in
      PutioHistoryPage(items: [Self.event(30, at: firstDay)], nextBefore: nil)
    })
    await model.loadIfNeeded()
    XCTAssertEqual(model.daySections(now: firstDay, calendar: calendar).map(\.id), [.today])
    XCTAssertEqual(model.daySections(now: nextDay, calendar: calendar).map(\.id), [.yesterday])
    XCTAssertEqual(model.page?.items.map(\.id), [30])
  }

  func testInitialLoadRestartsBeforeCancelledRequestUnwinds() async throws {
    let pending = PendingHistoryPage()
    defer { pending.cancel() }
    var calls = 0
    let model = model(list: { _ in
      calls += 1
      if calls == 1 { return try await pending.load() }
      return Self.page([20])
    })
    let first = Task { await model.loadIfNeeded() }
    defer { first.cancel() }
    try await pending.waitForRequest()
    first.cancel()
    await model.loadIfNeeded()
    pending.finish(Self.page([30]))
    await first.value
    XCTAssertEqual(model.page, Self.page([20]))
    XCTAssertFalse(model.isRefreshing)
  }

  func testLeavingHistoryRejectsLateFileLookup() async throws {
    let pending = PendingHistoryPage()
    defer { pending.cancel() }
    let model = model(
      list: { _ in Self.page([]) },
      file: { _ in
        _ = try await pending.load()
        return BrowserTestFixtures.item(id: 10)
      })
    let event = PutioHistoryEventItem(
      id: 30, createdAt: .now,
      kind: .upload(name: "File", sizeBytes: 0, fileID: PutioFileID(rawValue: 10)))
    let opening = Task { await model.openFile(event: event) }
    defer { opening.cancel() }
    try await pending.waitForRequest()
    model.cancelOpen()
    pending.finish(Self.page([]))
    await opening.value
    XCTAssertNil(model.openedFile)
    XCTAssertNil(model.openingEventID)
    XCTAssertNil(model.openFailure)
  }

  func testCalendarGroupingAcrossSpringDSTBoundary() throws {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "America/New_York"))
    let now = try XCTUnwrap(
      calendar.date(from: DateComponents(year: 2026, month: 3, day: 9, hour: 1)))
    let yesterday = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 3, day: 8)))
    let older = try XCTUnwrap(
      calendar.date(from: DateComponents(year: 2026, month: 3, day: 7, hour: 23)))
    let items = [Self.event(3, at: now), Self.event(2, at: yesterday), Self.event(1, at: older)]
    let sections = PutioHistorySection.group(items, now: now, calendar: calendar)
    XCTAssertEqual(sections.map(\.id), [.today, .yesterday, .earlier])
    XCTAssertEqual(sections.map { $0.items.map(\.id) }, [[3], [2], [1]])
  }

  private func model(
    list: @escaping @MainActor @Sendable (Int?) async throws -> PutioHistoryPage,
    delete: @escaping @MainActor @Sendable (Int) async throws -> Void = { _ in },
    clear: @escaping @MainActor @Sendable () async throws -> Void = {},
    file: @escaping @MainActor @Sendable (PutioFileID) async throws -> PutioFileItem = { _ in
      throw PutioRuntimeError.notFound
    }
  ) -> PutioHistoryModel {
    PutioHistoryModel(
      actions: PutioHistoryActions(list: list, delete: delete, clear: clear, file: file))
  }

  private static func page(_ ids: [Int], next: Int? = nil) -> PutioHistoryPage {
    PutioHistoryPage(items: ids.map { event($0) }, nextBefore: next)
  }

  private static func event(_ id: Int, at date: Date = .distantPast) -> PutioHistoryEventItem {
    PutioHistoryEventItem(id: id, createdAt: date, kind: .transferError(name: "Transfer \(id)"))
  }
}

@MainActor
private final class PendingHistoryPage {
  private var continuation: CheckedContinuation<PutioHistoryPage, any Error>?
  private var cancelled = false

  func load() async throws -> PutioHistoryPage {
    guard !cancelled else { throw CancellationError() }
    return try await withCheckedThrowingContinuation { continuation = $0 }
  }

  func waitForRequest() async throws {
    let deadline = ContinuousClock.now.advanced(by: .seconds(5))
    while continuation == nil {
      guard ContinuousClock.now < deadline else {
        throw NSError(
          domain: "HistoryTests", code: 1,
          userInfo: [NSLocalizedDescriptionKey: "Timed out waiting for history request"])
      }
      try await Task.sleep(for: .milliseconds(1))
    }
  }

  func finish(_ page: PutioHistoryPage) {
    continuation?.resume(returning: page)
    continuation = nil
  }

  func cancel() {
    cancelled = true
    continuation?.resume(throwing: CancellationError())
    continuation = nil
  }
}
