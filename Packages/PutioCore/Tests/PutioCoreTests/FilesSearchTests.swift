import XCTest

@testable import PutioCore

@MainActor
final class FilesSearchTests: XCTestCase {
  func testWhitespaceDoesNotSearchAndCancellationStopsDebounce() async throws {
    var keywords: [String] = []
    let model = PutioFileSearchModel(
      search: { keyword in
        keywords.append(keyword)
        return Self.page([])
      },
      continueSearch: { _ in Self.page([]) },
      debounce: .seconds(30)
    )
    await model.update(query: " \n ")
    XCTAssertEqual(model.state, .idle)
    let task = Task { await model.update(query: "unsubmitted") }
    defer { task.cancel() }
    try await waitForSearchCondition { model.query == "unsubmitted" }
    task.cancel()
    await task.value
    await model.update(query: "")
    XCTAssertEqual(model.state, .idle)
    XCTAssertTrue(keywords.isEmpty)
  }

  func testLatestQueryWinsEvenWhenOldRequestIgnoresCancellation() async throws {
    let requests = ControlledSearch()
    defer { requests.cancelPending() }
    let model = PutioFileSearchModel(
      search: { try await requests.load($0) }, continueSearch: { _ in Self.page([]) })
    let first = Task { await model.update(query: "old", debounced: false) }
    try await requests.waitForCount(1)
    let second = Task { await model.update(query: " new ", debounced: false) }
    try await requests.waitForCount(2)
    XCTAssertEqual(requests.keywords, ["old", "new"])
    requests.finish(1, with: .success(Self.page([2])))
    await second.value
    requests.finish(0, with: .success(Self.page([1])))
    await first.value
    XCTAssertEqual(model.state, .loaded(Self.page([2])))
    XCTAssertEqual(model.query, "new")
  }

  func testClearingQueryRejectsAnInFlightResult() async throws {
    let requests = ControlledSearch()
    defer { requests.cancelPending() }
    let model = PutioFileSearchModel(
      search: { try await requests.load($0) }, continueSearch: { _ in Self.page([]) })
    let request = Task { await model.update(query: "old", debounced: false) }
    try await requests.waitForCount(1)
    await model.update(query: "")
    requests.finish(0, with: .success(Self.page([1])))
    await request.value
    XCTAssertEqual(model.state, .idle)
  }

  func testFailureCanRetryTheSameQueryAndEmptyResultsRemainLoaded() async {
    var attempts = 0
    let model = PutioFileSearchModel(
      search: { _ in
        attempts += 1
        if attempts == 1 { throw PutioRuntimeError.transient }
        return Self.page([])
      }, continueSearch: { _ in Self.page([]) })
    await model.update(query: "missing", debounced: false)
    guard case .failed(let failure) = model.state else { return XCTFail("Expected failure") }
    XCTAssertEqual(failure.kind, .transient)
    await model.update(query: model.query, debounced: false)
    XCTAssertEqual(model.state, .loaded(Self.page([])))
  }

  func testPaginationRetainsRowsOnFailureAndDeduplicatesRetry() async {
    var cursors: [String] = []
    let model = PutioFileSearchModel(
      search: { _ in Self.page([1], cursor: "second") },
      continueSearch: { cursor in
        cursors.append(cursor)
        if cursors.count == 1 { throw PutioRuntimeError.transient }
        return Self.page([1, 2])
      })
    await model.update(query: "movie", debounced: false)
    await model.loadMore()
    XCTAssertEqual(model.state, .loaded(Self.page([1], cursor: "second")))
    XCTAssertEqual(model.loadMoreFailure?.kind, .transient)
    await model.loadMore()
    XCTAssertEqual(model.state, .loaded(Self.page([1, 2])))
    XCTAssertNil(model.loadMoreFailure)
    XCTAssertEqual(cursors, ["second", "second"])
  }

