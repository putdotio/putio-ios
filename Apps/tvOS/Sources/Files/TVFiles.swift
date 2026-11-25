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

/// One folder of Your Files: the list on the leading side and the focused
/// row's actions in a panel beside it. Browse, sort, paging, and file
/// actions come from the shared folder model; this screen owns focus and
/// remote input.
struct TVFolderView: View {
  let route: PutioFolderRoute
  let account: PutioAccountSnapshot
  let refreshRequests: PutioFolderRefreshRequests
  let open: (PutioFileItem) -> Void
  let play: ((PutioFileItem, PutioVideoResumePrompt.Choice) -> Void)?

  @State private var model: PutioFolderModel
  @State private var refreshRegistration: PutioFolderRefreshRegistration
  @State private var pins: PutioPinnedFilesModel?
  @FocusState private var focusedRow: PutioFileID?
  @FocusState private var focusesMoreRetry: Bool?
  @State private var focusTarget: PutioFileID?
  @State private var shownItemID: PutioFileID?
  @State private var showsPanel = true
  @State private var confirmingDelete: PutioFileItem?
  @State private var renaming: PutioFileItem?
  @State private var proposedName = ""
  @State private var toast: PutioToast?
  @State private var hasAppeared = false
  @State private var now: Date
  private let locale: Locale
  private let loadsOnAppear: Bool

  init(
    route: PutioFolderRoute, runtime: PutioRuntime, account: PutioAccountSnapshot,
    refreshRequests: PutioFolderRefreshRequests, open: @escaping (PutioFileItem) -> Void,
    play: ((PutioFileItem, PutioVideoResumePrompt.Choice) -> Void)? = nil
  ) {
    self.init(
      route: route,
      model: PutioFolderModel(
        folderID: route.id,
        load: { try await runtime.listFiles(parentID: $0, perPage: PutioRuntime.folderPageSize) },
        continueLoad: { try await runtime.continueFiles(cursor: $0) },
        actions: PutioFileActions(runtime: runtime)),
      pins: PutioPinnedFilesModel(
        actions: PutioPinnedFilesActions(runtime: runtime), rootName: TVFolderCopy.yourFiles),
      account: account, refreshRequests: refreshRequests, open: open, play: play)
  }

  /// `loadsOnAppear: false` keeps an already loaded model as it is, for
  /// rendering a fixed state.
  init(
    route: PutioFolderRoute, model: PutioFolderModel, pins: PutioPinnedFilesModel? = nil,
    account: PutioAccountSnapshot,
    refreshRequests: PutioFolderRefreshRequests = PutioFolderRefreshRequests(),
    now: Date = .now, locale: Locale = .current, loadsOnAppear: Bool = true,
    shownItemID: PutioFileID? = nil, open: @escaping (PutioFileItem) -> Void,
    play: ((PutioFileItem, PutioVideoResumePrompt.Choice) -> Void)? = nil
  ) {
    self.route = route
    self.account = account
    self.refreshRequests = refreshRequests
    self.open = open
    self.play = play
    self.locale = locale
    self.loadsOnAppear = loadsOnAppear
    _model = State(initialValue: model)
    _pins = State(initialValue: pins)
    _refreshRegistration = State(
      initialValue: PutioFolderRefreshRegistration(folderID: route.id, requests: refreshRequests))
    _now = State(initialValue: now)
    _shownItemID = State(initialValue: shownItemID)
  }

