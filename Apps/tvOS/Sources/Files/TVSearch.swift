import PutioCore
import SwiftUI

/// Search through the system linear keyboard. An empty query lists recent
/// searches; results use the Files rows with a panel for the focused row.
struct TVSearchView: View {
  let account: PutioAccountSnapshot
  let refreshRequests: PutioFolderRefreshRequests
  let open: (PutioFileItem) -> Void
  let play: ((PutioFileItem, PutioVideoResumePrompt.Choice) -> Void)?

  @State private var query: String
  @State private var model: PutioFileSearchModel
  @State private var itemActions: PutioFileItemActionModel
  @State private var recent: PutioRecentSearchesModel?
  @State private var pins: PutioPinnedFilesModel?
  @State private var folderNames: PutioFolderNames?
  @State private var externalPlayback: PutioExternalPlaybackModel?
  @State private var moving: PutioFileItem?
  @FocusState private var focusedRow: PutioFileID?
  @FocusState private var focusedRecent: String?
  @State private var recentRemoval: TVRecentRemoval?
  @State private var focusTarget: PutioFileID?
  @State private var shownItemID: PutioFileID?
  @State private var showsPanel = false
  @State private var recordedQuery: String?
  @State private var toast: PutioToast?
  @State private var now: Date
  private let locale: Locale
  private let searchesOnChange: Bool
  private let moveSource: TVMoveSource?

  init(
    runtime: PutioRuntime, account: PutioAccountSnapshot,
    refreshRequests: PutioFolderRefreshRequests, open: @escaping (PutioFileItem) -> Void,
    play: ((PutioFileItem, PutioVideoResumePrompt.Choice) -> Void)? = nil
  ) {
    self.init(
      model: PutioFileSearchModel(
        search: { try await runtime.searchFiles(query: $0, filter: $1) },
        continueSearch: { try await runtime.continueFileSearch(cursor: $0) }),
      actions: PutioFileActions(runtime: runtime),
      recent: PutioRecentSearchesModel(actions: PutioRecentSearchActions(runtime: runtime)),
      pins: PutioPinnedFilesModel(
        actions: PutioPinnedFilesActions(runtime: runtime), rootName: TVFolderCopy.yourFiles),
      folderNames: PutioFolderNames(rootName: TVFolderCopy.yourFiles) {
        try await runtime.getFile(fileID: $0)
      },
      externalPlayback: TVExternalPlayback.model(runtime: runtime),
      moveSource: TVMoveSource(runtime: runtime), account: account,
      refreshRequests: refreshRequests, open: open, play: play)
  }

  /// `searchesOnChange: false` keeps an already searched model as it is, for
  /// rendering a fixed state.
  init(
    model: PutioFileSearchModel, actions: PutioFileActions,
    recent: PutioRecentSearchesModel? = nil, pins: PutioPinnedFilesModel? = nil,
    folderNames: PutioFolderNames? = nil, externalPlayback: PutioExternalPlaybackModel? = nil,
    moveSource: TVMoveSource? = nil, account: PutioAccountSnapshot,
    refreshRequests: PutioFolderRefreshRequests = PutioFolderRefreshRequests(),
    query: String = "", now: Date = .now, locale: Locale = .current,
    searchesOnChange: Bool = true, open: @escaping (PutioFileItem) -> Void,
    play: ((PutioFileItem, PutioVideoResumePrompt.Choice) -> Void)? = nil
  ) {
    self.account = account
    self.refreshRequests = refreshRequests
    self.open = open
    self.play = play
    self.locale = locale
    self.searchesOnChange = searchesOnChange
    self.moveSource = moveSource
    _query = State(initialValue: query)
    _model = State(initialValue: model)
    _itemActions = State(
      initialValue: PutioFileItemActionModel(actions: actions, refreshRequests: refreshRequests))
    _recent = State(initialValue: recent)
    _pins = State(initialValue: pins)
    _folderNames = State(initialValue: folderNames)
    _externalPlayback = State(initialValue: externalPlayback)
    _now = State(initialValue: now)
  }

