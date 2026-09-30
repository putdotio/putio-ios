import Foundation
import Observation
import PutioCore
import SwiftUI

typealias PutioFileSearch = @MainActor @Sendable (String) async throws -> PutioFileSearchPage

@MainActor
@Observable
final class PutioFileSearchModel {
  enum State: Equatable {
    case idle
    case loading
    case loaded(PutioFileSearchPage)
    case failed(PutioBrowserErrorPresentation)
  }

  private(set) var state: State = .idle
  private(set) var query = ""
  private(set) var isLoadingMore = false
  private(set) var isSearching = false
  private(set) var refreshFailure: PutioBrowserErrorPresentation?
  private(set) var loadMoreFailure: PutioBrowserErrorPresentation?
  private(set) var generation: UInt64 = 0
  private(set) var paginationEpoch: UInt64 = 0
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

  init(
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
  func apply(query: String, revision: UInt64) async {
    let request = Request(query: Self.keyword(query), revision: revision)
    if request == appliedRequest, request.query == self.query, case .loaded = state,
      refreshFailure == nil
    {
      return
    }
    if await update(query: request.query) { appliedRequest = request }
  }

  func refresh(query: String, revision: UInt64) async {
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
      return true
    } catch {
      guard requestGeneration == generation else { return false }
      if Task.isCancelled {
        refreshFailure = previousRefreshFailure
        return false
      }
      guard let failure = PutioBrowserErrorPresentation(error: error) else { return false }
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

  func loadMore() async {
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

@MainActor
struct FilesSearchView: View {
  let runtime: PutioRuntime
  let trashEnabled: Bool
  let refreshRequests: PutioFolderRefreshRequests
  let onFileSelected: PutioFileSelection

  @State private var query = ""
  @State private var model: PutioFileSearchModel
  @State private var itemActions: PutioFileItemActionModel
  @State private var itemAction: PutioFileItemActionRequest?

  init(
    runtime: PutioRuntime,
    trashEnabled: Bool,
    refreshRequests: PutioFolderRefreshRequests,
    onFileSelected: @escaping PutioFileSelection
  ) {
    self.runtime = runtime
    self.trashEnabled = trashEnabled
    self.refreshRequests = refreshRequests
    self.onFileSelected = onFileSelected
    _model = State(
      initialValue: PutioFileSearchModel(
        search: { try await runtime.searchFiles(query: $0) },
        continueSearch: { try await runtime.continueFileSearch(cursor: $0) }
      ))
    _itemActions = State(
      initialValue: PutioFileItemActionModel(actions: PutioFileActions(runtime: runtime)))
  }

  var body: some View {
    NavigationStack {
      results
        .navigationTitle("Search")
        .putioContentBackground()
        .searchable(text: $query, prompt: "Search in Files")
        .task(id: Request(query: query, revision: refreshRequests.revision)) {
          await model.apply(query: query, revision: refreshRequests.revision)
        }
        .navigationDestination(for: PutioFolderRoute.self) { route in
          PutioFolderScreen(
            route: route,
            load: { try await runtime.listFiles(parentID: $0) },
            continueLoad: { try await runtime.continueFiles(cursor: $0) },
            actions: PutioFileActions(runtime: runtime),
            trashEnabled: trashEnabled,
            refreshRequests: refreshRequests,
            onFileSelected: onFileSelected
          )
        }
        .modifier(
          PutioFileItemActionsHost(
            request: $itemAction,
            model: itemActions,
            actions: PutioFileActions(runtime: runtime),
            load: { try await runtime.listFiles(parentID: $0) },
            continueLoad: { try await runtime.continueFiles(cursor: $0) },
            trashEnabled: trashEnabled,
            refreshRequests: refreshRequests
          ))
    }
  }

  @ViewBuilder
  private var results: some View {
    switch model.state {
    case .idle:
      PutioEmptyStateView(
        icon: .file, title: "Search your files", message: "Find files by their stored name.")
    case .loading:
      PutioLoadingStateView(title: "Searching files")
    case .failed(let failure):
      PutioErrorStateView(
        title: "Could not search files", message: failure.message,
        retryTitle: "Try again",
        retryIdentifier: "files.search-retry"
      ) {
        Task { await model.refresh(query: query, revision: refreshRequests.revision) }
      }
    case .loaded(let page):
      if page.items.isEmpty, page.nextCursor == nil, model.refreshFailure == nil {
        GeometryReader { geometry in
          ScrollView {
            PutioEmptyStateView(
              icon: .file, title: "No results", message: "Try a different file name."
            )
            .frame(minHeight: geometry.size.height)
          }
          .scrollBounceBehavior(.always)
          .refreshable { await model.refresh(query: query, revision: refreshRequests.revision) }
        }
      } else {
        List {
          if let failure = model.refreshFailure {
            VStack(spacing: PutioTheme.Spacing.space2) {
              Text(failure.message)
                .putioFont(PutioTheme.Typography.caption)
              Button("Try again") {
                Task { await model.refresh(query: query, revision: refreshRequests.revision) }
              }
              .accessibilityIdentifier("files.search-retry")
            }
            .listRowBackground(PutioTheme.Colors.background)
          }
          ForEach(page.items) { item in
            resultRow(PutioBrowserItemPresentation(item: item))
              .listRowBackground(PutioTheme.Colors.background)
          }
          if let cursor = page.nextCursor, model.refreshFailure == nil {
            Group {
              if let failure = model.loadMoreFailure {
                VStack(spacing: PutioTheme.Spacing.space2) {
                  Text(failure.message)
                    .putioFont(PutioTheme.Typography.caption)
                  Button("Try again") { Task { await model.loadMore() } }
                    .accessibilityIdentifier("files.search-more-retry")
                }
              } else {
                ProgressView("Loading more results")
                  .task(
                    id: PageRequest(
                      cursor: cursor, generation: model.generation, isSearching: model.isSearching,
                      epoch: model.paginationEpoch)
                  ) {
                    await model.loadMore()
                  }
              }
            }
            .listRowBackground(PutioTheme.Colors.background)
          }
        }
        .listStyle(.plain)
        .refreshable { await model.refresh(query: query, revision: refreshRequests.revision) }
      }
    }
  }

  @ViewBuilder
  private func resultRow(_ presentation: PutioBrowserItemPresentation) -> some View {
    Group {
      if let route = presentation.folderRoute {
        NavigationLink(value: route) { PutioFileRow(presentation.row) }
      } else if let route = presentation.fileRoute {
        Button {
          onFileSelected(route)
        } label: {
          PutioFileRow(presentation.row)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
      }
    }
    .accessibilityIdentifier("files.search-item.\(presentation.id.rawValue)")
    .contextMenu { itemActionButtons(for: presentation.item) }
    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
      itemActionButtons(for: presentation.item).deleteButton
        .tint(PutioTheme.Colors.destructive)
    }
    .swipeActions(edge: .leading, allowsFullSwipe: false) {
      itemActionButtons(for: presentation.item).moveButton
        .tint(PutioTheme.Colors.accent)
    }
  }

  private func itemActionButtons(for item: PutioFileItem) -> PutioFileItemActionButtons {
    PutioFileItemActionButtons(
      item: item,
      trashEnabled: trashEnabled,
      isDisabled: !itemActions.canStartAction || itemAction != nil,
      canDelete: itemActions.canDelete
    ) { itemAction = $0 }
  }

  private struct Request: Equatable {
    let query: String
    let revision: UInt64
  }

  private struct PageRequest: Equatable {
    let cursor: String
    let generation: UInt64
    let isSearching: Bool
    let epoch: UInt64
  }
}
