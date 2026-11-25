import PutioCore
import SwiftUI

enum TVFilePresentation {
  /// The rows a long press performs today, from the shared menu with the
  /// Apple TV preset. Trash waits for the account's trash setting.
  static func menuActions(
    for item: PutioFileItem, account: PutioAccountSnapshot, canDelete: Bool
  ) -> [PutioFileMenuRow] {
    let menu = PutioFileMenu(
      item: item, capabilities: .tv(tracksWatched: account.rememberVideoTime, pinned: nil))
    return menu.sections.joined().filter { row in
      switch row {
      case .markWatched, .markUnwatched: true
      case .trash: canDelete
      default: false
      }
    }
  }

  /// A folder without its own sort follows the account default.
  static func effectiveSort(
    _ folderSort: PutioFolderSort?, account: PutioAccountSnapshot
  ) -> PutioFolderSort {
    folderSort ?? account.defaultSort ?? .nameAscending
  }

  /// Sort by, then Order, then Videos, as on iOS. The current sort is not
  /// offered again.
  static func sortChoices(from current: PutioFolderSort) -> [PutioFolderSort] {
    let choices = PutioFolderSortChoices(current: current)
    let all =
      PutioFolderSortChoices.fields.map(choices.selecting) + choices.orders
      + PutioFolderSortChoices.videoOrders
    return all.reduce(into: []) { result, sort in
      if sort != current, !result.contains(sort) { result.append(sort) }
    }
  }
}

extension TVRoute {
  /// Folders open the browser; any other file opens its own screen.
  static func opening(_ item: PutioFileItem) -> TVRoute {
    item.kind == .folder ? .folder(PutioFolderRoute(id: item.id, title: item.name)) : .file(item)
  }
}

/// A focusable file row: select opens it, a long press asks for its menu.
struct TVFileRowButton: View {
  let presentation: PutioBrowserItemPresentation
  let identifier: String
  /// Whether this row's menu is up.
  let isMenuOpen: Bool
  let open: () -> Void
  let showMenu: () -> Void

  @State private var endsLongPress = false

  var body: some View {
    Button {
      // tvOS still delivers the select that ends a long press, however long
      // it was held; that one belongs to the menu, not to opening the row.
      if endsLongPress || isMenuOpen {
        endsLongPress = false
        return
      }
      open()
    } label: {
      PutioFileRow(presentation.row)
    }
    // A plain long-press modifier never sees the press a tvOS button owns.
    .simultaneousGesture(
      LongPressGesture(minimumDuration: 0.5).onEnded { _ in
        endsLongPress = true
        showMenu()
      }
    )
    // Answering the menu takes another press, so the long one has ended by
    // the time it closes, whether or not its select reached the row.
    .onChange(of: isMenuOpen) { _, isOpen in
      if !isOpen { endsLongPress = false }
    }
    .tvRowOpen(isMenuOpen)
    .accessibilityIdentifier(identifier)
  }
}

/// Moves focus to a row once the menu that removed its neighbour has let
/// go of focus. A focus change made while the alert is up is dropped, and
/// tvOS then puts focus on the first row, so the move waits for the next
/// focus change, or one second.
struct TVFocusHandoff: ViewModifier {
  @Binding var target: PutioFileID?
  var focusedRow: FocusState<PutioFileID?>.Binding

  func body(content: Content) -> some View {
    content
      .onChange(of: focusedRow.wrappedValue) { _, row in
        if row != nil { apply() }
      }
      .task(id: target) {
        guard target != nil else { return }
        try? await Task.sleep(for: .seconds(1))
        if !Task.isCancelled { apply() }
      }
  }

  private func apply() {
    guard let row = target else { return }
    target = nil
    focusedRow.wrappedValue = row
  }
}