  var body: some View {
    content
      .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
      .tvOverscanPadding()
      .background(PutioTheme.Colors.background.ignoresSafeArea())
      .searchable(text: $query, prompt: PutioSearchResultPresentation.prompt)
      .onSubmit(of: .search) { record(query) }
      .task {
        guard searchesOnChange else { return }
        await recent?.load()
      }
      .task {
        guard searchesOnChange else { return }
        await pins?.load()
      }
      .task(id: Request(query: query, revision: refreshRequests.revision)) {
        guard searchesOnChange else { return }
        await model.apply(query: query, revision: refreshRequests.revision)
      }
      .onAppear { if searchesOnChange { now = .now } }
      .onChange(of: query) {
        showsPanel = false
        shownItemID = nil
      }
      .onChange(of: focusedRow) { _, row in
        guard let row else { return }
        shownItemID = row
        showsPanel = true
        record(query)
      }
      .onChange(of: model.resultsRevision) {
        itemActions.revealHiddenItems(reflecting: model.resultsRefreshRevision)
      }
      .onChange(of: NamesRequest(id: panelItem?.parentID, revision: refreshRequests.revision)) {
        _, request in
        guard let id = request.id else { return }
        folderNames?.resolve([id], revision: request.revision)
      }
      .onChange(of: itemActions.outcome) { _, outcome in
        // The Move sheet settles its own outcome; a name clash keeps it open.
        guard let outcome, moving == nil else { return }
        toast = TVFilePresentation.toast(for: outcome, trashEnabled: account.trashEnabled)
        itemActions.clearOutcome()
      }
      .onChange(of: recent?.editFailure) { _, failure in
        guard failure != nil else { return }
        recentRemoval = nil
        toast = PutioToast(PutioRecentSearchesCopy.editFailed, icon: .warning, width: .fit)
        recent?.clearEditFailure()
      }
      .onChange(of: pins?.editFailure) { _, failure in
        guard failure != nil else { return }
        toast = PutioToast(PutioScreenErrorKind.failed.message, icon: .warning, width: .fit)
        pins?.clearEditFailure()
      }
      .modifier(
        TVExternalPlaybackPresentation(model: externalPlayback, toast: $toast) {
          focusTarget = shownItemID
        }
      )
      .modifier(TVFocusHandoff(target: $focusTarget, focusedRow: $focusedRow))
      .tvMoveSheet($moving, source: moveSource) { item, destination in
        await move(item, to: destination)
      } dismissed: {
        if focusTarget == nil { focusTarget = shownItemID }
      }
      .onChange(of: focusedRecent) { _, focused in
        guard let removal = recentRemoval, focused == removal.term else { return }
        recentRemoval = nil
        remove(removal)
      }
      .putioToast($toast)
  }

