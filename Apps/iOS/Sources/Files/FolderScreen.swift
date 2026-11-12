import Foundation
import PutioCore
import SwiftUI

@MainActor
private struct PendingRefresh: Equatable {
  let sequence: PutioFolderRefreshRequests.Sequence?
  let loaded: Bool
}

struct PutioFolderScreen: View {
  let route: PutioFolderRoute

  @State private var model: PutioFolderModel
  @State private var retryRequest: RetryRequest?
  @State private var retrySequence: UInt64 = 0
  @State private var reportedLoaded = false
  @State private var nameAlert: PutioTextAlert?
  @State private var confirmAlert: PutioConfirmAlert?
  @State private var queuedUndo: PutioFileItem?
  @State private var pendingMove: MoveSelection?
  @State private var actionRequest: FileActionRequest?
  @State private var startedActionRequest: FileActionRequest?
  @State private var toast: PutioToast?
  @State private var selectedIDs: Set<PutioFileID> = []
  // Rows a Trash move hides in the tapping transaction, so a destructive
  // swipe closes over a removed row instead of a row that vanishes later.
  @State private var trashingIDs: Set<PutioFileID> = []
  @State private var editMode: EditMode = .inactive
  @State private var refreshRegistration: PutioFolderRefreshRegistration
  @State private var lastKnownFolderName: String?
  @Environment(\.putioDefaultFolderSort) private var defaultSort
  @Environment(\.putioPreviewOpen) private var previewOpen
  private let relativeDateReference: Date?
  private let locale: Locale
  private let load: PutioFolderLoad
  private let continueLoad: PutioFolderContinue?
  private let actions: PutioFileActions?
  private let trashEnabled: Bool
  private let tracksWatched: Bool
  private let onLoaded: @MainActor @Sendable () -> Void
  private let onFileSelected: PutioFileSelection
  private let onExternalPlayback: PutioFileSelection?
  private let onDownload: PutioFileSelection?
  private let castButton: AnyView?
  private let refreshRequests: PutioFolderRefreshRequests
  private let accountNotice: PutioInactiveAccountNotice?

  init(
    route: PutioFolderRoute,
    load: @escaping PutioFolderLoad,
    continueLoad: PutioFolderContinue? = nil,
    actions: PutioFileActions? = nil,
    trashEnabled: Bool = true,
    tracksWatched: Bool = false,
    initialContents: PutioFolderContents? = nil,
    relativeTo relativeDateReference: Date? = nil,
    locale: Locale = .current,
    onLoaded: @escaping @MainActor @Sendable () -> Void = {},
    refreshRequests: PutioFolderRefreshRequests = PutioFolderRefreshRequests(),
    onFileSelected: @escaping PutioFileSelection,
    onExternalPlayback: PutioFileSelection? = nil,
    onDownload: PutioFileSelection? = nil,
    castButton: AnyView? = nil,
    accountNotice: PutioInactiveAccountNotice? = nil
  ) {
    self.accountNotice = accountNotice
    self.castButton = castButton
    self.route = route
    _model = State(
      initialValue: PutioFolderModel(
        folderID: route.id,
        load: load,
        continueLoad: continueLoad,
        actions: actions,
        initialContents: initialContents
      )
    )
    _refreshRegistration = State(
      initialValue: PutioFolderRefreshRegistration(folderID: route.id, requests: refreshRequests))
    self.relativeDateReference = relativeDateReference
    self.locale = locale
    self.actions = actions
    self.load = load
    self.continueLoad = continueLoad
    self.trashEnabled = trashEnabled
    self.tracksWatched = tracksWatched
    self.onLoaded = onLoaded
    self.refreshRequests = refreshRequests
    self.onFileSelected = onFileSelected
    self.onExternalPlayback = onExternalPlayback
    self.onDownload = onDownload
  }

  private var folderTitle: String {
    guard route.id != .root else { return route.title }
    if case .loaded(let contents) = model.state,
      let folder = contents.folder, folder.id == route.id
    {
      return folder.name
    }
    return lastKnownFolderName ?? route.title
  }