/// The long-press menu and the permanent-delete confirmation, both centered
/// alerts. Trash moves are recoverable and run without a confirmation.
struct TVFileMenuModifier: ViewModifier {
  @Binding var item: PutioFileItem?
  let account: PutioAccountSnapshot
  let canDelete: Bool
  let setWatched: (PutioFileItem, Bool) -> Void
  let delete: (PutioFileItem) -> Void

  @State private var confirmingDelete: PutioFileItem?

  func body(content: Content) -> some View {
    let confirmation = confirmingDelete.map { item in
      PutioFileDeletionPresentation.permanentDeleteAlert(itemCount: 1) { delete(item) }
    }
    content
      .alert(
        item?.name ?? "",
        isPresented: Binding(get: { item != nil }, set: { if !$0 { item = nil } }),
        presenting: item
      ) { item in
        let actions = TVFilePresentation.menuActions(
          for: item, account: account, canDelete: canDelete)
        ForEach(actions, id: \.self) { row in
          let title = row.title(for: item, trashEnabled: account.trashEnabled) ?? ""
          switch PutioFileItemActionRequest(row: row, item: item)?.step(
            trashEnabled: account.trashEnabled)
          {
          case .setWatched(_, let watched):
            Button(title) { setWatched(item, watched) }
              .accessibilityIdentifier(watched ? "files.menu.watched" : "files.menu.unwatched")
          case .trash:
            Button(title, role: .destructive) { delete(item) }
              .accessibilityIdentifier("files.menu.delete")
          case .confirmPermanentDelete:
            Button(title, role: .destructive) { confirmingDelete = item }
              .accessibilityIdentifier("files.menu.delete")
          case .askForName, .pickDestination, nil:
            EmptyView()
          }
        }
        Button("Cancel", role: .cancel) {}
      }
      .alert(
        confirmation?.title ?? "",
        isPresented: Binding(
          get: { confirmingDelete != nil }, set: { if !$0 { confirmingDelete = nil } }),
        presenting: confirmingDelete
      ) { item in
        Button(confirmation?.confirmTitle ?? "", role: .destructive) { delete(item) }
          .accessibilityIdentifier("files.delete-confirm")
        Button("Cancel", role: .cancel) {}
          .accessibilityIdentifier("files.delete-cancel")
      } message: { _ in
        Text(confirmation?.message ?? "")
      }
  }
}

extension View {
  func tvFileMenu(
    item: Binding<PutioFileItem?>, account: PutioAccountSnapshot, canDelete: Bool,
    setWatched: @escaping (PutioFileItem, Bool) -> Void,
    delete: @escaping (PutioFileItem) -> Void
  ) -> some View {
    modifier(
      TVFileMenuModifier(
        item: item, account: account, canDelete: canDelete, setWatched: setWatched,
        delete: delete))
  }
}

/// One folder of Your Files. Browse, sort, paging, and file actions come
/// from the shared folder model; this screen owns focus and remote input.
struct TVFolderView: View {
  let route: PutioFolderRoute
  let account: PutioAccountSnapshot
  let refreshRequests: PutioFolderRefreshRequests
  let open: (PutioFileItem) -> Void

  @State private var model: PutioFolderModel
  @State private var refreshRegistration: PutioFolderRefreshRegistration
  @State private var menuItem: PutioFileItem?
  @FocusState private var focusedRow: PutioFileID?
  @State private var focusTarget: PutioFileID?
  @State private var choosesSort = false
  @State private var toast: PutioToast?
  @State private var hasAppeared = false
  @State private var now: Date
  private let locale: Locale
  private let loadsOnAppear: Bool

  init(
    route: PutioFolderRoute, runtime: PutioRuntime, account: PutioAccountSnapshot,
    refreshRequests: PutioFolderRefreshRequests, open: @escaping (PutioFileItem) -> Void
  ) {
    self.init(
      route: route,
      model: PutioFolderModel(
        folderID: route.id,
        load: { try await runtime.listFiles(parentID: $0, perPage: PutioRuntime.folderPageSize) },
        continueLoad: { try await runtime.continueFiles(cursor: $0) },
        actions: PutioFileActions(runtime: runtime)),
      account: account, refreshRequests: refreshRequests, open: open)
  }

