import Foundation
import Observation
import PutioCore
import SwiftUI

@MainActor
struct FilesSearchView: View {
  let runtime: PutioRuntime
  let trashEnabled: Bool
  let tracksWatched: Bool
  let refreshRequests: PutioFolderRefreshRequests
  let pins: PutioPinnedFilesModel
  let onFileSelected: PutioFileSelection
  let onExternalPlayback: PutioFileSelection?
  let onDownload: PutioFileSelection?

  @State private var query = ""
  @State private var filter = PutioFileSearchFilter.all
  @State private var model: PutioFileSearchModel
  @State private var recent: PutioRecentSearchesModel
  @State private var folderNames: PutioFolderNames
  @State private var itemActions: PutioFileItemActionModel
  @State private var itemAction: PutioFileItemActionRequest?
  @State private var share = PutioFileShareModel()
  @State private var toast: PutioToast?
  @State private var preparingToast: PutioToast.ID?
  @Environment(\.putioFileShare) private var fileShare
  @Environment(\.locale) private var locale

  init(
    runtime: PutioRuntime,
    trashEnabled: Bool,
    tracksWatched: Bool,
    refreshRequests: PutioFolderRefreshRequests,
    pins: PutioPinnedFilesModel,
    onFileSelected: @escaping PutioFileSelection,
    onExternalPlayback: PutioFileSelection?,
    onDownload: PutioFileSelection?
  ) {
    self.runtime = runtime
    self.trashEnabled = trashEnabled
    self.tracksWatched = tracksWatched
    self.refreshRequests = refreshRequests
    self.pins = pins
    self.onFileSelected = onFileSelected
    self.onExternalPlayback = onExternalPlayback
    self.onDownload = onDownload
    _model = State(
      initialValue: PutioFileSearchModel(
        search: { try await runtime.searchFiles(query: $0, filter: $1) },
        continueSearch: { try await runtime.continueFileSearch(cursor: $0) }
      ))
    _recent = State(
      initialValue: PutioRecentSearchesModel(actions: PutioRecentSearchActions(runtime: runtime)))
    _folderNames = State(
      initialValue: PutioFolderNames(rootName: PutioFolderRoute.root.title) {
        try await runtime.getFile(fileID: $0)
      })
    _itemActions = State(
      initialValue: PutioFileItemActionModel(
        actions: PutioFileActions(runtime: runtime), refreshRequests: refreshRequests))
  }

  var body: some View {
    NavigationStack {
      results
        .safeAreaInset(edge: .top, spacing: 0) {
          if model.state != .idle { filterBar }
        }
        .navigationTitle("Search")
        .putioContentBackground()
        .searchable(text: $query, prompt: "Search your files")
        .onSubmit(of: .search) {
          Task { await recent.record(query) }
        }
        .task { await recent.load() }
        .onChange(of: recent.editFailure) { _, failure in
          guard failure != nil else { return }
          recent.clearEditFailure()
          toast = PutioToast(String(localized: "Couldn’t update recent searches"))
        }
        .task(id: Request(query: query, filter: filter, revision: refreshRequests.revision)) {
          await model.apply(query: query, filter: filter, revision: refreshRequests.revision)
        }
        .onChange(
          of: NamesRequest(ids: shownParentIDs, revision: refreshRequests.revision), initial: true
        ) { _, request in
          folderNames.resolve(request.ids, revision: request.revision)
        }
        .navigationDestination(for: PutioFolderRoute.self) { route in
          PutioFolderScreen(
            route: route,
            load: {
              try await runtime.listFiles(parentID: $0, perPage: PutioRuntime.folderPageSize)
            },
            continueLoad: { try await runtime.continueFiles(cursor: $0) },
            actions: PutioFileActions(runtime: runtime),
            trashEnabled: trashEnabled,
            tracksWatched: tracksWatched,
            refreshRequests: refreshRequests,
            onFileSelected: onFileSelected,
            onExternalPlayback: onExternalPlayback,
            onDownload: onDownload
          )
        }
        .modifier(
          PutioFileItemActionsHost(
            request: $itemAction,
            model: itemActions,
            actions: PutioFileActions(runtime: runtime),
            load: {
              try await runtime.listFiles(parentID: $0, perPage: PutioRuntime.folderPageSize)
            },
            continueLoad: { try await runtime.continueFiles(cursor: $0) },
            trashEnabled: trashEnabled,
            refreshRequests: refreshRequests
          )
        )
        .onChange(of: model.state) { itemActions.revealHiddenItems() }
        .onChange(of: share.state) { _, state in
          if case .fetching = state { return }
          if toast?.id == preparingToast { toast = nil }
          preparingToast = nil
        }
        .onDisappear { share.leave() }
        .putioToast($toast)
    }
  }