  var body: some View {
    Group {
      switch model.state {
      case .loading:
        PutioLoadingStateView(title: String(localized: "Loading files"))
      case .loaded(let contents):
        loadedContent(contents)
      case .failed(let failure):
        PutioErrorStateView(
          title: failure.title,
          message: failure.message,
          retryTitle: String(localized: "Try again")
        ) {
          requestRetry(.load)
        }
      }
    }
    .navigationTitle(folderTitle)
    .navigationBarTitleDisplayMode(route.id == .root && !isEditing ? .large : .inline)
    .navigationBarBackButtonHidden(fileActionPending || isEditing)
    .putioContentBackground()
    .toolbar {
      if model.supportsActions, isEditing {
        ToolbarItem(placement: .topBarLeading) {
          Button(allLoadedItemsAreSelected ? "Deselect All" : "Select All") {
            toggleAllLoadedItems()
          }
          .disabled(fileActionPending || currentItems.isEmpty)
          .accessibilityIdentifier(
            allLoadedItemsAreSelected
              ? "files.selection.deselect-all" : "files.selection.select-all"
          )
        }
        ToolbarItem(placement: .principal) {
          Text("Select Items")
        }
        ToolbarItem(placement: .confirmationAction) {
          Button {
            editMode = .inactive
          } label: {
            Label("Done", systemImage: "checkmark")
          }
          .disabled(fileActionPending)
          .accessibilityLabel("Done")
          .accessibilityIdentifier("files.selection.toggle")
        }
        ToolbarItemGroup(placement: .bottomBar) {
          bulkMoveButton
          Spacer()
          bulkDeleteButton
          Spacer()
          Menu {
            bulkMoveButton
            bulkDeleteButton
          } label: {
            Label("More", systemImage: "ellipsis.circle")
          }
          .disabled(selectedItems.isEmpty || fileActionPending)
          .accessibilityIdentifier("files.selection.menu")
        }
      } else if model.supportsActions {
        ToolbarItemGroup(placement: .primaryAction) {
          if let castButton { castButton }
          PutioFolderSortMenu(
            current: model.sort ?? defaultSort,
            isDisabled: !model.canStartAction || actionRequest != nil
          ) { sort in
            actionRequest = .sort(sort)
          }
          browseMenu
        }
      } else if let castButton {
        ToolbarItem(placement: .primaryAction) { castButton }
      }
    }
    .modifier(PutioSelectionTabBarVisibility(isEditing: isEditing))
    .environment(\.editMode, $editMode)
    .putioTextAlert($nameAlert)
    .sheet(item: $pendingMove) { selection in
      PutioMovePicker(
        items: selection.items,
        load: actions?.loadFolders ?? load,
        continueLoad: actions?.continueFolders ?? continueLoad,
        actions: actions,
        refreshRequests: refreshRequests,
        onMove: { destination in
          guard !selection.isBulk, let item = selection.items.first else {
            actionRequest = .bulkMove(selection.items, destination)
            return .closed
          }
          return await move(item, to: destination)
        }
      )
    }
    .putioConfirmAlert($confirmAlert)
    .alert(
      bulkFailureTitle,
      isPresented: bulkFailurePresented,
      presenting: model.bulkOutcome
    ) { outcome in
      Button("Try Again") {
        actionRequest = .bulkRetry(outcome)
      }
      .accessibilityIdentifier("files.bulk.retry")
      Button("Done", role: .cancel) {
        model.clearBulkOutcome()
      }
      .accessibilityIdentifier("files.bulk.dismiss")
    } message: { outcome in
      Text(bulkOutcomeMessage(outcome))
    }
    .putioToast($toast)
    .overlay {
      if let progress = model.bulkProgress {
        ProgressView(
          value: Double(progress.completedCount),
          total: Double(progress.totalCount)
        ) {
          Text(bulkProgressTitle(progress))
        } currentValueLabel: {
          Text(progress.currentItem.name)
        }
        .controlSize(.large)
        .padding(PutioTheme.Spacing.space4)
        .modifier(PutioBulkProgressSurface())
        .accessibilityIdentifier("files.bulk.progress")
        .accessibilityLabel(Text(bulkProgressTitle(progress)))
        .accessibilityValue(
          Text(
            "\(progress.currentItem.name). \(progress.completedCount) of \(progress.totalCount) complete."
          )
        )
      }
    }
    .task(id: route.id) {
      refreshRegistration.activate()
      let pending = refreshRequests.sequence(for: route.id, owner: refreshRegistration.owner)
      // A fresh initial load already reflects any request that predates it.
      let loaded = await model.loadIfNeeded()
      guard loaded, let pending, !Task.isCancelled else { return }
      refreshRequests.markConsumed(pending, for: route.id, owner: refreshRegistration.owner)
    }
    .task(id: retryRequest) {
      await runRetryRequest()
    }
    .task(id: actionRequest) {
      await runActionRequest()
    }
    // Keyed on the loaded flag too, so a request that arrived while the
    // initial load was in flight is retried once the folder is loaded.
    .task(
      id: PendingRefresh(
        sequence: refreshRequests.sequence(for: route.id, owner: refreshRegistration.owner),
        loaded: model.isLoaded)
    ) {
      guard model.isLoaded,
        let sequence = refreshRequests.sequence(for: route.id, owner: refreshRegistration.owner)
      else { return }
      // A request stays pending until a refresh actually ran. One queued
      // behind a mutation is awaited so its success consumes the request too.
      let refreshed = await model.refreshWhenIdle()
      guard refreshed, !Task.isCancelled else { return }
      refreshRequests.markConsumed(sequence, for: route.id, owner: refreshRegistration.owner)
    }
    .onChange(of: model.state, initial: true) { _, state in
      if case .loaded(let contents) = state,
        let folder = contents.folder, folder.id == route.id
      {
        lastKnownFolderName = folder.name
      }
      if case .loaded(let contents) = state, !fileActionPending {
        selectedIDs.formIntersection(contents.items.map(\.id))
      }
      guard !reportedLoaded, case .loaded = state else { return }
      reportedLoaded = true
      onLoaded()
    }
    .onChange(of: editMode) { _, mode in
      if mode != .active, !fileActionPending {
        selectedIDs = []
      }
    }
  }

