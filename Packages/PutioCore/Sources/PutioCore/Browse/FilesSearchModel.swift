import Foundation
import Observation

public typealias PutioFileSearch = @MainActor @Sendable (String) async throws -> PutioFileSearchPage

@MainActor
@Observable
public final class PutioFileSearchModel {
  public enum State: Equatable {
    case idle
    case loading
    case loaded(PutioFileSearchPage)
    case failed(PutioBrowserErrorPresentation)
  }

  public private(set) var state: State = .idle
  private(set) var query = ""
  private(set) var isLoadingMore = false
  public private(set) var isSearching = false
  public private(set) var refreshFailure: PutioBrowserErrorPresentation?
  public private(set) var loadMoreFailure: PutioBrowserErrorPresentation?
  public private(set) var generation: UInt64 = 0
  public private(set) var paginationEpoch: UInt64 = 0
  /// Results the latest search returned on its first page; a re-run keeps
  /// only these until paging reaches the rest again.
  public private(set) var firstPageIDs: Set<PutioFileID> = []
  @ObservationIgnored private let search: PutioFileSearch
  @ObservationIgnored private let continueSearch: PutioFileSearch
  @ObservationIgnored private let debounce: Duration
  @ObservationIgnored private var consumedCursors: Set<String> = []
  @ObservationIgnored private var appliedRequest: Request?

  /// A query and the browser refresh revision its results reflect.
  struct Request: Equatable {
    let query: String
    let revision: UInt64
  }

  public init(
    search: @escaping PutioFileSearch,
    continueSearch: @escaping PutioFileSearch,
    debounce: Duration = .milliseconds(300)
  ) {
    self.search = search
    self.continueSearch = continueSearch
    self.debounce = debounce
  }

  /// Searches for the view's current request unless the shown results
  /// already reflect it. Reappearing after a tab switch or a pop keeps them;
  /// a new query or a browser mutation since the last search runs again.
  public func apply(query: String, revision: UInt64) async {
    let request = Request(query: Self.keyword(query), revision: revision)
    if request == appliedRequest, request.query == self.query, case .loaded = state,
      refreshFailure == nil
    {
      return
    }
    if await update(query: request.query) { appliedRequest = request }
  }

  public func refresh(query: String, revision: UInt64) async {
    let request = Request(query: Self.keyword(query), revision: revision)
    if await update(query: request.query, debounced: false) { appliedRequest = request }
  }

  /// Returns true when this call's results are the ones shown.
  @discardableResult
  func update(query: String, debounced: Bool = true) async -> Bool {
    let keyword = Self.keyword(query)
    let retainedPage: PutioFileSearchPage?
    if keyword == self.query, case .loaded(let page) = state {
      retainedPage = page
    } else {
      retainedPage = nil
    }
    // A cancelled refresh restores the failure it cleared, so reappearance
    // still retries and the banner stays.
    let previousRefreshFailure = retainedPage == nil ? nil : refreshFailure
    generation &+= 1
    let requestGeneration = generation
    self.query = keyword
    isSearching = true
    refreshFailure = nil
    defer { if requestGeneration == generation { isSearching = false } }
    isLoadingMore = false
    loadMoreFailure = nil
    consumedCursors = []
    guard !self.query.isEmpty else {
      state = .idle
      return false
    }
    if retainedPage == nil { state = .loading }
    do {
      if debounced { try await Task.sleep(for: debounce) }
      try Task.checkCancellation()
      let page = try await search(keyword)
      guard requestGeneration == generation else { return false }
      if Task.isCancelled {
        refreshFailure = previousRefreshFailure
        return false
      }
      state = .loaded(page)
      firstPageIDs = Set(page.items.map(\.id))
      return true
    } catch {
      guard requestGeneration == generation else { return false }
      if Task.isCancelled {
        refreshFailure = previousRefreshFailure
        return false
      }
      guard let failure = PutioBrowserErrorPresentation(error: error) else { return false }
      // The shown results stay unconfirmed until a later request lands, even
      // if a retry is cancelled while reappearance already checked them.
      appliedRequest = nil
      if retainedPage != nil {
        refreshFailure = failure
      } else {
        state = .failed(failure)
      }
      return false
    }
  }

  private static func keyword(_ query: String) -> String {
    query.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  public func loadMore() async {
    guard !isSearching, !isLoadingMore, refreshFailure == nil, case .loaded(let current) = state,
      let cursor = current.nextCursor
    else { return }
    let requestGeneration = generation
    isLoadingMore = true
    loadMoreFailure = nil
    defer {
      if requestGeneration == generation {
        isLoadingMore = false
        if Task.isCancelled { paginationEpoch &+= 1 }
      }
    }
    do {
      let page = try await continueSearch(cursor)
      guard requestGeneration == generation, !Task.isCancelled else { return }
      guard page.nextCursor != cursor,
        page.nextCursor.map({ !consumedCursors.contains($0) }) ?? true
      else { throw PutioRuntimeError.invalidResponse }
      consumedCursors.insert(cursor)
      var ids = Set(current.items.map(\.id))
      let appended = page.items.filter { ids.insert($0.id).inserted }
      state = .loaded(
        PutioFileSearchPage(
          items: current.items + appended, nextCursor: page.nextCursor, totalCount: page.totalCount)
      )
    } catch {
      guard requestGeneration == generation, !Task.isCancelled,
        let failure = PutioBrowserErrorPresentation(error: error)
      else { return }
      loadMoreFailure = failure
    }
  }
}
