import PutioCore
import XCTest

@testable import Putio

@MainActor
final class FilesSearchTests: XCTestCase {
  func testWhitespaceDoesNotSearchAndCancellationStopsDebounce() async {
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
    while model.query != "unsubmitted" { await Task.yield() }
    task.cancel()
    await task.value
    await model.update(query: "")
    XCTAssertEqual(model.state, .idle)
    XCTAssertTrue(keywords.isEmpty)
  }

  func testLatestQueryWinsEvenWhenOldRequestIgnoresCancellation() async {
    let requests = ControlledSearch()
    let model = PutioFileSearchModel(
      search: { try await requests.load($0) }, continueSearch: { _ in Self.page([]) })
    let first = Task { await model.update(query: "old", debounced: false) }
    await requests.waitForCount(1)
    let second = Task { await model.update(query: " new ", debounced: false) }
    await requests.waitForCount(2)
    XCTAssertEqual(requests.keywords, ["old", "new"])
    requests.finish(1, with: .success(Self.page([2])))
    await second.value
    requests.finish(0, with: .success(Self.page([1])))
    await first.value
    XCTAssertEqual(model.state, .loaded(Self.page([2])))
    XCTAssertEqual(model.query, "new")
  }

  func testClearingQueryRejectsAnInFlightResult() async {
    let requests = ControlledSearch()
    let model = PutioFileSearchModel(
      search: { try await requests.load($0) }, continueSearch: { _ in Self.page([]) })
    let request = Task { await model.update(query: "old", debounced: false) }
    await requests.waitForCount(1)
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

  func testNewQueryDiscardsOldPageAndAllowsNewPagination() async {
    let requests = ControlledSearch()
    let model = PutioFileSearchModel(
      search: { query in Self.page(query == "old" ? [1] : [3], cursor: query) },
      continueSearch: { try await requests.load($0) })
    await model.update(query: "old", debounced: false)
    let oldPage = Task { await model.loadMore() }
    await requests.waitForCount(1)
    await model.update(query: "new", debounced: false)
    let newPage = Task { await model.loadMore() }
    await requests.waitForCount(2)
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

  func testCancelledPageRestartsAfterAnEarlyReappearance() async {
    let requests = ControlledSearch()
    let model = PutioFileSearchModel(
      search: { _ in Self.page([1], cursor: "second") },
      continueSearch: { try await requests.load($0) })
    await model.update(query: "movie", debounced: false)
    let originalEpoch = model.paginationEpoch
    let first = Task { await model.loadMore() }
    await requests.waitForCount(1)
    first.cancel()
    await model.loadMore()
    XCTAssertEqual(requests.keywords.count, 1)
    requests.finish(0, with: .failure(CancellationError()))
    await first.value
    XCTAssertNotEqual(model.paginationEpoch, originalEpoch)
    XCTAssertFalse(model.isLoadingMore)
    XCTAssertNil(model.loadMoreFailure)
    let restarted = Task { await model.loadMore() }
    await requests.waitForCount(2)
    requests.finish(1, with: .success(Self.page([2])))
    await restarted.value
    XCTAssertEqual(model.state, .loaded(Self.page([1, 2])))
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

  func load(_ keyword: String) async throws -> PutioFileSearchPage {
    let index = keywords.count
    keywords.append(keyword)
    return try await withCheckedThrowingContinuation { pending[index] = $0 }
  }

  func waitForCount(_ count: Int) async {
    while keywords.count < count { await Task.yield() }
  }

  func finish(_ index: Int, with result: Result<PutioFileSearchPage, any Error>) {
    pending.removeValue(forKey: index)?.resume(with: result)
  }
}
