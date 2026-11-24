import Foundation
import XCTest

@testable import PutioCore

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

  func testRefreshClearsPageFailureAndStartsFromPageOne() async {
    var cursors: [Int?] = []
    var roots = 0
    let model = model(list: { before in
      cursors.append(before)
      guard before == nil else { throw PutioRuntimeError.transient }
      roots += 1
      return roots == 1 ? Self.page([30], next: 20) : Self.page([40, 30], next: 20)
    })
    await model.loadIfNeeded()
    await model.loadMore()
    XCTAssertNotNil(model.loadMoreFailure)
    await model.refresh()
    XCTAssertNil(model.loadMoreFailure)
    XCTAssertEqual(cursors, [nil, 20, nil])
    XCTAssertEqual(model.page, Self.page([40, 30], next: 20))
  }

  func testDeleteHidesTheEventWhileTheRequestIsPending() async throws {
    let pending = PendingHistoryPage()
    defer { pending.cancel() }
    let model = model(
      list: { _ in Self.page([30, 20], next: 10) },
      delete: { _ in _ = try await pending.load() })
    await model.loadIfNeeded()
    XCTAssertTrue(model.beginDelete(eventID: 30))
    XCTAssertEqual(model.page, Self.page([20], next: 10))
    let deletion = Task { await model.finishDelete(eventID: 30) }
    defer { deletion.cancel() }
    try await pending.waitForRequest()
    XCTAssertEqual(model.page, Self.page([20], next: 10))
    XCTAssertEqual(model.deletingEventIDs, [30])
    pending.finish(Self.page([]))
    let failure = await deletion.value
    XCTAssertNil(failure)
    XCTAssertEqual(model.page, Self.page([20], next: 10))
    XCTAssertEqual(model.deletingEventIDs, [])
  }

  func testFailedDeleteRestoresTheEventInPlaceAndReportsTheFailure() async {
    var deleted: [Int] = []
    let model = model(
      list: { _ in Self.page([30, 20, 10], next: 5) },
      delete: { id in
        deleted.append(id)
        throw PutioRuntimeError.transient
      })
    await model.loadIfNeeded()
    XCTAssertTrue(model.beginDelete(eventID: 20))
    XCTAssertEqual(model.page, Self.page([30, 10], next: 5))
    let failure = await model.finishDelete(eventID: 20)
    XCTAssertNotNil(failure)
    XCTAssertEqual(deleted, [20])
    XCTAssertEqual(model.page, Self.page([30, 20, 10], next: 5))
    XCTAssertNil(model.mutationFailure)
    XCTAssertNil(model.failedMutation)
  }

  func testExpiredSessionRestoresTheEventWithoutAFailure() async {
    let model = model(
      list: { _ in Self.page([30, 20]) },
      delete: { _ in throw PutioRuntimeError.sessionExpired })
    await model.loadIfNeeded()
    model.beginDelete(eventID: 30)
    let failure = await model.finishDelete(eventID: 30)
    XCTAssertNil(failure)
    XCTAssertEqual(model.page, Self.page([30, 20]))
  }

  func testDeleteThatFailsAfterAClearReportsNothing() async throws {
    let pending = PendingHistoryPage()
    defer { pending.cancel() }
    let model = model(
      list: { _ in Self.page([30, 20], next: 10) },
      delete: { _ in _ = try await pending.load() })
    await model.loadIfNeeded()
    XCTAssertTrue(model.beginDelete(eventID: 30))
    let deletion = Task { await model.finishDelete(eventID: 30) }
    defer { deletion.cancel() }
    try await pending.waitForRequest()
    await model.clear()
    XCTAssertEqual(model.page, Self.page([]))
    pending.fail(PutioRuntimeError.notFound)
    let failure = await deletion.value
    XCTAssertNil(failure)
    XCTAssertEqual(model.page, Self.page([]))
    XCTAssertEqual(model.deletingEventIDs, [])
  }

  func testClearFailureRetainsPageAndRetriesTheClear() async {
    var failClear = true
    let model = model(
      list: { _ in Self.page([30, 20], next: 10) },
      clear: { if failClear { throw PutioRuntimeError.transient } })
    await model.loadIfNeeded()
    await model.clear()
    XCTAssertEqual(model.failedMutation, .clear)
    XCTAssertEqual(model.page, Self.page([30, 20], next: 10))
    failClear = false
    await model.retryMutation()
    XCTAssertEqual(model.page, Self.page([]))
  }

  func testDismissingAFailedClearKeepsThePageAndSendsNothing() async {
    var clears = 0
    let model = model(
      list: { _ in Self.page([30, 20], next: 10) },
      clear: {
        clears += 1
        throw PutioRuntimeError.transient
      })
    await model.loadIfNeeded()
    await model.clear()
    XCTAssertEqual(model.failedMutation, .clear)
    model.dismissMutationFailure()
    XCTAssertNil(model.failedMutation)
    XCTAssertNil(model.mutationFailure)
    XCTAssertEqual(model.page, Self.page([30, 20], next: 10))
    XCTAssertEqual(clears, 1)
  }

  func testLateRefreshCannotRestoreADeletedEvent() async throws {
    let refreshing = PendingHistoryPage()
    defer { refreshing.cancel() }
    var calls = 0
    let model = model(list: { _ in
      calls += 1
      if calls == 1 { return Self.page([30, 20]) }
      return try await refreshing.load()
    })
    await model.loadIfNeeded()
    let refresh = Task { await model.refresh() }
    defer { refresh.cancel() }
    try await refreshing.waitForRequest()
    model.beginDelete(eventID: 30)
    let failure = await model.finishDelete(eventID: 30)
    XCTAssertNil(failure)
    refreshing.finish(Self.page([40, 30, 20]))
    await refresh.value
    XCTAssertEqual(model.page, Self.page([40, 20]))
  }

  func testDeletesRunTogetherAndLeavePagingAndRefreshUsable() async throws {
    let first = PendingHistoryPage()
    let second = PendingHistoryPage()
    defer {
      first.cancel()
      second.cancel()
    }
    var cursors: [Int?] = []
    let model = model(
      list: { before in
        cursors.append(before)
        return before == nil ? Self.page([30, 20], next: 15) : Self.page([10])
      },
      delete: { id in _ = try await (id == 30 ? first : second).load() })
    await model.loadIfNeeded()
    XCTAssertTrue(model.beginDelete(eventID: 30))
    XCTAssertFalse(model.beginDelete(eventID: 30))
    XCTAssertTrue(model.beginDelete(eventID: 20))
    let deleteFirst = Task { await model.finishDelete(eventID: 30) }
    let deleteSecond = Task { await model.finishDelete(eventID: 20) }
    defer {
      deleteFirst.cancel()
      deleteSecond.cancel()
    }
    try await first.waitForRequest()
    try await second.waitForRequest()
    XCTAssertEqual(model.page, Self.page([], next: 15))
    await model.loadMore()
    XCTAssertEqual(model.page, Self.page([10]))
    await model.refresh()
    XCTAssertEqual(cursors, [nil, 15, nil])
    XCTAssertEqual(model.page, Self.page([], next: 15))
    first.finish(Self.page([]))
    second.finish(Self.page([]))
    let results = [await deleteFirst.value, await deleteSecond.value]
    XCTAssertEqual(results, [nil, nil])
    XCTAssertEqual(model.page, Self.page([], next: 15))
  }

  func testDeletingTheOnlyEventOfADayRemovesItsSectionAndTheLastEventEmptiesHistory()
    async throws
  {
    let calendar = Calendar(identifier: .gregorian)
    let now = try XCTUnwrap(
      calendar.date(from: DateComponents(year: 2026, month: 9, day: 30, hour: 9)))
    let older = try XCTUnwrap(calendar.date(byAdding: .day, value: -10, to: now))
    let model = model(list: { _ in
      PutioHistoryPage(
        items: [Self.event(30, at: now), Self.event(20, at: older)], nextBefore: nil)
    })
    await model.loadIfNeeded()
    func days() -> Int {
      PutioHistoryDay.group(model.page?.items ?? [], now: now, calendar: calendar).count
    }
    XCTAssertEqual(days(), 2)
    model.beginDelete(eventID: 20)
    _ = await model.finishDelete(eventID: 20)
    XCTAssertEqual(days(), 1)
    model.beginDelete(eventID: 30)
    _ = await model.finishDelete(eventID: 30)
    XCTAssertEqual(model.page, Self.page([]))
  }

  func testRefreshDiscardsFailedLookupOnlyWhenItsEventIsNoLongerLoaded() async {
    let event = PutioHistoryEventItem(
      id: 30, createdAt: .now,
      kind: .upload(name: "Missing file", sizeBytes: 0, fileID: PutioFileID(rawValue: 10)))
    var items = [event]
    var lookups = 0
    let model = model(
      list: { _ in PutioHistoryPage(items: items, nextBefore: nil) },
      file: { _ in
        lookups += 1
        throw PutioRuntimeError.transient
      })
    await model.loadIfNeeded()
    await model.openFile(event: event)
    await model.refresh()
    XCTAssertNotNil(model.openFailure)
    items = []
    await model.refresh()
    XCTAssertEqual(model.page?.items, [])
    XCTAssertNil(model.openFailure)
    await model.retryOpen()
    XCTAssertEqual(lookups, 1)
  }

  func testRefreshClearsFailedClearOnlyAfterHistoryIsCompletelyEmpty() async {
    var page = Self.page([30])
    var clears = 0
    let model = model(
      list: { _ in page },
      clear: {
        clears += 1
        throw PutioRuntimeError.transient
      })
    await model.loadIfNeeded()
    await model.clear()
    page = Self.page([], next: 20)
    await model.refresh()
    XCTAssertEqual(model.failedMutation, .clear)
    XCTAssertNotNil(model.mutationFailure)
    page = Self.page([])
    await model.refresh()
    XCTAssertNil(model.failedMutation)
    XCTAssertNil(model.mutationFailure)
    await model.retryMutation()
    XCTAssertEqual(clears, 1)
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
      delete: { deletes.append($0) },
      clear: {
        clears += 1
        _ = try await pending.load()
      })
    await model.loadIfNeeded()
    let task = Task { await model.clear() }
    defer { task.cancel() }
    try await pending.waitForRequest()
    task.cancel()
    await model.refresh()
    XCTAssertFalse(model.beginDelete(eventID: 20))
    await model.clear()
    XCTAssertEqual(listCalls, 1)
    XCTAssertEqual(deletes, [])
    XCTAssertEqual(clears, 1)
    pending.finish(Self.page([]))
    await task.value
    XCTAssertEqual(model.page, Self.page([]))
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

  func testCancelledFirstLoadStaysLoadingAndReloadsOnReturn() async throws {
    let pending = PendingHistoryPage()
    defer { pending.cancel() }
    var calls = 0
    let model = model(list: { _ in
      calls += 1
      if calls == 1 { return try await pending.load() }
      return Self.page([30])
    })
    let first = Task { await model.loadIfNeeded() }
    try await pending.waitForRequest()
    first.cancel()
    pending.cancel()
    await first.value
    XCTAssertEqual(model.state, .loading)
    await model.loadIfNeeded()
    XCTAssertEqual(calls, 2)
    XCTAssertEqual(model.page, Self.page([30]))
  }

  func testOfflineFirstLoadFailsWithTheConnectionMessage() async {
    let model = model(list: { _ in throw PutioFolderLoadError.offline })
    await model.loadIfNeeded()
    guard case .failed(let failure) = model.state else { return XCTFail("expected a failure") }
    XCTAssertTrue(failure.isOffline)
    XCTAssertEqual(failure.message, "Check your connection and try again.")
  }

  func testRetryFailedLoadShowsLoadingThenTheList() async throws {
    let pending = PendingHistoryPage()
    defer { pending.cancel() }
    var calls = 0
    let model = model(list: { _ in
      calls += 1
      if calls == 1 { throw PutioRuntimeError.transient }
      return try await pending.load()
    })
    await model.loadIfNeeded()
    guard case .failed(let failure) = model.state else { return XCTFail("expected a failure") }
    XCTAssertFalse(failure.isOffline)
    model.retryFailedLoad()
    XCTAssertEqual(model.state, .loading)
    let retry = Task { await model.loadIfNeeded() }
    try await pending.waitForRequest()
    XCTAssertEqual(model.state, .loading)
    pending.finish(Self.page([30]))
    await retry.value
    XCTAssertEqual(model.page, Self.page([30]))
    model.retryFailedLoad()
    await model.loadIfNeeded()
    XCTAssertEqual(calls, 2)
    XCTAssertEqual(model.page, Self.page([30]))
  }

  func testFileLookupRetriesAndReturnsAuthoritativeSnapshot() async {
    var fail = true
    let item = BrowserTestFixtures.item(id: 10)
    let model = model(
      list: { _ in Self.page([]) },
      file: { id in
        XCTAssertEqual(id.rawValue, 10)
        if fail { throw PutioRuntimeError.transient }
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
        throw PutioRuntimeError.transient
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
    let model = model(
      list: { _ in PutioHistoryPage(items: [event, Self.event(20)], nextBefore: nil) },
      file: { _ in throw PutioRuntimeError.transient })
    await model.loadIfNeeded()
    await model.openFile(event: event)
    model.beginDelete(eventID: 20)
    _ = await model.finishDelete(eventID: 20)
    XCTAssertNotNil(model.openFailure)
    model.beginDelete(eventID: 30)
    XCTAssertNil(model.openFailure)
    _ = await model.finishDelete(eventID: 30)
    await model.retryOpen()
    XCTAssertNil(model.openFailure)
  }

  func testAFileThatIsGoneReportsItOnceAndOffersNoRetry() async {
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
    let first = model.fileGone
    XCTAssertEqual(first?.eventID, 30)
    XCTAssertNil(model.openFailure)
    await model.retryOpen()
    XCTAssertEqual(lookups, 1)
    await model.openFile(event: event)
    XCTAssertEqual(model.fileGone?.eventID, 30)
    XCTAssertNotEqual(model.fileGone, first)
    model.dismissFileGone()
    XCTAssertNil(model.fileGone)
    XCTAssertEqual(model.page?.items, [event])
  }

  func testGoToFolderOpensTheFolderThatHoldsTheEventFile() async {
    let file = BrowserTestFixtures.item(id: 10, parentID: 4)
    let folder = BrowserTestFixtures.item(id: 4, kind: .folder)
    var lookups: [Int] = []
    var parentFails = true
    let model = model(
      list: { _ in Self.page([]) },
      file: { id in
        lookups.append(id.rawValue)
        if id.rawValue == 4 {
          if parentFails { throw PutioRuntimeError.transient }
          return folder
        }
        return file
      })
    let event = PutioHistoryEventItem(
      id: 30, createdAt: .now,
      kind: .upload(name: "File", sizeBytes: 0, fileID: PutioFileID(rawValue: 10)))
    await model.openFolder(event: event)
    XCTAssertNil(model.openedFile)
    XCTAssertNotNil(model.openFailure)
    parentFails = false
    await model.retryOpen()
    XCTAssertEqual(model.openedFile, folder)
    XCTAssertEqual(lookups, [10, 4, 10, 4])
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
    func titles(at now: Date) -> [String] {
      PutioHistoryDay.group(
        model.page?.items ?? [], now: now, calendar: calendar, locale: Locale(identifier: "en_US")
      ).map(\.title)
    }
    XCTAssertEqual(titles(at: firstDay), ["Today"])
    XCTAssertEqual(titles(at: nextDay), ["Yesterday"])
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

  /// A lookup that resolves while History is being cleared must not open a
  /// file from the list being cleared.
  func testClearingRejectsAFileLookupThatResolvesMidClear() async throws {
    let lookup = PendingHistoryPage()
    let clearing = PendingHistoryPage()
    defer {
      lookup.cancel()
      clearing.cancel()
    }
    let model = model(
      list: { _ in Self.page([30]) },
      clear: { _ = try await clearing.load() },
      file: { _ in
        _ = try await lookup.load()
        return BrowserTestFixtures.item(id: 10)
      })
    await model.loadIfNeeded()
    let event = PutioHistoryEventItem(
      id: 30, createdAt: .now,
      kind: .upload(name: "File", sizeBytes: 0, fileID: PutioFileID(rawValue: 10)))
    let opening = Task { await model.openFile(event: event) }
    defer { opening.cancel() }
    try await lookup.waitForRequest()
    let clear = Task { await model.clear() }
    defer { clear.cancel() }
    try await clearing.waitForRequest()
    lookup.finish(Self.page([]))
    await opening.value
    XCTAssertNil(model.openedFile)
    XCTAssertNil(model.openingEventID)
    clearing.finish(Self.page([]))
    await clear.value
    XCTAssertEqual(model.page, Self.page([]))
    XCTAssertNil(model.openedFile)
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

  func testEventTimesReadAsRelativeDatesInsteadOfDurations() throws {
    let now = Date(timeIntervalSince1970: 1_790_000_000)
    let english = Locale(identifier: "en_US")

    XCTAssertEqual(
      PutioBrowserItemPresentation.relativeDateText(
        for: now.addingTimeInterval(-3 * 86_400), relativeTo: now, locale: english),
      "3 days ago")
    XCTAssertEqual(
      PutioBrowserItemPresentation.relativeDateText(
        for: now.addingTimeInterval(-86_400), relativeTo: now, locale: english),
      "yesterday")
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

  func fail(_ error: any Error) {
    continuation?.resume(throwing: error)
    continuation = nil
  }

  func cancel() {
    cancelled = true
    continuation?.resume(throwing: CancellationError())
    continuation = nil
  }
}