  private var filterBar: some View {
    ScrollView(.horizontal) {
      HStack(spacing: PutioTheme.Spacing.space2) {
        ForEach(PutioFileSearchFilter.allCases, id: \.self) { option in
          filterChip(option)
        }
      }
      .padding(.horizontal, PutioTheme.Spacing.space4)
      .padding(.vertical, PutioTheme.Spacing.space2)
    }
    .scrollIndicators(.hidden)
    .background(PutioTheme.Colors.background)
    .accessibilityIdentifier("files.search-filters")
  }

  private func filterChip(_ option: PutioFileSearchFilter) -> some View {
    let isSelected = option == filter
    return Button {
      filter = option
    } label: {
      HStack(spacing: PutioTheme.Spacing.space1) {
        if isSelected {
          Image(systemName: "checkmark")
            .imageScale(.small)
            .foregroundStyle(PutioTheme.Colors.accent)
            .accessibilityHidden(true)
        }
        Text(Self.title(option))
          .fontWeight(isSelected ? .semibold : .regular)
      }
      .putioFont(PutioTheme.Components.Button.label)
    }
    .buttonStyle(.bordered)
    .buttonBorderShape(.capsule)
    .tint(PutioTheme.Colors.textPrimary)
    .accessibilityAddTraits(isSelected ? .isSelected : [])
    .accessibilityIdentifier("files.search-filter.\(option.rawValue)")
  }

  private static func title(_ filter: PutioFileSearchFilter) -> String {
    switch filter {
    case .all: String(localized: "All")
    case .folders: String(localized: "Folders")
    case .videos: String(localized: "Videos")
    case .audio: String(localized: "Audio")
    case .images: String(localized: "Images")
    case .documents: String(localized: "Documents")
    case .subtitles: String(localized: "Subtitles")
    }
  }

  private var shownItems: [PutioFileItem] {
    guard case .loaded(let page) = model.state else { return [] }
    return page.items.filter {
      !itemActions.hiddenIDs.contains($0.id) && model.filter.accepts($0)
    }
  }

  private var shownParentIDs: [PutioFileID] {
    PutioFileSearchGroups(shownItems).parentIDs
  }

