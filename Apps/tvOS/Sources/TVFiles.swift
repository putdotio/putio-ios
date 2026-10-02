import PutioCore
import SwiftUI

/// What a long press on a file row offers, as in the shipped TV app.
enum TVFileMenuAction: Hashable {
  case markWatched
  case markUnwatched
  case delete
}

enum TVFilePresentation {
  /// Watch status needs remember-position on and a video; Trash or Delete
  /// waits for the account's trash setting to be known.
  static func menuActions(
    for item: PutioFileItem, account: PutioAccountSnapshot, canDelete: Bool
  ) -> [TVFileMenuAction] {
    var actions: [TVFileMenuAction] = []
    if account.rememberVideoTime, item.kind == .video {
      actions.append(item.isWatched ? .markUnwatched : .markWatched)
    }
    if canDelete { actions.append(.delete) }
    return actions
  }

  /// The shipped sort menu: the current key's other direction, and every
  /// other key in the current direction.
  static func sortChoices(from current: PutioFolderSort) -> [PutioFolderSort] {
    PutioFolderSortKey.allCases.map { key in
      key.sort(ascending: key == current.key ? !current.isAscending : current.isAscending)
    }
  }

  /// A folder without its own sort follows the account default.
  static func effectiveSort(
    _ folderSort: PutioFolderSort?, account: PutioAccountSnapshot
  ) -> PutioFolderSort {
    folderSort ?? account.defaultSort ?? .nameAscending
  }

  static func sortButtonTitle(_ sort: PutioFolderSort) -> String {
    "\(sort.key.title) \(sort.isAscending ? "↑" : "↓")"
  }