  func testRefreshFailureRetainsResultsAndRetryReplacesThem() async {
    var attempts = 0
    var continuationCalls = 0
    let model = PutioFileSearchModel(
      search: { _ in
        attempts += 1
        if attempts == 2 { throw PutioRuntimeError.transient }
        return Self.page([attempts], cursor: "next")
      },
      continueSearch: { _ in
        continuationCalls += 1
        return Self.page([9])
      })
    await model.update(query: "movie", debounced: false)
    await model.update(query: "movie", debounced: false)
    XCTAssertEqual(model.state, .loaded(Self.page([1], cursor: "next")))
    XCTAssertEqual(model.refreshFailure?.kind, .transient)
    await model.loadMore()
    XCTAssertEqual(continuationCalls, 0)
    await model.update(query: "movie", debounced: false)
    XCTAssertNil(model.refreshFailure)
    XCTAssertEqual(model.state, .loaded(Self.page([3], cursor: "next")))
  }

  func testNewQueryDiscardsOldPageAndAllowsNewPagination() async throws {
    let requests = ControlledSearch()
    defer { requests.cancelPending() }
    let model = PutioFileSearchModel(
      search: { query in Self.page(query == "old" ? [1] : [3], cursor: query) },
      continueSearch: { try await requests.load($0) })
    await model.update(query: "old", debounced: false)
    let oldPage = Task { await model.loadMore() }
    try await requests.waitForCount(1)
    await model.update(query: "new", debounced: false)
    let newPage = Task { await model.loadMore() }
    try await requests.waitForCount(2)
    requests.finish(0, with: .success(Self.page([2])))
    await oldPage.value
    XCTAssertTrue(model.isLoadingMore)
    requests.finish(1, with: .success(Self.page([4])))
    await newPage.value
    XCTAssertEqual(model.state, .loaded(Self.page([3, 4])))
    XCTAssertFalse(model.isLoadingMore)
  }

  func testCursorCycleStopsWithoutDroppingResults() async {
    var requestCount = 0
    let model = PutioFileSearchModel(
      search: { _ in Self.page([1], cursor: "a") },
      continueSearch: { _ in
        requestCount += 1
        return Self.page([requestCount + 1], cursor: requestCount == 1 ? "b" : "a")
      })
    await model.update(query: "movie", debounced: false)
    await model.loadMore()
    await model.loadMore()
    XCTAssertEqual(model.loadMoreFailure?.kind, .invalidResponse)
    XCTAssertEqual(model.state, .loaded(Self.page([1, 2], cursor: "b")))
  }

  func testCancelledPageRestartsAfterAnEarlyReappearance() async throws {
    let requests = ControlledSearch()
    defer { requests.cancelPending() }
    let model = PutioFileSearchModel(
      search: { _ in Self.page([1], cursor: "second") },
      continueSearch: { try await requests.load($0) })
    await model.update(query: "movie", debounced: false)
    let originalEpoch = model.paginationEpoch
    let first = Task { await model.loadMore() }
    try await requests.waitForCount(1)
    first.cancel()
    await model.loadMore()
    XCTAssertEqual(requests.keywords.count, 1)
    requests.finish(0, with: .failure(CancellationError()))
    await first.value
    XCTAssertNotEqual(model.paginationEpoch, originalEpoch)
    XCTAssertFalse(model.isLoadingMore)
    XCTAssertNil(model.loadMoreFailure)
    let restarted = Task { await model.loadMore() }
    try await requests.waitForCount(2)
    requests.finish(1, with: .success(Self.page([2])))
    await restarted.value
    XCTAssertEqual(model.state, .loaded(Self.page([1, 2])))
  }

  func testReappearanceKeepsResultsUntilTheQueryOrARefreshChanges() async {
    var keywords: [String] = []
    let model = PutioFileSearchModel(
      search: { keyword in
        keywords.append(keyword)
        return Self.page([keywords.count])
      },
      continueSearch: { _ in Self.page([]) },
      debounce: .zero
    )

    await model.apply(query: "movie", revision: 0)
    // Tab switches and pops re-run the view task with the same request.
    await model.apply(query: "movie", revision: 0)
    await model.apply(query: " movie ", revision: 0)
    XCTAssertEqual(keywords, ["movie"])
    XCTAssertEqual(model.state, .loaded(Self.page([1])))

    // A browser mutation since the last search refreshes the results.
    await model.apply(query: "movie", revision: 1)
    XCTAssertEqual(keywords, ["movie", "movie"])
    await model.apply(query: "show", revision: 1)
    await model.apply(query: "movie", revision: 1)
    XCTAssertEqual(keywords, ["movie", "movie", "show", "movie"])
    XCTAssertEqual(model.state, .loaded(Self.page([4])))
  }