  @ViewBuilder
  private func loadedContent(_ contents: PutioFolderContents) -> some View {
    if contents.items.isEmpty, !contents.hasMore {
      GeometryReader { geometry in
        ScrollView {
          VStack(spacing: PutioTheme.Spacing.space4) {
            if let accountNotice {
              PutioInactiveAccountNoticeView(notice: accountNotice)
            }
            PutioEmptyStateView(
              icon: .folderFill,
              title: String(localized: "This folder is empty"),
              message: String(localized: "Files added here appear in this list.")
            )
            if let refreshFailure = model.refreshFailure {
              refreshFailureRow(refreshFailure)
            }
          }
          .padding(PutioTheme.Spacing.space4)
          .frame(minHeight: geometry.size.height)
        }
        .scrollBounceBehavior(.always)
        .refreshable {
          _ = await model.refresh()
        }
      }
      .accessibilityIdentifier("files.screen.\(route.id.rawValue)")
    } else {
      ScrollViewReader { proxy in
        folderList(contents)
          .task(id: model.isUpdatingSortOrder) {
            guard model.isUpdatingSortOrder else { return }
            withAnimation {
              proxy.scrollTo(accountNotice == nil ? ListTop.header : ListTop.notice, anchor: .top)
            }
          }
      }
    }
  }

  private enum ListTop: Hashable {
    case notice
    case header
  }

  private func folderList(_ contents: PutioFolderContents) -> some View {
    List(selection: isEditing && !fileActionPending ? $selectedIDs : nil) {
      if let accountNotice {
        PutioInactiveAccountNoticeView(notice: accountNotice)
          .listRowInsets(
            EdgeInsets(
              top: PutioTheme.Spacing.space2, leading: PutioTheme.Spacing.space3,
              bottom: PutioTheme.Spacing.space2, trailing: PutioTheme.Spacing.space3)
          )
          .id(ListTop.notice)
          .listRowSeparator(.hidden)
          .listRowBackground(PutioTheme.Colors.background)
          .selectionDisabled()
      }
      listTop(contents)
      ForEach(contents.items.filter { !trashingIDs.contains($0.id) }) { item in
        VStack(spacing: 0) {
          row(
            PutioBrowserItemPresentation(
              item: item,
              relativeTo: relativeDateReference ?? .now,
              locale: locale,
              sort: contents.sort ?? defaultSort
            )
          )
        }
        .tag(item.id)
        .listRowBackground(PutioTheme.Colors.background)
      }

      if contents.hasMore {
        loadMoreRow
          .listRowBackground(PutioTheme.Colors.background)
      }

      if let refreshFailure = model.refreshFailure {
        Section {
          refreshFailureRow(refreshFailure)
        }
      }
    }
    .listStyle(.plain)
    .refreshable {
      _ = await model.refresh()
    }
    .accessibilityIdentifier("files.screen.\(route.id.rawValue)")
  }

  private func hasHeader(_ contents: PutioFolderContents) -> Bool {
    route.id != .root && contents.folder?.id == route.id
  }

  @ViewBuilder
  private func listTop(_ contents: PutioFolderContents) -> some View {
    if hasHeader(contents) || model.isUpdatingSortOrder {
      VStack(alignment: .leading, spacing: PutioTheme.Spacing.space3) {
        folderHeader(contents)
        if model.isUpdatingSortOrder {
          HStack(spacing: PutioTheme.Spacing.space2) {
            ProgressView()
              .controlSize(.small)
            Text("Updating file order")
              .putioFont(PutioTheme.Typography.body)
          }
          .foregroundStyle(PutioTheme.Colors.textSecondary)
          .accessibilityElement(children: .combine)
          .accessibilityIdentifier("files.sorting.\(route.id.rawValue)")
        }
      }
      .id(ListTop.header)
      .listRowSeparator(.hidden)
      .listRowBackground(PutioTheme.Colors.background)
      .selectionDisabled()
    }
  }