  /// Sorting shows in the header; every other outcome is a toast.
  static func toast(for outcome: PutioFileActionOutcome, trashEnabled: Bool) -> PutioToast? {
    let deletion = PutioFileDeletionPresentation(trashEnabled: trashEnabled)
    switch outcome {
    case .succeeded(.setWatched(_, _, let name, let watched)):
      return PutioToast(
        variant: .success, title: watched ? "Marked as watched" : "Marked as unwatched",
        message: name)
    case .succeeded(.delete(_, let name)):
      return PutioToast(variant: .success, title: deletion.singleSuccessTitle, message: name)
    case .succeeded:
      return nil
    case .failed(.delete, let failure):
      return PutioToast(
        variant: .danger, title: deletion.singleFailureTitle, message: failure.message)
    case .failed(_, let failure):
      return PutioToast(variant: .danger, title: failure.title, message: failure.message)
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
  let open: () -> Void
  let showMenu: () -> Void

  var body: some View {
    Button(action: open) {
      PutioFileRow(presentation.row)
    }
    // A recognized long press cancels the select, so the row does not open.
    .onLongPressGesture(minimumDuration: 0.5, perform: showMenu)
    .accessibilityIdentifier(identifier)
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
    let deletion = PutioFileDeletionPresentation(trashEnabled: account.trashEnabled)
    content
      .alert(
        item?.name ?? "",
        isPresented: Binding(get: { item != nil }, set: { if !$0 { item = nil } }),
        presenting: item
      ) { item in
        let actions = TVFilePresentation.menuActions(
          for: item, account: account, canDelete: canDelete)
        if actions.contains(.markWatched) {
          Button("Mark as watched") { setWatched(item, true) }
            .accessibilityIdentifier("files.menu.watched")
        }
        if actions.contains(.markUnwatched) {
          Button("Mark as unwatched") { setWatched(item, false) }
            .accessibilityIdentifier("files.menu.unwatched")
        }
        if actions.contains(.delete) {
          Button(deletion.actionTitle, role: .destructive) {
            if account.trashEnabled { delete(item) } else { confirmingDelete = item }
          }
          .accessibilityIdentifier("files.menu.delete")
        }
        Button("Cancel", role: .cancel) {}
      }
      .alert(
        confirmingDelete.map { deletion.confirmationTitle(itemName: $0.name) } ?? "",
        isPresented: Binding(
          get: { confirmingDelete != nil }, set: { if !$0 { confirmingDelete = nil } }),
        presenting: confirmingDelete
      ) { item in
        Button(deletion.actionTitle, role: .destructive) { delete(item) }
          .accessibilityIdentifier("files.delete-confirm")
        Button("Cancel", role: .cancel) {}
      } message: { _ in
        Text(deletion.confirmationMessage(itemCount: 1))
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

  /// Shows a toast and lets it go after three seconds.
  func tvToast(_ toast: Binding<PutioToast?>) -> some View {
    putioToast(toast)
      .task(id: toast.wrappedValue) {
        guard let presented = toast.wrappedValue else { return }
        try? await Task.sleep(for: .seconds(3))
        guard !Task.isCancelled, toast.wrappedValue == presented else { return }
        toast.wrappedValue = nil
      }
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
        load: { try await runtime.listFiles(parentID: $0) },
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
          PutioButton(TVFilePresentation.sortButtonTitle(sort), tier: .secondary) {
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
        Button(choice.title) { Task { await model.setSort(choice) } }
          .accessibilityIdentifier("files.sort.\(choice.rawValue)")
      }
      Button("Cancel", role: .cancel) {}
    } message: {
      Text("Sorted by \(sort.title.lowercased()).")
    }
    .tvFileMenu(
      item: $menuItem, account: account, canDelete: model.canDelete,
      setWatched: { item, watched in Task { await model.setWatched(item, watched) } },
      delete: { item in Task { await model.delete(item) } }
    )
    .tvToast($toast)
    .task(id: route.id) {
      guard loadsOnAppear else { return }
      refreshRegistration.activate()
      let pending = refreshRequests.sequence(for: route.id, owner: refreshRegistration.owner)
      // A fresh initial load already reflects any request that predates it.
      let loaded = await model.loadIfNeeded()
      guard loaded, let pending, !Task.isCancelled else { return }
      refreshRequests.markConsumed(pending, for: route.id, owner: refreshRegistration.owner)
    }
    // Keyed on the loaded flag too, so a request that arrived while the
    // initial load was in flight runs once the folder is loaded.
    .task(
      id: PendingRefresh(
        sequence: refreshRequests.sequence(for: route.id, owner: refreshRegistration.owner),
        loaded: model.isLoaded)
    ) {
      guard loadsOnAppear, model.isLoaded,
        let sequence = refreshRequests.sequence(for: route.id, owner: refreshRegistration.owner)
      else { return }
      let refreshed = await model.refreshWhenIdle()
      guard refreshed, !Task.isCancelled else { return }
      refreshRequests.markConsumed(sequence, for: route.id, owner: refreshRegistration.owner)
    }
    .onAppear {
      // Returning from a pushed screen refetches, as the shipped app does.
      if hasAppeared, loadsOnAppear { Task { await refresh() } }
      hasAppeared = true
      if loadsOnAppear { now = .now }
    }
    .onChange(of: model.actionOutcome) { _, outcome in
      guard let outcome else { return }
      notifyOtherScreens(after: outcome)
      toast = TVFilePresentation.toast(for: outcome, trashEnabled: account.trashEnabled)
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
        Task { await model.retry() }
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
          open: { open(item) },
          showMenu: { if model.canStartAction { menuItem = item } }
        )
      }
      if contents.nextCursor != nil {
        if let failure = model.loadMoreFailure {
          TVRetrySection(
            message: "\(failure.title). \(failure.message)", identifier: "files.more-retry"
          ) {
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

  private func refresh() async {
    let pending = refreshRequests.sequence(for: route.id, owner: refreshRegistration.owner)
    let refreshed = await model.refresh()
    guard refreshed, let pending, !Task.isCancelled else { return }
    refreshRequests.markConsumed(pending, for: route.id, owner: refreshRegistration.owner)
  }

  /// A failed mutation may still have reached the server, so other mounted
  /// screens, Search included, refresh after either outcome.
  private func notifyOtherScreens(after outcome: PutioFileActionOutcome) {
    let action =
      switch outcome {
      case .succeeded(let action), .failed(let action, _): action
      }
    switch action {
    case .delete:
      // A deleted folder can contain any other mounted folder.
      refreshRequests.requestAllLoadedFolders(excludingOwner: refreshRegistration.owner)
    case .sort:
      break
    default:
      refreshRequests.request(folderID: route.id, excludingOwner: refreshRegistration.owner)
    }
  }

  private struct PendingRefresh: Equatable {
    let sequence: PutioFolderRefreshRequests.Sequence?
    let loaded: Bool
  }
}

/// Where a non-folder file leads. Apple TV plays video only; playback itself
/// arrives with the player, so a video stops at a marked hand-off point.
struct TVFileScreen: View {
  let item: PutioFileItem

  @Environment(\.dismiss) private var dismiss

  var body: some View {
    VStack(alignment: .leading, spacing: PutioTheme.TV.Spacing.medium) {
      TVScreenHeader(title: item.name) {}
      destination
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    .tvOverscanPadding()
    .background(PutioTheme.Colors.background.ignoresSafeArea())
  }

  @ViewBuilder
  private var destination: some View {
    switch PutioFileRoute(item: item).openAction {
    case .video:
      // Hand-off point for the tvOS player.
      PutioEmptyStateView(
        icon: .fileVideo, title: "Playback is not available yet",
        message: "Video playback on Apple TV arrives in a later build.",
        actionTitle: "Go back", action: { dismiss() }
      )
      .accessibilityIdentifier("file.playback-placeholder")
    case .audio, .preview, .unsupported:
      PutioEmptyStateView(
        icon: .xCircle, title: "Unsupported file type",
        message: "We currently only support video files in this app (for now).",
        actionTitle: "Go back", action: { dismiss() }
      )
      .accessibilityIdentifier("file.unsupported")
    }
  }
}