  private var title: String {
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
    content
      .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
      .tvOverscanPadding()
      .background(PutioTheme.Colors.background.ignoresSafeArea())
      .confirmationDialog(
        deleteConfirmation?.title ?? "",
        isPresented: Binding(
          get: { confirmingDelete != nil }, set: { if !$0 { confirmingDelete = nil } }),
        titleVisibility: .visible, presenting: confirmingDelete
      ) { item in
        Button(deleteConfirmation?.confirmTitle ?? "", role: .destructive) {
          delete(item, permanently: true)
        }
        .accessibilityIdentifier("files.delete-confirm")
        Button(String(localized: "Cancel", bundle: .putioCore), role: .cancel) {}
          .accessibilityIdentifier("files.delete-cancel")
      } message: { _ in
        Text(deleteConfirmation?.message ?? "")
      }
      .alert(
        String(localized: "Rename", bundle: .putioCore),
        isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } }),
        presenting: renaming
      ) { item in
        TextField(String(localized: "Name", bundle: .putioCore), text: $proposedName)
          .accessibilityIdentifier("files.rename-field")
        Button(String(localized: "Rename", bundle: .putioCore)) {
          let name = proposedName
          Task { await model.rename(item, to: name) }
        }
        .disabled(!PutioTextAlert.canSubmit(proposedName, replacing: item.name))
        .accessibilityIdentifier("files.rename-confirm")
        Button(String(localized: "Cancel", bundle: .putioCore), role: .cancel) {}
      }
      .modifier(TVFocusHandoff(target: $focusTarget, focusedRow: $focusedRow))
      .putioToast($toast)
      .task(id: route.id) {
        guard loadsOnAppear else { return }
        await refreshRegistration.loadIfNeeded(model)
      }
      .task {
        guard loadsOnAppear else { return }
        await pins?.load()
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
      .onChange(of: focusedRow) { _, row in
        guard let row else { return }
        shownItemID = row
        showsPanel = true
      }
      .onChange(of: focusesMoreRetry) { _, focused in
        if focused == true { showsPanel = false }
      }
      .onChange(of: model.actionOutcome) { _, outcome in
        guard let outcome else { return }
        toast = Self.toast(for: outcome, trashEnabled: account.trashEnabled)
        model.clearActionOutcome()
      }
      .onChange(of: pins?.editFailure) { _, failure in
        guard failure != nil else { return }
        toast = PutioToast(PutioScreenErrorKind.failed.message, icon: .warning, width: .fit)
        pins?.clearEditFailure()
      }
  }

  private var deleteConfirmation: PutioConfirmAlert? {
    confirmingDelete.map { _ in
      PutioFileDeletionPresentation.permanentDeleteAlert(itemCount: 1) {}
    }
  }

  static func toast(for outcome: PutioFileActionOutcome, trashEnabled: Bool) -> PutioToast? {
    guard let title = outcome.toastTitle(trashEnabled: trashEnabled) else { return nil }
    switch outcome {
    case .failed:
      return PutioToast(title, icon: .warning, width: .fit)
    case .succeeded(.delete):
      return PutioToast(title, icon: .symbol(.trash), width: .fit)
    case .succeeded(.setWatched(_, _, _, let watched)):
      return PutioToast(title, icon: .symbol(watched ? .eye : .eyeSlash), width: .fit)
    case .succeeded:
      return PutioToast(title, width: .fit)
    }
  }

  @ViewBuilder
  private var content: some View {
    switch model.state {
    case .loading:
      split(panel: nil) {
        header(nil, showsActions: true)
        PutioLoadingStateView(title: TVFolderCopy.loading, titleVisibility: .hidden)
          .frame(maxWidth: .infinity, maxHeight: .infinity)
      }
    case .failed:
      PutioErrorStateView(
        title: TVFolderCopy.loadFailed,
        message: String(
          localized: "Check your internet connection and try again.", bundle: .putioCore),
        retryTitle: String(localized: "Try again", bundle: .putioCore),
        retryIdentifier: "files.retry"
      ) {
        Task { await refreshRegistration.retry(model) }
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
    case .loaded(let contents):
      if contents.items.isEmpty, contents.nextCursor == nil, model.refreshFailure == nil {
        VStack(alignment: .leading, spacing: PutioTheme.TV.Spacing.medium) {
          header(contents, showsActions: false)
          PutioEmptyStateView(
            kaomoji: .emptyFolder, title: TVFolderCopy.emptyTitle,
            message: TVFolderCopy.emptyMessage
          )
          .accessibilityIdentifier("files.empty")
          .frame(maxWidth: .infinity, maxHeight: .infinity)
          .focusable()
          .focusEffectDisabled()
        }
      } else {
        split(panel: showsPanel ? shownItem(in: contents) : nil) {
          header(contents, showsActions: true)
          list(contents)
        }
      }
    }
  }

  private func split(
    panel item: PutioFileItem?, @ViewBuilder list: () -> some View
  ) -> some View {
    HStack(alignment: .top, spacing: PutioTheme.TV.Spacing.large) {
      VStack(alignment: .leading, spacing: PutioTheme.TV.Spacing.small) {
        list()
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
      if let item {
        panel(item)
      } else {
        Color.clear.frame(width: TVDetailPanelLayout.width)
      }
    }
  }

  private func shownItem(in contents: PutioFolderContents) -> PutioFileItem? {
    contents.items.first { $0.id == shownItemID } ?? contents.items.first
  }

  @ViewBuilder
  private func header(_ contents: PutioFolderContents?, showsActions: Bool) -> some View {
    VStack(alignment: .leading, spacing: PutioTheme.TV.Spacing.xxs) {
      if route.id == .root {
        HStack(spacing: PutioTheme.TV.Spacing.small) {
          caption(TVFolderCopy.yourFiles)
          Spacer(minLength: PutioTheme.TV.Spacing.medium)
          if showsActions { headerActions }
        }
        .focusSection()
      } else {
        caption(TVFolderCopy.yourFiles)
        Text(title)
          .putioFont(PutioTheme.TV.Typography.heading)
          .foregroundStyle(PutioTheme.TV.Colors.textPrimary)
          .lineLimit(1)
          .accessibilityAddTraits(.isHeader)
          .accessibilityIdentifier("files.title")
        if showsActions {
          HStack(spacing: PutioTheme.TV.Spacing.small) {
            summary(contents)
            Spacer(minLength: PutioTheme.TV.Spacing.medium)
            headerActions
          }
          .padding(.top, PutioTheme.TV.Spacing.small)
          .focusSection()
        }
      }
    }
  }

  private func caption(_ text: String) -> some View {
    Text(text)
      .putioFont(PutioTheme.TV.Typography.caption)
      .foregroundStyle(PutioTheme.TV.Colors.textSecondary)
  }

  /// "3 items · 276 MB" once the whole folder is listed; the size alone
  /// while more pages remain.
  @ViewBuilder
  private func summary(_ contents: PutioFolderContents?) -> some View {
    if let contents, let folder = contents.folder, folder.id == route.id {
      HStack(spacing: PutioTheme.TV.Spacing.xs) {
        if contents.nextCursor == nil {
          Text(PutioHomeCopy.itemCount(contents.items.count))
          Text(verbatim: "·").accessibilityHidden(true)
        }
        Text(PutioFileRowModel.sizeText(bytes: folder.sizeBytes, locale: locale))
          .putioFont(PutioTheme.TV.Typography.numeric)
      }
      .putioFont(PutioTheme.TV.Typography.caption)
      .foregroundStyle(PutioTheme.TV.Colors.textSecondary)
      .lineLimit(1)
      .accessibilityElement(children: .combine)
      .accessibilityIdentifier("files.summary")
    }
  }

  @ViewBuilder
  private var headerActions: some View {
    PutioButton(
      String(localized: "Refresh", bundle: .putioCore), icon: .arrowsClockwise, tier: .secondary
    ) {
      Task { await refresh() }
    }
    .fixedSize()
    .disabled(!model.isLoaded)
    .accessibilityIdentifier("files.refresh")
    TVDefaultSortMenu(current: sort, save: { choice in Task { await model.setSort(choice) } }) {
      HStack(spacing: PutioTheme.TV.Spacing.xs) {
        Image(putioIcon: .sortAscending)
          .resizable()
          .scaledToFit()
          .frame(
            width: PutioButtonSize.regular.brandLabel.size,
            height: PutioButtonSize.regular.brandLabel.size)
        Text(sort.menuLabel)
      }
      .putioFont(PutioButtonSize.regular.brandLabel)
    }
    .buttonStyle(.bordered)
    .fixedSize()
    .disabled(!model.isLoaded || !model.canStartAction)
    .accessibilityLabel(
      String(localized: "Sort, \(sort.menuLabel)", bundle: .putioCore)
    )
    .accessibilityIdentifier("files.sort")
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
        Button {
          activate(item)
        } label: {
          PutioFileRow(
            PutioBrowserItemPresentation(
              item: item, relativeTo: now, locale: locale, sort: sort
            ).row)
        }
        .tvRowOpen(!isRowFocused && showsPanel && shownItem(in: contents)?.id == item.id)
        .focused($focusedRow, equals: item.id)
        .disabled(!model.canStartAction)
        .accessibilityIdentifier("files.item.\(item.id.rawValue)")
      }
      if contents.nextCursor != nil {
        if model.loadMoreFailure != nil {
          TVLoadMoreFailedRow(
            message: TVFolderCopy.moreFailed, identifier: "files.more-retry",
            focus: $focusesMoreRetry, focusValue: true
          ) {
            // The retry row goes away as the page loads; without a target,
            // focus would jump back to the top of the folder.
            focusedRow = contents.items.last?.id
            await model.loadMore()
          }
        } else {
          ProgressView()
            .accessibilityLabel(TVFolderCopy.loadingMore)
            .frame(maxWidth: .infinity)
            .accessibilityIdentifier("files.load-more")
            .task(id: model.continuationKey) { await model.loadMore() }
        }
      }
    }
    .defaultFocus($focusedRow, contents.items.first?.id)
    .focusSection()
  }

  private var isRowFocused: Bool { focusedRow != nil }

  private func activate(_ item: PutioFileItem) {
    open(item)
  }

  private func play(_ item: PutioFileItem, _ choice: PutioVideoResumePrompt.Choice) {
    guard let play else { return open(item) }
    play(item, choice)
  }

  private var pinnedState: (PutioFileID) -> Bool? {
    guard let pins, case .loaded = pins.state else { return { _ in nil } }
    return { pins.isPinned($0) }
  }

  private func panelRows(for item: PutioFileItem) -> [[PutioFileMenuRow]] {
    let menu = PutioFileMenu(
      item: item,
      capabilities: .tv(
        tracksWatched: account.rememberVideoTime, pinned: pinnedState(item.id)))
    return menu.sections.map { section in
      section.filter { row in
        switch row {
        case .open, .play, .markWatched, .markUnwatched, .rename, .pin, .unpin: true
        case .startOver: play != nil
        case .trash: model.canDelete
        default: false
        }
      }
    }
    .filter { !$0.isEmpty }
  }

  private func panel(_ item: PutioFileItem) -> some View {
    let row = PutioBrowserItemPresentation(item: item, relativeTo: now, locale: locale, sort: sort)
      .row
    let sections = panelRows(for: item)
    return TVDetailPanel(icon: row.kind.icon, title: item.name, identifier: "files.panel") {
      HStack(spacing: PutioTheme.TV.Spacing.xs) {
        if let size = row.sizeText {
          Text(size)
            .putioFont(PutioTheme.TV.Typography.numeric)
          Text(verbatim: "·").accessibilityHidden(true)
        }
        Text(row.dateText ?? "")
      }
    } facts: {
      EmptyView()
    } actions: {
      ForEach(Array(sections.enumerated()), id: \.offset) { _, section in
        if section.contains(.trash) { TVDetailDivider() }
        ForEach(section, id: \.self) { menuRow in
          if let title = menuRow.title(
            for: item, style: .panel, trashEnabled: account.trashEnabled)
          {
            TVDetailAction(
              title: title, icon: menuRow.icon, isDestructive: menuRow.isDestructive
            ) {
              perform(menuRow, on: item)
            }
            .accessibilityIdentifier("files.panel.\(menuRow.rawValue)")
          }
        }
      }
    }
    .disabled(!model.canStartAction)
  }

  private func perform(_ row: PutioFileMenuRow, on item: PutioFileItem) {
    switch row {
    case .open:
      open(item)
    case .play:
      play(item, .resume)
    case .startOver:
      play(item, .startOver)
    case .pin:
      Task { await pins?.pin(item, in: route.id == .root ? nil : title) }
    case .unpin:
      Task { await pins?.unpin(item) }
    case .rename:
      proposedName = item.name
      renaming = item
    default:
      switch PutioFileItemActionRequest(row: row, item: item)?.step(
        trashEnabled: account.trashEnabled)
      {
      case .setWatched(_, let watched):
        setWatched(item, watched)
      case .trash:
        delete(item, permanently: false)
      case .confirmPermanentDelete:
        confirmingDelete = item
      case .askForName, .pickDestination, nil:
        break
      }
    }
  }

  private func setWatched(_ item: PutioFileItem, _ watched: Bool) {
    if case .loaded(let contents) = model.state {
      focusTarget = PutioFolderContents.neighbour(
        keeping: item.id, in: contents.items, firstPage: model.firstPageIDs)
    }
    mutate(.folder(route.id)) { [model] in await model.setWatched(item, watched) }
  }

  private func delete(_ item: PutioFileItem, permanently: Bool) {
    guard case .loaded(let contents) = model.state else { return }
    let next = PutioFolderContents.neighbour(
      afterRemoving: item.id, from: contents.items, firstPage: model.firstPageIDs)
    focusTarget = next
    shownItemID = next
    mutate(.allFolders) { [model] in await model.delete(item, permanently: permanently) }
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

enum TVFolderCopy {
  static var yourFiles: String { String(localized: "Your files", bundle: .putioCore) }
  static var loading: String { String(localized: "Loading files", bundle: .putioCore) }
  static var loadingMore: String { String(localized: "Loading more files", bundle: .putioCore) }
  static var loadFailed: String {
    String(localized: "Couldn’t load your files.", bundle: .putioCore)
  }
  static var moreFailed: String {
    String(localized: "Couldn’t load more files.", bundle: .putioCore)
  }
  static var emptyTitle: String { String(localized: "No files whatsoever!", bundle: .putioCore) }
  static var emptyMessage: String {
    String(localized: "Files you add to this folder on put.io show up here.", bundle: .putioCore)
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
