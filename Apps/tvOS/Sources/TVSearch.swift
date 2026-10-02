import PutioCore
import SwiftUI

/// Search through the system linear keyboard. Results use the browser's
/// file rows and long-press menu; query, paging, and actions come from the
/// shared search and item-action models.
struct TVSearchView: View {
  let account: PutioAccountSnapshot
  let refreshRequests: PutioFolderRefreshRequests
  let open: (PutioFileItem) -> Void

  @State private var query: String
  @State private var model: PutioFileSearchModel
  @State private var itemActions: PutioFileItemActionModel
  @State private var menuItem: PutioFileItem?
  @FocusState private var focusedRow: PutioFileID?
  @State private var toast: PutioToast?
  @State private var now: Date
  private let locale: Locale
  private let searchesOnChange: Bool

  init(
    runtime: PutioRuntime, account: PutioAccountSnapshot,
    refreshRequests: PutioFolderRefreshRequests, open: @escaping (PutioFileItem) -> Void
  ) {
    self.init(
      model: PutioFileSearchModel(
        search: { try await runtime.searchFiles(query: $0) },
        continueSearch: { try await runtime.continueFileSearch(cursor: $0) }),
      actions: PutioFileActions(runtime: runtime), account: account,
      refreshRequests: refreshRequests, open: open)
  }

  /// `searchesOnChange: false` keeps an already searched model as it is, for
  /// rendering a fixed state.
  init(
    model: PutioFileSearchModel, actions: PutioFileActions, account: PutioAccountSnapshot,
    refreshRequests: PutioFolderRefreshRequests = PutioFolderRefreshRequests(),
    query: String = "", now: Date = .now, locale: Locale = .current,
    searchesOnChange: Bool = true, open: @escaping (PutioFileItem) -> Void
  ) {
    self.account = account
    self.refreshRequests = refreshRequests
    self.open = open
    self.locale = locale
    self.searchesOnChange = searchesOnChange
    _query = State(initialValue: query)
    _model = State(initialValue: model)
    _itemActions = State(
      initialValue: PutioFileItemActionModel(actions: actions, refreshRequests: refreshRequests))
    _now = State(initialValue: now)
  }

  var body: some View {
    results
      .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
      .tvOverscanPadding()
      .background(PutioTheme.Colors.background.ignoresSafeArea())
      .searchable(text: $query, prompt: "Search your files")
      .task(id: Request(query: query, revision: refreshRequests.revision)) {
        guard searchesOnChange else { return }
        await model.apply(query: query, revision: refreshRequests.revision)
      }
      .onAppear { if searchesOnChange { now = .now } }
      // Reloaded results reflect every settled delete.
      .onChange(of: model.state) { itemActions.revealHiddenItems() }
      .tvFileMenu(
        item: $menuItem, account: account, canDelete: itemActions.canDelete,
        setWatched: { item, watched in Task { await itemActions.setWatched(item, watched) } },
        delete: { item in
          if account.trashEnabled { itemActions.hideForTrash(item) }
          Task { await itemActions.delete(item) }
        }
      )
      .onChange(of: itemActions.outcome) { _, outcome in
        guard let outcome else { return }
        toast = TVFilePresentation.toast(for: outcome, trashEnabled: account.trashEnabled)
        itemActions.clearOutcome()
      }
      .tvToast($toast)
  }

  @ViewBuilder
  private var results: some View {
    switch model.state {
    case .idle:
      Color.clear
    case .loading:
      PutioLoadingStateView(title: "Searching files")
    case .failed(let failure):
      PutioErrorStateView(
        title: "Could not search files", message: failure.message, retryTitle: "Try again",
        retryIdentifier: "search.retry"
      ) {
        Task { await model.refresh(query: query, revision: refreshRequests.revision) }
      }
    case .loaded(let page):
      if page.items.isEmpty, page.nextCursor == nil, model.refreshFailure == nil {
        ContentUnavailableView.search(text: query)
          .accessibilityIdentifier("search.empty")
      } else {
        list(page)
      }
    }
  }

  private func list(_ page: PutioFileSearchPage) -> some View {
    TVRowList {
      if let failure = model.refreshFailure {
        TVRetrySection(message: failure.message, identifier: "search.refresh-retry") {
          await model.refresh(query: query, revision: refreshRequests.revision)
        }
      }
      Text(page.totalCount == 1 ? "1 result" : "\(page.totalCount) results")
        .putioFont(PutioTheme.TV.Typography.caption)
        .foregroundStyle(PutioTheme.TV.Colors.textSecondary)
        .accessibilityIdentifier("search.count")
      ForEach(page.items.filter { !itemActions.hiddenIDs.contains($0.id) }) { item in
        TVFileRowButton(
          presentation: PutioBrowserItemPresentation(item: item, relativeTo: now, locale: locale),
          identifier: "search.item.\(item.id.rawValue)",
          open: { open(item) },
          showMenu: { if itemActions.canStartAction { menuItem = item } }
        )
        .focused($focusedRow, equals: item.id)
      }
      if let cursor = page.nextCursor, model.refreshFailure == nil {
        if let failure = model.loadMoreFailure {
          TVRetrySection(message: failure.message, identifier: "search.more-retry") {
            // Keeps focus at the end of the results as the retry row goes.
            focusedRow = page.items.last?.id
            await model.loadMore()
          }
        } else {
          ProgressView("Loading more results")
            .frame(maxWidth: .infinity)
            .accessibilityIdentifier("search.load-more")
            .task(
              id: PageRequest(
                cursor: cursor, generation: model.generation, isSearching: model.isSearching,
                epoch: model.paginationEpoch)
            ) {
              await model.loadMore()
            }
        }
      }
    }
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