  @ViewBuilder
  private var results: some View {
    switch model.state {
    case .idle:
      RecentSearchesView(model: recent) { term in
        query = term
        Task { await recent.record(term) }
      }
    case .loading:
      PutioLoadingStateView(
        title: String(localized: "Searching files"), titleVisibility: .hidden)
    case .failed(let failure):
      PutioErrorStateView(
        title: String(localized: "Couldn’t search"),
        message: failure.message,
        retryTitle: String(localized: "Try again"),
        retryIdentifier: "files.search-retry"
      ) {
        Task { await refresh() }
      }
    case .loaded(let page):
      let groups = PutioFileSearchGroups(shownItems)
      if groups.folders.isEmpty, groups.files.isEmpty, page.nextCursor == nil,
        model.refreshFailure == nil
      {
        GeometryReader { geometry in
          ScrollView {
            PutioEmptyStateView(
              kaomoji: .shrug, title: String(localized: "Nothing matches"),
              attributedMessage: noResultsMessage(model.query)
            )
            .frame(minHeight: geometry.size.height)
          }
          .scrollBounceBehavior(.always)
          .refreshable { await refresh() }
        }
      } else {
        List {
          if let failure = model.refreshFailure {
            VStack(spacing: PutioTheme.Spacing.space2) {
              Text(failure.message)
                .putioFont(PutioTheme.Typography.caption)
              Button("Try again") {
                Task { await refresh() }
              }
              .accessibilityIdentifier("files.search-retry")
            }
            .listRowBackground(PutioTheme.Colors.background)
          }
          group(String(localized: "Folders"), id: "folders", items: groups.folders)
          group(String(localized: "Files"), id: "files", items: groups.files)
          if let cursor = page.nextCursor, model.refreshFailure == nil {
            Group {
              if model.loadMoreFailure != nil {
                PutioNextPageFailedFooter(
                  message: String(localized: "Couldn’t load more results."),
                  retryIdentifier: "files.search-more-retry"
                ) {
                  Task { await model.loadMore() }
                }
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("files.search-more-error")
                .listRowInsets(
                  EdgeInsets(
                    top: 0, leading: PutioTheme.Spacing.space1, bottom: 0,
                    trailing: PutioTheme.Spacing.space1)
                )
                .listRowSeparator(.hidden)
                .selectionDisabled()
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
        .refreshable { await refresh() }
      }
    }
  }

  private func noResultsMessage(_ query: String) -> AttributedString {
    let mark = "\u{FFFC}"
    let template = String(localized: "No files or folders named \(mark). Try fewer words.")
    let parts = template.components(separatedBy: mark)
    var term = AttributedString(PutioFileSearchModel.shownTerm(query))
    term.font = Self.termFont
    term.foregroundColor = PutioTheme.Colors.textPrimary
    var message = AttributedString(parts.first ?? "")
    message.append(term)
    message.append(AttributedString(parts.dropFirst().joined(separator: mark)))
    return message
  }

  private static let termFont = Font.custom(
    PutioTheme.Typography.subheading.fontName, size: PutioTheme.Typography.body.size,
    relativeTo: .body)

  private func refresh() async {
    await model.refresh(query: query, filter: filter, revision: refreshRequests.revision)
  }

  @ViewBuilder
  private func group(_ title: String, id: String, items: [PutioFileItem]) -> some View {
    if !items.isEmpty {
      HStack(alignment: .firstTextBaseline) {
        Text(title)
          .putioFont(PutioTheme.Typography.caption)
          .accessibilityAddTraits(.isHeader)
        Spacer(minLength: PutioTheme.Spacing.space2)
        Text(items.count, format: .number)
          .putioFont(PutioTheme.Typography.numeric)
      }
      .foregroundStyle(PutioTheme.Colors.textSecondary)
      .accessibilityElement(children: .combine)
      .accessibilityIdentifier("files.search-group.\(id)")
      .listRowInsets(
        EdgeInsets(
          top: PutioTheme.Spacing.space3, leading: PutioTheme.Spacing.space4,
          bottom: 0, trailing: PutioTheme.Spacing.space4)
      )
      .listRowSeparator(.hidden)
      .listRowBackground(PutioTheme.Colors.background)
      ForEach(items) { item in
        resultRow(item)
      }
    }
  }

  private func rowModel(_ item: PutioFileItem) -> PutioFileRowModel {
    let location = folderNames.names[item.parentID].map(PutioPinnedCopy.location)
    let isFolder = item.kind == .folder
    return PutioFileRowModel(
      name: item.name,
      kind: PutioBrowserItemPresentation.rowKind(for: item.kind),
      locationText: location,
      sizeText: isFolder ? nil : PutioFileRowModel.sizeText(bytes: item.sizeBytes, locale: locale),
      dateText: isFolder
        ? PutioBrowserItemPresentation.relativeDateText(for: item.updatedAt, locale: locale) : nil,
      isWatched: item.isWatched)
  }

  @ViewBuilder
  private func resultRow(_ item: PutioFileItem) -> some View {
    let presentation = PutioBrowserItemPresentation(item: item)
    let row = Group {
      if let route = presentation.folderRoute {
        NavigationLink(value: route) { PutioFileRow(rowModel(item)) }
      } else if let route = presentation.fileRoute {
        Button {
          onFileSelected(route)
        } label: {
          PutioFileRow(rowModel(item))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
      }
    }
    .accessibilityIdentifier("files.search-item.\(item.id.rawValue)")
    .frame(maxWidth: .infinity, alignment: .leading)
    .listRowBackground(PutioTheme.Colors.background)
    .background {
      if let file = share.presented(for: item.id) {
        PutioShareSheetAnchor(file: file, name: item.name, model: share)
      }
    }
    .onDisappear { share.leave(item.id) }
    let menu = PutioFileMenu.searchResult(
      item: item,
      capabilities: .init(
        canEdit: true,
        canDownload: onDownload != nil,
        vlcInstalled: onExternalPlayback != nil,
        tracksWatched: tracksWatched,
        canShare: fileShare != nil,
        pinned: pins.isPinned(item.id)),
      isDownloaded: PutioFileShareSource.dependsOnDownload(item)
        && fileShare.map { share.isDownloaded(item, using: $0) } ?? false)
    if menu.sections.isEmpty {
      row
    } else {
      let actions = Dictionary(
        uniqueKeysWithValues: menu.sections.joined().compactMap { menuRow in
          menuAction(menuRow, for: item).map { (menuRow, $0) }
        })
      row.putioItemActions(
        PutioItemMenu(menu.sections.map { $0.compactMap { actions[$0] } }),
        leading: menu.leadingSwipe.compactMap { actions[$0] },
        trailing: menu.trailingSwipe.compactMap { actions[$0] })
    }
  }

  private func menuAction(_ row: PutioFileMenuRow, for item: PutioFileItem) -> PutioItemAction? {
    let route = PutioFileRoute(item: item)
    let editingBlocked = !itemActions.canStartAction || itemAction != nil
    switch row {
    case .play:
      return PutioItemAction(id: "play", title: String(localized: "Play"), icon: .play) {
        onFileSelected(route)
      }
    case .download:
      return PutioItemAction(
        id: "download", title: String(localized: "Download"), icon: .arrowCircleDown
      ) { onDownload?(route) }
    case .downloadWithDirectPlay:
      return PutioItemAction(
        id: "download-direct", title: String(localized: "Download with Direct play"),
        icon: .downloadSimple
      ) { onDownload?(route) }
    case .openInVLC:
      return PutioItemAction(
        id: "open-in-vlc", title: String(localized: "Open in VLC"), icon: .trafficCone
      ) { onExternalPlayback?(route) }
    case .share:
      return PutioItemAction(id: "share", title: String(localized: "Share"), icon: .export) {
        startShare(item)
      }
    case .pin:
      let location = folderNames.names[item.parentID]
      return PutioItemAction(id: "pin", title: String(localized: "Pin"), icon: .pushPin) {
        Task {
          await pins.pin(item, in: location)
          showPinFailure()
        }
      }
    case .unpin:
      return PutioItemAction(id: "unpin", title: String(localized: "Unpin"), icon: .pushPinSlash) {
        Task {
          await pins.unpin(item)
          showPinFailure()
        }
      }
    case .markWatched, .markUnwatched:
      let watched = row == .markWatched
      return PutioItemAction(
        id: watched ? "watched" : "unwatched",
        title: watched
          ? String(localized: "Mark as watched") : String(localized: "Mark as unwatched"),
        icon: watched ? .eye : .eyeSlash,
        isDisabled: editingBlocked
      ) { itemAction = .setWatched(item, watched) }
    case .move:
      return PutioItemAction(
        id: "move", title: String(localized: "Move"), icon: .folderSimpleDashed,
        isDisabled: editingBlocked
      ) { itemAction = .move(item) }
    case .select, .rename, .exclusiveLink, .trash, .makeCopy:
      return nil
    }
  }

  private func showPinFailure() {
    guard pins.editFailure != nil else { return }
    pins.clearEditFailure()
    toast = PutioToast(PutioScreenErrorKind.failed.message)
  }

  private func startShare(_ item: PutioFileItem) {
    guard let fileShare else { return }
    let fetching = share.share(item, using: fileShare) { failure in
      switch failure {
      case .retryable:
        toast = PutioToast(
          PutioScreenErrorKind.failed.title,
          action: PutioToast.Action(String(localized: "Try again")) { startShare(item) })
      case .final:
        toast = PutioToast(PutioScreenErrorKind.failed.title)
      }
    }
    guard fetching else { return }
    let preparing = PutioToast(
      String(localized: "Preparing…"),
      action: PutioToast.Action(String(localized: "Cancel")) { share.cancel() },
      staysUntilDismissed: true)
    toast = preparing
    preparingToast = preparing.id
  }

  private struct Request: Equatable {
    let query: String
    let filter: PutioFileSearchFilter
    let revision: UInt64
  }

  private struct NamesRequest: Equatable {
    let ids: [PutioFileID]
    let revision: UInt64
  }

  private struct PageRequest: Equatable {
    let cursor: String
    let generation: UInt64
    let isSearching: Bool
    let epoch: UInt64
  }
}