  @ViewBuilder
  private var content: some View {
    switch model.state {
    case .idle:
      if let recent, !recent.terms.isEmpty {
        recentSearches(recent)
      } else {
        let start = PutioSearchResultPresentation.start
        PutioEmptyStateView(
          kaomoji: start.kaomoji ?? .curious, title: start.title, message: start.message
        )
        .accessibilityIdentifier("search.start")
        .frame(maxWidth: .infinity, maxHeight: .infinity)
      }
    case .loading:
      PutioLoadingStateView(
        title: PutioSearchResultPresentation.searching, titleVisibility: .hidden
      )
      .frame(maxWidth: .infinity, maxHeight: .infinity)
    case .failed(let failure):
      let copy = PutioSearchResultPresentation.failed(failure)
      PutioEmptyStateView(
        kaomoji: copy.kaomoji ?? .knockedOut, title: copy.title, message: copy.message,
        actionTitle: String(localized: "Try again", bundle: .putioCore),
        actionIcon: .arrowsClockwise, actionIdentifier: "search.retry"
      ) {
        record(query)
        Task { await model.refresh(query: query, revision: refreshRequests.revision) }
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
    case .loaded(let page):
      if page.items.isEmpty, page.nextCursor == nil, model.refreshFailure == nil {
        let nothing = PutioSearchResultPresentation.nothingMatches(query)
        PutioEmptyStateView(
          kaomoji: nothing.copy.kaomoji ?? .uneasy, title: nothing.copy.title,
          message: nothing.copy.message.replacingOccurrences(
            of: PutioSearchResultPresentation.termMark, with: "“\(nothing.term)”")
        )
        .accessibilityIdentifier("search.empty")
        .frame(maxWidth: .infinity, maxHeight: .infinity)
      } else {
        HStack(alignment: .top, spacing: PutioTheme.TV.Spacing.large) {
          list(page)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
          if showsPanel, let item = panelItem {
            panel(item)
          } else {
            Color.clear.frame(width: TVDetailPanelLayout.width)
          }
        }
      }
    }
  }

  private func recentSearches(_ recent: PutioRecentSearchesModel) -> some View {
    VStack(alignment: .leading, spacing: PutioTheme.TV.Spacing.small) {
      HStack(spacing: PutioTheme.TV.Spacing.small) {
        Text(PutioRecentSearchesCopy.title)
          .putioFont(PutioTheme.TV.Typography.caption)
          .foregroundStyle(PutioTheme.TV.Colors.textSecondary)
          .accessibilityAddTraits(.isHeader)
        Spacer(minLength: PutioTheme.TV.Spacing.medium)
        PutioButton(PutioRecentSearchesCopy.clear, icon: .x, tier: .secondary) {
          recordedQuery = nil
          Task { await recent.clear() }
        }
        .fixedSize()
        .accessibilityIdentifier("search.recent-clear")
      }
      .focusSection()
      TVRowList {
        ForEach(recent.terms, id: \.self) { term in
          Button {
            query = term
            record(term)
          } label: {
            HStack(spacing: PutioTheme.TV.Spacing.small) {
              Image(putioIcon: .clockCounterClockwise)
                .resizable()
                .scaledToFit()
                .frame(width: TVRowLayout.disclosureSize, height: TVRowLayout.disclosureSize)
                .foregroundStyle(.putioRowIcon)
                .accessibilityHidden(true)
              Text(term)
                .putioFont(PutioTheme.TV.Typography.label)
                .foregroundStyle(.putioRowPrimary)
                .lineLimit(1)
            }
            .tvRowPadding()
          }
          .contextMenu {
            Button {
              recordedQuery = nil
              let terms = recent.terms
              let next = terms.firstIndex(of: term).flatMap { index in
                terms.indices.contains(index + 1)
                  ? terms[index + 1] : index > 0 ? terms[index - 1] : nil
              }
              let removal = TVRecentRemoval(term: term, next: next)
              if focusedRecent == term { remove(removal) } else { recentRemoval = removal }
            } label: {
              Label {
                Text(PutioRecentSearchesCopy.remove)
              } icon: {
                Image(putioIcon: .x)
              }
            }
            .accessibilityIdentifier("search.recent-remove")
          }
          .focused($focusedRecent, equals: term)
          .accessibilityIdentifier("search.recent.\(term)")
        }
      }
      .focusSection()
    }
  }

  private var visibleItems: [PutioFileItem] {
    guard case .loaded(let page) = model.state else { return [] }
    return page.items.filter { !itemActions.hiddenIDs.contains($0.id) }
  }

  private var panelItem: PutioFileItem? {
    let items = visibleItems
    return items.first { $0.id == shownItemID } ?? items.first
  }

  private var isRowFocused: Bool { focusedRow != nil }

  private func list(_ page: PutioFileSearchPage) -> some View {
    TVRowList {
      if let failure = model.refreshFailure {
        TVRetrySection(message: failure.message, identifier: "search.refresh-retry") {
          await model.refresh(query: query, revision: refreshRequests.revision)
        }
      }
      if let total = PutioFileSearchTotal(
        page: page, filter: model.filter, hiddenIDs: itemActions.hiddenIDs)
      {
        Text(total.label(locale: locale))
          .putioFont(PutioTheme.TV.Typography.caption)
          .foregroundStyle(PutioTheme.TV.Colors.textSecondary)
          .accessibilityIdentifier("search.count")
      }
      ForEach(visibleItems) { item in
        Button {
          record(query)
          open(item)
        } label: {
          PutioFileRow(
            PutioBrowserItemPresentation(item: item, relativeTo: now, locale: locale).row)
        }
        .tvRowOpen(!isRowFocused && showsPanel && panelItem?.id == item.id)
        .focused($focusedRow, equals: item.id)
        .disabled(!itemActions.canStartAction)
        .accessibilityIdentifier("search.item.\(item.id.rawValue)")
      }
      if let cursor = page.nextCursor, model.refreshFailure == nil {
        if let failure = model.loadMoreFailure {
          TVRetrySection(message: failure.message, identifier: "search.more-retry") {
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
    .focusSection()
  }

  private var pinnedState: (PutioFileID) -> Bool? {
    guard let pins, case .loaded = pins.state else { return { _ in nil } }
    return { pins.isPinned($0) }
  }

  private func panel(_ item: PutioFileItem) -> some View {
    let menu = PutioFileMenu.searchResult(
      item: item,
      capabilities: .tv(tracksWatched: account.rememberVideoTime, pinned: pinnedState(item.id)))
    return TVFilePanel(
      item: item,
      row: PutioBrowserItemPresentation(item: item, relativeTo: now, locale: locale).row,
      sections: TVFilePresentation.panelRows(
        menu, canStartOver: play != nil, canOpenInVLC: externalPlayback != nil,
        canMove: moveSource != nil, canDelete: itemActions.canDelete),
      trashEnabled: account.trashEnabled, identifier: "search.panel"
    ) { perform($0, on: item) }
    .disabled(!itemActions.canStartAction)
  }

  private func perform(_ row: PutioFileMenuRow, on item: PutioFileItem) {
    record(query)
    switch row {
    case .open:
      open(item)
    case .play:
      playVideo(item, .resume)
    case .startOver:
      playVideo(item, .startOver)
    case .pin:
      let location = folderNames?.names[item.parentID]
      Task { await pins?.pin(item, in: location) }
    case .unpin:
      Task { await pins?.unpin(item) }
    case .openInVLC:
      Task { await externalPlayback?.open(PutioFileRoute(item: item)) }
    case .move:
      moving = item
    default:
      if case .setWatched(_, let watched) = PutioFileItemActionRequest(row: row, item: item)?
        .step(trashEnabled: account.trashEnabled)
      {
        focusTarget = PutioFolderContents.neighbour(
          keeping: item.id, in: visibleItems, firstPage: model.firstPageIDs)
        Task { await itemActions.setWatched(item, watched) }
      }
    }
  }

  /// A result stays listed where it moved; the sheet stays open only when
  /// the destination already holds the name.
  private func move(
    _ item: PutioFileItem, to destination: PutioFolderRoute
  ) async -> TVMoveResult {
    await itemActions.move(item, to: destination)
    switch itemActions.settleMove(of: item) {
    case .nameTaken(let name):
      return .nameTaken(name)
    case .settled(let outcome?):
      toast = TVFilePresentation.toast(for: outcome, trashEnabled: account.trashEnabled)
      itemActions.clearOutcome()
    case .settled(nil):
      break
    }
    focusTarget = item.id
    moving = nil
    return .closed
  }

  private func playVideo(_ item: PutioFileItem, _ choice: PutioVideoResumePrompt.Choice) {
    guard let play else { return open(item) }
    play(item, choice)
  }

  private func remove(_ removal: TVRecentRemoval) {
    if let next = removal.next { focusedRecent = next }
    Task { await recent?.remove(removal.term) }
  }

  private func record(_ term: String) {
    let trimmed = term.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty, trimmed != recordedQuery, let recent else { return }
    recordedQuery = trimmed
    Task { await recent.record(trimmed) }
  }

  private struct Request: Equatable {
    let query: String
    let revision: UInt64
  }

  private struct NamesRequest: Equatable {
    let id: PutioFileID?
    let revision: UInt64
  }

  private struct PageRequest: Equatable {
    let cursor: String
    let generation: UInt64
    let isSearching: Bool
    let epoch: UInt64
  }
}

private struct TVRecentRemoval: Equatable {
  let term: String
  let next: String?
}