  /// `loadsOnAppear: false` keeps an already loaded model as it is, for
  /// rendering a fixed state.
  init(
    route: PutioFolderRoute, model: PutioFolderModel, account: PutioAccountSnapshot,
    refreshRequests: PutioFolderRefreshRequests = PutioFolderRefreshRequests(),
    now: Date = .now, locale: Locale = .current, loadsOnAppear: Bool = true,
    open: @escaping (PutioFileItem) -> Void
  ) {
    self.route = route
    self.account = account
    self.refreshRequests = refreshRequests
    self.open = open
    self.locale = locale
    self.loadsOnAppear = loadsOnAppear
    _model = State(initialValue: model)
    _refreshRegistration = State(
      initialValue: PutioFolderRefreshRegistration(folderID: route.id, requests: refreshRequests))
    _now = State(initialValue: now)
  }

  private var title: String {
    if route.id == .root { return "Your Files" }
    if case .loaded(let contents) = model.state, let folder = contents.folder,
      folder.id == route.id
    {
      return folder.name
    }
    return route.title
  }

  private var sort: PutioFolderSort {
    TVFilePresentation.effectiveSort(model.sort, account: account)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: PutioTheme.TV.Spacing.medium) {
      TVScreenHeader(title: title) {
        if model.isLoaded {
          PutioButton("Refresh", tier: .secondary) {
            Task { await refresh() }
          }
          .accessibilityIdentifier("files.refresh")
          PutioButton(sort.menuLabel, tier: .secondary) {
            if model.canStartAction { choosesSort = true }
          }
          .accessibilityLabel("Sort by \(sort.title)")
          .accessibilityIdentifier("files.sort")
        }
      }
      content
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    .tvOverscanPadding()
    .background(PutioTheme.Colors.background.ignoresSafeArea())
    .alert("Sort by", isPresented: $choosesSort) {
      ForEach(TVFilePresentation.sortChoices(from: sort), id: \.self) { choice in
        Button(choice.menuLabel) { Task { await model.setSort(choice) } }
          .accessibilityIdentifier("files.sort.\(choice.rawValue)")
      }
      Button("Cancel", role: .cancel) {}
    } message: {
      Text("Sorted by \(sort.menuLabel.lowercased()).")
    }
    .tvFileMenu(
      item: $menuItem, account: account, canDelete: model.canDelete,
      setWatched: { item, watched in
        if case .loaded(let contents) = model.state {
          focusTarget = PutioFolderContents.neighbour(
            keeping: item.id, in: contents.items, firstPage: model.firstPageIDs)
        }
        mutate(.folder(route.id)) { [model] in await model.setWatched(item, watched) }
      },
      delete: { item in
        guard case .loaded(let contents) = model.state else { return }
        focusTarget = PutioFolderContents.neighbour(
          afterRemoving: item.id, from: contents.items, firstPage: model.firstPageIDs)
        mutate(.allFolders) { [model] in await model.delete(item) }
      }
    )
    .modifier(TVFocusHandoff(target: $focusTarget, focusedRow: $focusedRow))
    .putioToast($toast)
    .task(id: route.id) {
      guard loadsOnAppear else { return }
      await refreshRegistration.loadIfNeeded(model)
    }
    .task(id: isOffline) {
      guard loadsOnAppear else { return }
      await PutioOfflineRetry().run(while: isOffline) {
        await refreshRegistration.retryKeepingFailure(model)
      }
    }
    // Keyed on the loaded flag too, so a request that arrived while the
    // initial load was in flight runs once the folder is loaded.
    .task(
      id: PendingRefresh(sequence: refreshRegistration.pendingSequence, loaded: model.isLoaded)
    ) {
      guard loadsOnAppear else { return }
      await refreshRegistration.refreshPending(model)
    }
    .onAppear {
      // Returning from a pushed screen refetches, as the shipped app does.
      if hasAppeared, loadsOnAppear { Task { await refresh() } }
      hasAppeared = true
      if loadsOnAppear { now = .now }
    }
    .onChange(of: model.actionOutcome) { _, outcome in
      guard let outcome else { return }
      toast = outcome.toastTitle(trashEnabled: account.trashEnabled).map { PutioToast($0) }
      model.clearActionOutcome()
    }
  }