  @ViewBuilder
  private func folderHeader(_ contents: PutioFolderContents) -> some View {
    if hasHeader(contents), let folder = contents.folder {
      HStack(alignment: .firstTextBaseline) {
        if let itemCount = contents.itemCount {
          Text("\(itemCount) items")
            .putioFont(PutioTheme.Typography.numeric)
        }
        Spacer(minLength: PutioTheme.Spacing.space2)
        Text(PutioFileRowModel.sizeText(bytes: folder.sizeBytes, locale: locale))
          .putioFont(PutioTheme.Typography.numeric)
      }
      .foregroundStyle(PutioTheme.Colors.textSecondary)
      .accessibilityElement(children: .combine)
      .accessibilityIdentifier("files.header.\(route.id.rawValue)")
    }
  }

  @ViewBuilder
  private func row(_ presentation: PutioBrowserItemPresentation) -> some View {
    if isEditing {
      PutioFileRow(presentation.row)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("files.item.\(presentation.id.rawValue)")
        .accessibilityValue(Text(selectionAccessibilityValue(for: presentation.item)))
    } else if let folderRoute = presentation.folderRoute {
      fileActions(
        for: presentation.item,
        content: NavigationLink(value: folderRoute) {
          PutioFileRow(presentation.row)
        }
        .disabled(fileActionPending)
        .accessibilityIdentifier("files.item.\(presentation.id.rawValue)")
      )
    } else {
      let fileRoute = PutioFileRoute(item: presentation.item)
      fileActions(
        for: presentation.item,
        content: Button {
          if let previewOpen, fileRoute.previewKind != nil {
            previewOpen(fileRoute, in: model.previewSource)
          } else {
            onFileSelected(fileRoute)
          }
        } label: {
          PutioFileRow(presentation.row)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(fileActionPending)
        .accessibilityIdentifier("files.item.\(presentation.id.rawValue)")
        .accessibilityValue(Text(fileAccessibilityValue(for: fileRoute)))
      )
    }
  }

  @ViewBuilder
  private func fileActions<Content: View>(
    for item: PutioFileItem,
    content: Content
  ) -> some View {
    let menu = PutioFileMenu(
      item: item,
      capabilities: .init(
        canEdit: model.supportsActions,
        canDownload: onDownload != nil,
        vlcInstalled: onExternalPlayback != nil,
        tracksWatched: tracksWatched))
    let row = content.frame(maxWidth: .infinity, alignment: .leading)
    if menu.sections.isEmpty {
      row
    } else {
      let actions = Dictionary(
        uniqueKeysWithValues: menu.sections.joined().map { ($0, itemAction($0, for: item)) })
      row.putioItemActions(
        PutioItemMenu(menu.sections.map { $0.compactMap { actions[$0] } }),
        leading: menu.leadingSwipe.compactMap { actions[$0] },
        trailing: menu.trailingSwipe.compactMap { actions[$0] })
    }
  }

  private func itemAction(_ row: PutioFileMenuRow, for item: PutioFileItem) -> PutioItemAction {
    let route = PutioFileRoute(item: item)
    let editingBlocked = !model.canStartAction || actionRequest != nil
    switch row {
    case .play:
      return PutioItemAction(
        id: "play", title: String(localized: "Play"), icon: .play,
        isDisabled: fileActionPending
      ) { onFileSelected(route) }
    case .download:
      return PutioItemAction(
        id: "download", title: String(localized: "Download"), icon: .arrowCircleDown,
        isDisabled: fileActionPending
      ) { onDownload?(route) }
    case .openInVLC:
      return PutioItemAction(
        id: "open-in-vlc", title: String(localized: "Open in VLC"), icon: .trafficCone,
        isDisabled: fileActionPending
      ) { onExternalPlayback?(route) }
    case .select:
      return PutioItemAction(
        id: "select", title: String(localized: "Select"), icon: .checkCircle,
        isDisabled: fileActionPending
      ) {
        editMode = .active
        selectedIDs = [item.id]
      }
    case .markWatched, .markUnwatched:
      let watched = row == .markWatched
      return PutioItemAction(
        id: watched ? "watched" : "unwatched",
        title: watched
          ? String(localized: "Mark as watched") : String(localized: "Mark as unwatched"),
        icon: watched ? .eye : .eyeSlash,
        isDisabled: editingBlocked
      ) { actionRequest = .setWatched(item, watched) }
    case .rename:
      return PutioItemAction(
        id: "rename", title: String(localized: "Rename"), icon: .pencilSimple,
        isDisabled: editingBlocked
      ) { nameAlert = renameAlert(for: item) }
    case .move:
      return PutioItemAction(
        id: "move", title: String(localized: "Move"), icon: .folderSimpleDashed,
        isDisabled: editingBlocked
      ) { pendingMove = MoveSelection(items: [item], isBulk: false) }
    case .trash:
      return PutioItemAction(
        id: "trash", title: deleteActionTitle, icon: .trash, role: .destructive,
        isDisabled: !model.canDelete || actionRequest != nil,
        subtitle: model.trashSettingKnown ? nil : PutioFileDeletionCopy.settingUnknown,
        asksFirst: !trashEnabled
      ) { requestDeletion(of: item) }
    }
  }

  private func requestDeletion(of item: PutioFileItem) {
    guard model.canDelete, actionRequest == nil else { return }
    if trashEnabled {
      trashingIDs.insert(item.id)
      actionRequest = .delete(item, permanently: false)
    } else {
      confirmAlert = PutioFileDeletionCopy.permanentDeleteAlert(itemCount: 1) {
        startDeletion(.delete(item, permanently: true))
      }
    }
  }

  private func refreshFailureRow(_ failure: PutioBrowserErrorPresentation) -> some View {
    VStack(alignment: .leading, spacing: PutioTheme.Spacing.space2) {
      Text("Could not refresh")
        .putioFont(PutioTheme.Typography.subheading)
        .foregroundStyle(PutioTheme.Colors.textPrimary)
      Text(failure.message)
        .putioFont(PutioTheme.Typography.body)
        .foregroundStyle(PutioTheme.Colors.textSecondary)
      Button("Try again") {
        requestRetry(.refresh)
      }
      .buttonStyle(.borderless)
    }
    .accessibilityIdentifier("files.refresh-error.\(route.id.rawValue)")
  }

  private var bulkMoveButton: some View {
    Button {
      let items = selectedItems
      guard !items.isEmpty else { return }
      pendingMove = MoveSelection(items: items, isBulk: true)
    } label: {
      Label("Move", systemImage: "folder")
    }
    .disabled(selectedItems.isEmpty || fileActionPending)
    .accessibilityIdentifier("files.bulk.move")
  }

  private var bulkDeleteButton: some View {
    Button(role: .destructive) {
      let items = selectedItems
      guard !items.isEmpty else { return }
      if trashEnabled {
        actionRequest = .bulkDelete(items)
      } else {
        confirmAlert = PutioFileDeletionCopy.permanentDeleteAlert(itemCount: items.count) {
          startDeletion(.bulkDelete(items))
        }
      }
    } label: {
      Label(deleteActionTitle, systemImage: "trash")
    }
    .disabled(selectedItems.isEmpty || fileActionPending || !model.canDelete)
    .accessibilityIdentifier("files.bulk.remove")
  }

  private var browseMenu: some View {
    Menu {
      PutioItemMenuContent(
        PutioItemMenu([
          [
            PutioItemAction(
              id: "select",
              title: String(localized: "Select"),
              icon: .checkCircle,
              isDisabled: fileActionPending || currentItems.isEmpty
            ) {
              editMode = .active
            },
            PutioItemAction(
              id: "new-folder",
              title: String(localized: "New folder"),
              icon: .folderSimplePlus,
              isDisabled: !model.canStartAction || actionRequest != nil
            ) {
              nameAlert = newFolderAlert()
            },
          ]
        ])
      )
    } label: {
      Label("More", systemImage: "ellipsis.circle")
    }
    .accessibilityIdentifier("files.menu")
  }

  @ViewBuilder
  private var loadMoreRow: some View {
    if let failure = model.loadMoreFailure {
      VStack(alignment: .leading, spacing: PutioTheme.Spacing.space2) {
        Text("Could not load more files")
          .putioFont(PutioTheme.Typography.subheading)
          .foregroundStyle(PutioTheme.Colors.textPrimary)
        Text(failure.message)
          .putioFont(PutioTheme.Typography.body)
          .foregroundStyle(PutioTheme.Colors.textSecondary)
        Button("Try again") {
          Task { await model.loadMore() }
        }
        .buttonStyle(.borderless)
      }
      .accessibilityIdentifier("files.more-error.\(route.id.rawValue)")
    } else {
      HStack {
        Spacer()
        if model.isLoadingMore {
          ProgressView()
        } else {
          Text("Loading more files")
            .putioFont(PutioTheme.Typography.caption)
            .foregroundStyle(PutioTheme.Colors.textSecondary)
        }
        Spacer()
      }
      .accessibilityIdentifier("files.more.\(route.id.rawValue)")
      .task(id: model.continuationKey) {
        await model.loadMore()
      }
    }
  }

  private func fileAccessibilityValue(for route: PutioFileRoute) -> String {
    switch route.openAction {
    case .video, .audio:
      guard route.item.isWatched else { return String(localized: "Not watched") }
      return
        String(
          localized:
            "Watched, resume at \(Self.resumePositionText(seconds: route.item.resumePositionSeconds))"
        )
    case .preview(let preview):
      return preview.kind == .image ? String(localized: "Image") : String(localized: "Document")
    case .unsupported:
      return String(localized: "Unsupported file")
    }
  }

  /// Spoken as a time, such as "12 minutes, 5 seconds", not raw seconds.
  static func resumePositionText(seconds: Int) -> String {
    Duration.seconds(seconds).formatted(
      .units(allowed: [.hours, .minutes, .seconds], width: .wide))
  }

  private func selectionAccessibilityValue(for item: PutioFileItem) -> String {
    selectedIDs.contains(item.id)
      ? String(localized: "Selected") : String(localized: "Not selected")
  }

  private func requestRetry(_ kind: RetryKind) {
    retrySequence &+= 1
    retryRequest = RetryRequest(id: retrySequence, kind: kind)
  }

  private func runRetryRequest() async {
    guard let request = retryRequest else { return }
    // `.task(id:)` re-runs on every appearance, so a request that outlived
    // its screen visit must not re-fire once the model no longer needs it.
    switch request.kind {
    case .load:
      guard case .failed = model.state else {
        retryRequest = nil
        return
      }
      // A fresh load already reflects any refresh request made before it.
      let pending = refreshRequests.sequence(for: route.id, owner: refreshRegistration.owner)
      await model.retry()
      if model.isLoaded, let pending, !Task.isCancelled {
        refreshRequests.markConsumed(pending, for: route.id, owner: refreshRegistration.owner)
      }
    case .refresh:
      guard model.refreshFailure != nil else {
        retryRequest = nil
        return
      }
      // A successful retry is as current as the pending request asked for.
      let pending = refreshRequests.sequence(for: route.id, owner: refreshRegistration.owner)
      let refreshed = await model.refresh()
      if refreshed, let pending, !Task.isCancelled {
        refreshRequests.markConsumed(pending, for: route.id, owner: refreshRegistration.owner)
      }
    }
    guard retryRequest == request else { return }
    retryRequest = nil
  }

  private var deleteActionTitle: String {
    PutioFileDeletionCopy(trashEnabled: trashEnabled).actionTitle
  }

  private var deletionPresentation: PutioFileDeletionPresentation {
    PutioFileDeletionPresentation(trashEnabled: trashEnabled)
  }

  private var currentItems: [PutioFileItem] {
    guard case .loaded(let contents) = model.state else { return [] }
    return contents.items
  }

  private var isEditing: Bool {
    editMode == .active
  }

  private var selectedItems: [PutioFileItem] {
    currentItems.filter { selectedIDs.contains($0.id) }
  }

  private var allLoadedItemsAreSelected: Bool {
    !currentItems.isEmpty && selectedIDs == Set(currentItems.map(\.id))
  }

  private func toggleAllLoadedItems() {
    if allLoadedItemsAreSelected {
      selectedIDs = []
    } else {
      selectedIDs = Set(currentItems.map(\.id))
    }
  }

  private var fileActionPending: Bool {
    actionRequest != nil || model.activeAction != nil || model.activeBulkAction != nil
  }

  private var actionNotifier: PutioFolderActionNotifier {
    PutioFolderActionNotifier(
      folderID: route.id, owner: refreshRegistration.owner, requests: refreshRequests)
  }

  private func renameAlert(for item: PutioFileItem) -> PutioTextAlert {
    let model = model
    let notifier = actionNotifier
    return PutioTextAlert(
      title: String(localized: "Rename"),
      initialText: item.name,
      submitTitle: String(localized: "Rename"),
      failureText: String(localized: "Couldn’t rename.")
    ) { name in
      await model.rename(item, to: name)
      try notifier.settleNameAction(of: model) { action in
        guard case .rename(let fileID, _, _) = action else { return false }
        return fileID == item.id
      } alreadyApplied: {
        guard case .loaded(let contents) = model.state else { return false }
        return contents.items.contains { $0.id == item.id && $0.name == name }
      }
    }
  }

  private func newFolderAlert() -> PutioTextAlert {
    let model = model
    let notifier = actionNotifier
    return PutioTextAlert(
      title: String(localized: "New folder"),
      message: String(localized: "In \(folderTitle)"),
      initialText: "",
      submitTitle: String(localized: "Create"),
      failureText: String(localized: "Could not create folder")
    ) { name in
      await model.createFolder(name: name)
      try notifier.settleNameAction(of: model) { action in
        guard case .createFolder = action else { return false }
        return true
      }
    }
  }

  private func move(
    _ item: PutioFileItem, to destination: PutioFolderRoute
  ) async -> PutioMoveSheetResult {
    await model.move(item, to: destination)
    selectedIDs.formIntersection(currentItems.map(\.id))
    guard let outcome = model.actionOutcome,
      case .move(let fileID, _, _, _, _) = outcome.action, fileID == item.id
    else { return .closed }
    if outcome.isNameTaken(movingFileID: item.id) {
      model.clearActionOutcome()
      return .nameTaken(item.name)
    }
    presentActionOutcome()
    return .closed
  }

  private func runActionRequest() async {
    guard let request = actionRequest else { return }
    // `.task(id:)` re-runs when the screen reappears mid-mutation; rejoin
    // the model-owned mutation instead of starting a duplicate.
    if startedActionRequest == request {
      await model.waitForActiveAction()
    } else {
      startedActionRequest = request
      switch request {
      case .sort(let sort):
        await model.setSort(sort)
      case .delete(let item, let permanently):
        await model.delete(item, permanently: permanently)
      case .restore(let item):
        await model.restore(item)
      case .setWatched(let item, let watched):
        await model.setWatched(item, watched)
      case .bulkDelete(let items):
        await model.delete(items)
      case .bulkMove(let items, let destination):
        await model.move(items, to: destination)
      case .bulkRetry(let outcome):
        switch await model.prepareBulkRetry(outcome) {
        case .ready(let items):
          if items.isEmpty {
            selectedIDs = []
            editMode = .inactive
          } else {
            switch outcome.action {
            case .delete:
              await model.delete(items)
            case .move(let destination):
              await model.move(items, to: destination)
            }
          }
        case .failed:
          break
        }
      }
    }
    guard actionRequest == request else { return }
    // The model now holds the optimistic removal or its rollback.
    trashingIDs = []
    actionRequest = nil
    startedActionRequest = nil
    selectedIDs.formIntersection(currentItems.map(\.id))
    if case .delete(let item, _) = request {
      presentActionOutcome(deleting: item)
    } else {
      presentActionOutcome()
    }
    presentBulkOutcome()
    if let item = queuedUndo {
      queuedUndo = nil
      actionRequest = .restore(item)
    }
  }

  private func presentActionOutcome(deleting item: PutioFileItem? = nil) {
    guard let outcome = model.actionOutcome else { return }
    actionNotifier.notify(outcome.action)
    switch outcome {
    case .succeeded(.delete(_, _, let permanently)) where trashEnabled && !permanently:
      toast = PutioToast(
        PutioFileDeletionCopy.trashed,
        action: item.map { item in
          PutioToast.Action(PutioFileDeletionCopy.undo) { undoTrash(of: item) }
        })
    case .succeeded(let action):
      toast = successToast(for: action)
    case .failed(.delete(_, _, let permanently), let failure):
      if failure.isTrashLimit, let item {
        confirmAlert = PutioFileDeletionCopy.trashLimitAlert {
          startDeletion(.delete(item, permanently: true))
        }
      } else {
        toast = PutioToast(
          PutioFileDeletionPresentation(trashEnabled: trashEnabled && !permanently)
            .singleFailureTitle)
      }
    case .failed(_, let failure):
      toast = PutioToast(failure.title)
    }
    model.clearActionOutcome()
  }

  private func startDeletion(_ request: FileActionRequest) {
    guard model.canDelete, actionRequest == nil else {
      toast = PutioToast(PutioFileDeletionPresentation(trashEnabled: false).singleFailureTitle)
      return
    }
    actionRequest = request
  }

  private func undoTrash(of item: PutioFileItem) {
    guard actionRequest == nil else {
      queuedUndo = item
      return
    }
    actionRequest = .restore(item)
  }

  private func presentBulkOutcome() {
    guard let outcome = model.bulkOutcome else { return }
    if case .delete = outcome.action {
      refreshRequests.requestAllLoadedFolders(excludingOwner: refreshRegistration.owner)
    } else {
      refreshRequests.request(folderID: route.id, excludingOwner: refreshRegistration.owner)
    }
    if case .move(let destination) = outcome.action {
      refreshRequests.request(folderID: destination.id)
      let movedIDs = Set(outcome.succeeded.map(\.id) + outcome.failures.map { $0.item.id })
      for id in movedIDs {
        refreshRequests.request(folderID: id)
      }
    }

    if outcome.failures.isEmpty {
      selectedIDs = []
      editMode = .inactive
      toast = PutioToast(bulkOutcomeMessage(outcome))
      model.clearBulkOutcome()
    } else {
      selectedIDs = Set(outcome.retryableItems(in: currentItems).map(\.id))
      editMode = .active
    }
  }

  private var bulkFailurePresented: Binding<Bool> {
    Binding(
      get: { model.bulkOutcome?.failures.isEmpty == false },
      set: { isPresented in
        if !isPresented { model.clearBulkOutcome() }
      }
    )
  }

  private var bulkFailureTitle: String {
    guard let outcome = model.bulkOutcome else {
      return String(localized: "Could not update items")
    }
    if outcome.action == .delete {
      return deletionPresentation.failureTitle(
        allItemsFailed: outcome.failures.count == outcome.completedCount
      )
    }
    return outcome.failures.count == outcome.completedCount
      ? String(localized: "Could not move items")
      : String(localized: "Some items couldn’t be moved")
  }

  private func bulkProgressTitle(_ progress: PutioBulkFileProgress) -> String {
    let currentCount = min(progress.completedCount + 1, progress.totalCount)
    if progress.action == .delete {
      return deletionPresentation.progressTitle(
        currentItem: currentCount,
        totalItems: progress.totalCount
      )
    }
    return String(localized: "Moving item \(currentCount) of \(progress.totalCount)…")
  }

  private func bulkOutcomeMessage(_ outcome: PutioBulkFileOutcome) -> String {
    let succeeded = outcome.succeeded.count
    let failed = outcome.failures.count
    if outcome.action == .delete {
      return deletionPresentation.outcomeMessage(succeeded: succeeded, failed: failed)
    }
    guard failed > 0 else { return PutioMoveCopy.moved(succeeded) }
    let successText = String(localized: "Moved \(succeeded) items.")
    return String(localized: "\(successText) \(failed) couldn’t be moved.")
  }

  private func successToast(for action: PutioFileAction) -> PutioToast? {
    switch action {
    case .createFolder, .rename:
      nil
    case .sort:
      PutioToast(String(localized: "Sorting changed"))
    case .delete:
      PutioToast(PutioFileDeletionCopy.deleted)
    case .restore:
      nil
    case .move:
      PutioToast(PutioMoveCopy.moved(1))
    case .setWatched(_, _, _, let watched):
      PutioToast(
        watched
          ? String(localized: "Marked as watched") : String(localized: "Marked as unwatched"))
    }
  }

  private enum RetryKind: Equatable {
    case load
    case refresh
  }

  private struct RetryRequest: Equatable {
    let id: UInt64
    let kind: RetryKind
  }

  private enum FileActionRequest: Equatable {
    case sort(PutioFolderSort)
    case delete(PutioFileItem, permanently: Bool)
    case restore(PutioFileItem)
    case setWatched(PutioFileItem, Bool)
    case bulkDelete([PutioFileItem])
    case bulkMove([PutioFileItem], PutioFolderRoute)
    case bulkRetry(PutioBulkFileOutcome)
  }

  private struct MoveSelection: Equatable, Identifiable {
    let items: [PutioFileItem]
    let isBulk: Bool

    var id: [PutioFileID] {
      items.map(\.id)
    }
  }
}

@MainActor
private struct PutioFolderActionNotifier {
  let folderID: PutioFileID
  let owner: UUID
  let requests: PutioFolderRefreshRequests