  func testReappearanceRetriesARequestThatNeverLanded() async throws {
    let requests = ControlledSearch()
    defer { requests.cancelPending() }
    let model = PutioFileSearchModel(
      search: { try await requests.load($0) },
      continueSearch: { _ in Self.page([]) },
      debounce: .zero
    )

    let first = Task { await model.apply(query: "movie", revision: 0) }
    try await requests.waitForCount(1)
    requests.finish(0, with: .success(Self.page([1])))
    await first.value

    // Leaving the tab cancels the refresh a mutation started.
    let refresh = Task { await model.apply(query: "movie", revision: 1) }
    try await requests.waitForCount(2)
    refresh.cancel()
    requests.finish(1, with: .failure(CancellationError()))
    await refresh.value

    let returning = Task { await model.apply(query: "movie", revision: 1) }
    try await requests.waitForCount(3)
    requests.finish(2, with: .failure(PutioRuntimeError.transient))
    await returning.value
    XCTAssertEqual(model.refreshFailure?.kind, .transient)

    let retry = Task { await model.apply(query: "movie", revision: 1) }
    try await requests.waitForCount(4)
    requests.finish(3, with: .success(Self.page([2])))
    await retry.value
    XCTAssertEqual(model.state, .loaded(Self.page([2])))
    XCTAssertNil(model.refreshFailure)
    // Once a request lands, reappearing keeps it. A search would park in
    // `requests`, so run it detached and release it after the check.
    let reappearance = Task { await model.apply(query: "movie", revision: 1) }
    try await Task.sleep(for: .milliseconds(50))
    XCTAssertEqual(requests.keywords.count, 4)
    requests.cancelPending()
    await reappearance.value
  }

  func testCancelledRetryKeepsTheRefreshFailureForReappearance() async throws {
    let requests = ControlledSearch()
    defer { requests.cancelPending() }
    let model = PutioFileSearchModel(
      search: { try await requests.load($0) },
      continueSearch: { _ in Self.page([]) },
      debounce: .zero
    )

    let first = Task { await model.apply(query: "movie", revision: 0) }
    try await requests.waitForCount(1)
    requests.finish(0, with: .success(Self.page([1])))
    await first.value
    let pull = Task { await model.refresh(query: "movie", revision: 0) }
    try await requests.waitForCount(2)
    requests.finish(1, with: .failure(PutioRuntimeError.transient))
    await pull.value
    XCTAssertEqual(model.refreshFailure?.kind, .transient)

    // Leaving the tab cancels the retry that reappearance started.
    let retry = Task { await model.apply(query: "movie", revision: 0) }
    try await requests.waitForCount(3)
    retry.cancel()
    requests.finish(2, with: .failure(CancellationError()))
    await retry.value
    XCTAssertEqual(model.refreshFailure?.kind, .transient)
    XCTAssertEqual(model.state, .loaded(Self.page([1])))

    let returning = Task { await model.apply(query: "movie", revision: 0) }
    try await requests.waitForCount(4)
    requests.finish(3, with: .success(Self.page([2])))
    await returning.value
    XCTAssertEqual(model.state, .loaded(Self.page([2])))
    XCTAssertNil(model.refreshFailure)
  }

  func testReappearanceBeforeACancelledRetryUnwindsStillRetries() async throws {
    let requests = ControlledSearch()
    defer { requests.cancelPending() }
    let model = PutioFileSearchModel(
      search: { try await requests.load($0) },
      continueSearch: { _ in Self.page([]) },
      debounce: .zero
    )

    let first = Task { await model.apply(query: "movie", revision: 0) }
    try await requests.waitForCount(1)
    requests.finish(0, with: .success(Self.page([1])))
    await first.value
    let pull = Task { await model.refresh(query: "movie", revision: 0) }
    try await requests.waitForCount(2)
    requests.finish(1, with: .failure(PutioRuntimeError.transient))
    await pull.value

    let retry = Task { await model.apply(query: "movie", revision: 0) }
    try await requests.waitForCount(3)
    retry.cancel()
    // The tab comes back before the cancelled retry unwinds.
    let returning = Task { await model.apply(query: "movie", revision: 0) }
    try await requests.waitForCount(4)
    requests.finish(2, with: .failure(CancellationError()))
    await retry.value
    requests.finish(3, with: .success(Self.page([2])))
    await returning.value
    XCTAssertEqual(model.state, .loaded(Self.page([2])))
    XCTAssertNil(model.refreshFailure)
  }