  @ViewBuilder
  private var content: some View {
    switch model.state {
    case .loading:
      PutioLoadingStateView(title: "Loading files")
    case .failed(let failure):
      PutioErrorStateView(
        title: failure.title, message: failure.message, retryTitle: "Try again",
        retryIdentifier: "files.retry"
      ) {
        Task { await refreshRegistration.retry(model) }
      }
    case .loaded(let contents):
      if contents.items.isEmpty, contents.nextCursor == nil, model.refreshFailure == nil {
        PutioEmptyStateView(
          icon: .folderFill, title: "No files whatsoever!",
          message: "It looks like this folder is empty."
        )
        .accessibilityIdentifier("files.empty")
      } else {
        list(contents)
      }
    }
  }

  private func list(_ contents: PutioFolderContents) -> some View {
    TVRowList {
      if let failure = model.refreshFailure {
        TVRetrySection(
          message: "\(failure.title). \(failure.message)", identifier: "files.refresh-retry"
        ) {
          await refresh()
        }
      }
      ForEach(contents.items) { item in
        TVFileRowButton(
          presentation: PutioBrowserItemPresentation(
            item: item, relativeTo: now, locale: locale, sort: sort),
          identifier: "files.item.\(item.id.rawValue)",
          isMenuOpen: menuItem?.id == item.id,
          open: { open(item) },
          showMenu: {
            let actions = TVFilePresentation.menuActions(
              for: item, account: account, canDelete: model.canDelete)
            if model.canStartAction, !actions.isEmpty { menuItem = item }
          }
        )
        .focused($focusedRow, equals: item.id)
      }
      if contents.nextCursor != nil {
        if let failure = model.loadMoreFailure {
          TVRetrySection(
            message: "\(failure.title). \(failure.message)", identifier: "files.more-retry"
          ) {
            // The retry row goes away as the page loads; without a target,
            // focus would jump back to the top of the folder.
            focusedRow = contents.items.last?.id
            await model.loadMore()
          }
        } else {
          ProgressView("Loading more")
            .frame(maxWidth: .infinity)
            .accessibilityIdentifier("files.load-more")
            .task(id: model.continuationKey) { await model.loadMore() }
        }
      }
    }
  }

  private var isOffline: Bool {
    if case .failed(let failure) = model.state { return failure.isOffline }
    return false
  }

  private func refresh() async {
    await refreshRegistration.refresh(model)
  }

  private func mutate(
    _ scope: PutioFolderMutationScope, _ operation: @escaping @MainActor () async -> Bool
  ) {
    let registration = refreshRegistration
    Task { await registration.mutate(scope, operation: operation) }
  }

  private struct PendingRefresh: Equatable {
    let sequence: PutioFolderRefreshRequests.Sequence?
    let loaded: Bool
  }
}

/// A file Apple TV cannot open: it plays video only, and videos open the
/// player instead.
struct TVFileScreen: View {
  let item: PutioFileItem

  @Environment(\.dismiss) private var dismiss

  var body: some View {
    VStack(alignment: .leading, spacing: PutioTheme.TV.Spacing.medium) {
      TVScreenHeader(title: item.name) {}
      PutioEmptyStateView(
        icon: .xCircle, title: "Unsupported file type",
        message: "We currently only support video files in this app (for now).",
        actionTitle: "Go back", action: { dismiss() }
      )
      .accessibilityIdentifier("file.unsupported")
      .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    .tvOverscanPadding()
    .background(PutioTheme.Colors.background.ignoresSafeArea())
  }
}