  func notify(_ action: PutioFileAction) {
    switch action {
    case .delete, .restore:
      requests.requestAllLoadedFolders(excludingOwner: owner)
    default:
      requests.request(folderID: folderID, excludingOwner: owner)
    }
    switch action {
    case .rename(let fileID, _, _):
      requests.request(folderID: fileID)
    case .move(let fileID, _, _, let destinationID, _):
      requests.request(folderID: fileID)
      requests.request(folderID: destinationID)
    default:
      break
    }
  }

  func settleNameAction(
    of model: PutioFolderModel,
    matching isNameAction: (PutioFileAction) -> Bool,
    alreadyApplied: () -> Bool = { false }
  ) throws {
    guard let outcome = model.actionOutcome, isNameAction(outcome.action) else {
      if alreadyApplied() { return }
      throw PutioNameActionFailure()
    }
    model.clearActionOutcome()
    notify(outcome.action)
    if case .failed = outcome { throw PutioNameActionFailure() }
  }
}

private struct PutioNameActionFailure: Error {}

private struct PutioBulkProgressSurface: ViewModifier {
  @ViewBuilder func body(content: Content) -> some View {
    if HarnessRendering.usesRasterFallback {
      content.background(
        .regularMaterial,
        in: RoundedRectangle(cornerRadius: PutioTheme.Radius.large)
      )
    } else {
      content.glassEffect(
        .regular,
        in: RoundedRectangle(cornerRadius: PutioTheme.Radius.large)
      )
    }
  }
}

struct PutioSelectionTabBarVisibility: ViewModifier {
  let isEditing: Bool

  @ViewBuilder func body(content: Content) -> some View {
    if isEditing {
      content.toolbar(.hidden, for: .tabBar)
    } else {
      content
    }
  }
}