  func testSuccessfulInitialRetryKeepsResultsOnReappearance() async {
    var attempts = 0
    let model = PutioFileSearchModel(
      search: { _ in
        attempts += 1
        if attempts == 1 { throw PutioRuntimeError.transient }
        return Self.page([attempts])
      }, continueSearch: { _ in Self.page([]) }, debounce: .zero)

    await model.apply(query: "movie", revision: 0)
    guard case .failed = model.state else { return XCTFail("Expected initial failure") }
    await model.refresh(query: " movie ", revision: 0)
    await model.apply(query: "movie", revision: 0)

    XCTAssertEqual(attempts, 2)
    XCTAssertEqual(model.state, .loaded(Self.page([2])))
  }

  func testSuccessfulRefreshRetryRecordsTheNewRevision() async {
    var attempts = 0
    let model = PutioFileSearchModel(
      search: { _ in
        attempts += 1
        if attempts == 2 { throw PutioRuntimeError.transient }
        return Self.page([attempts])
      }, continueSearch: { _ in Self.page([]) }, debounce: .zero)

    await model.apply(query: "movie", revision: 0)
    await model.apply(query: "movie", revision: 1)
    XCTAssertEqual(model.refreshFailure?.kind, .transient)
    await model.refresh(query: "movie", revision: 1)
    XCTAssertNil(model.refreshFailure)
    await model.apply(query: "movie", revision: 1)
    XCTAssertEqual(attempts, 3)
    XCTAssertEqual(model.state, .loaded(Self.page([3])))

    // Pull-to-refresh still fetches even when the request is already applied.
    await model.refresh(query: "movie", revision: 1)
    await model.apply(query: "movie", revision: 1)
    XCTAssertEqual(attempts, 4)
    await model.apply(query: "movie", revision: 2)
    XCTAssertEqual(attempts, 5)
  }

  private static func page(_ ids: [Int], cursor: String? = nil) -> PutioFileSearchPage {
    PutioFileSearchPage(
      items: ids.map { BrowserTestFixtures.item(id: $0) }, nextCursor: cursor, totalCount: 10)
  }
}

@MainActor
private final class ControlledSearch {
  private(set) var keywords: [String] = []
  private var pending: [Int: CheckedContinuation<PutioFileSearchPage, any Error>] = [:]
  private var isClosed = false

  func load(_ keyword: String) async throws -> PutioFileSearchPage {
    guard !isClosed else { throw CancellationError() }
    let index = keywords.count
    keywords.append(keyword)
    return try await withCheckedThrowingContinuation { pending[index] = $0 }
  }

  func waitForCount(_ count: Int) async throws {
    try await waitForSearchCondition { self.keywords.count >= count }
  }

  func cancelPending() {
    isClosed = true
    let continuations = Array(pending.values)
    pending.removeAll()
    for continuation in continuations {
      continuation.resume(throwing: CancellationError())
    }
  }

  func finish(_ index: Int, with result: Result<PutioFileSearchPage, any Error>) {
    pending.removeValue(forKey: index)?.resume(with: result)
  }
}

@MainActor
private func waitForSearchCondition(_ condition: () -> Bool) async throws {
  let deadline = ContinuousClock.now.advanced(by: .seconds(5))
  while !condition() {
    guard ContinuousClock.now < deadline else {
      throw NSError(
        domain: "FilesSearchTests", code: 1,
        userInfo: [NSLocalizedDescriptionKey: "Timed out waiting for the search request"])
    }
    try await Task.sleep(for: .milliseconds(1))
  }
}
