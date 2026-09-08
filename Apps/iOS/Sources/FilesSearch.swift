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

  init(
    search: @escaping PutioFileSearch,
    continueSearch: @escaping PutioFileSearch,
    debounce: Duration = .milliseconds(300)
  ) {
    self.search = search
    self.continueSearch = continueSearch
    self.debounce = debounce
  }

  func update(query: String, debounced: Bool = true) async {
    let keyword = query.trimmingCharacters(in: .whitespacesAndNewlines)
    let retainedPage: PutioFileSearchPage?
    if keyword == self.query, case .loaded(let page) = state {
      retainedPage = page
    } else {
      retainedPage = nil
    }
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
      return
    }
    if retainedPage == nil { state = .loading }
    do {
      if debounced { try await Task.sleep(for: debounce) }
      try Task.checkCancellation()
      let page = try await search(keyword)
      guard requestGeneration == generation, !Task.isCancelled else { return }
      state = .loaded(page)
    } catch {
      guard requestGeneration == generation, !Task.isCancelled,
        let failure = PutioBrowserErrorPresentation(error: error)
      else { return }
      if retainedPage != nil {
        refreshFailure = failure
      } else {
        state = .failed(failure)
      }
    }
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
  }

  var body: some View {
    NavigationStack {
      results
        .navigationTitle("Search")
        .putioContentBackground()
        .searchable(text: $query, prompt: "Search in Files")
        .task(id: Request(query: query, revision: refreshRequests.revision)) {
          await model.update(query: query)
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
        Task { await model.update(query: query, debounced: false) }
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
          .refreshable { await model.update(query: query, debounced: false) }
        }
      } else {
        List {
          if let failure = model.refreshFailure {
            VStack(spacing: PutioTheme.Spacing.space2) {
              Text(failure.message)
                .putioFont(PutioTheme.Typography.caption)
              Button("Try again") {
                Task { await model.update(query: query, debounced: false) }
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
        .refreshable { await model.update(query: query, debounced: false) }
      }
    }
  }

  @ViewBuilder
  private func resultRow(_ presentation: PutioBrowserItemPresentation) -> some View {
    Group {
      if let route = presentation.folderRoute {
        NavigationLink(value: route) { PutioFileRow(presentation.row) }
      } else if let route = presentation.fileRoute, route.videoPlaybackRoute != nil {
        Button {
          onFileSelected(route)
        } label: {
          PutioFileRow(presentation.row)
        }
        .buttonStyle(.plain)
      } else {
        PutioFileRow(presentation.row)
      }
    }
    .accessibilityIdentifier("files.search-item.\(presentation.id.rawValue)")
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
