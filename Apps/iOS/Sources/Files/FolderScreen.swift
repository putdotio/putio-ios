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
  @State private var queuedUndo: [PutioFileItem]?
  @State private var pendingMove: MoveSelection?
  @State private var actionRequest: FileActionRequest?
  @State private var startedActionRequest: FileActionRequest?
  @State private var toast: PutioToast?
  @State private var selection = PutioSelection<PutioFileID>()
  // Rows a Trash move hides in the tapping transaction, so a destructive
  // swipe closes over a removed row instead of a row that vanishes later.
  @State private var trashingIDs: Set<PutioFileID> = []
  @State private var refreshRegistration: PutioFolderRefreshRegistration
  @State private var lastKnownFolderName: String?
  @State private var pinMoveRequest: PutioFileItemActionRequest?
  @State private var pinItemActions: PutioFileItemActionModel?
  @Environment(\.putioDefaultFolderSort) private var defaultSort
  @Environment(\.putioPinnedFiles) private var pinned
  @Environment(\.putioPreviewOpen) private var previewOpen
  @Environment(\.putioFileShare) private var fileShare
  @Environment(\.putioExclusiveLink) private var exclusiveLink
  @State private var linkItem: PutioFileItem?
  @State private var share = PutioFileShareModel()
  @State private var preparingToast: PutioToast.ID?
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
  private let onBulkDownload: PutioBulkFileSelection?
  private let castButton: AnyView?
  private let refreshRequests: PutioFolderRefreshRequests
  private let accountNotice: PutioInactiveAccountNotice?
  private let offlineFiles: PutioOfflineFolderFiles?

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
    onBulkDownload: PutioBulkFileSelection? = nil,
    castButton: AnyView? = nil,
    accountNotice: PutioInactiveAccountNotice? = nil,
    offlineFiles: PutioOfflineFolderFiles? = nil
  ) {
    self.accountNotice = accountNotice
    self.offlineFiles = offlineFiles
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
    _pinItemActions = State(
      initialValue: route.id == .root
        ? actions.map { PutioFileItemActionModel(actions: $0, refreshRequests: refreshRequests) }
        : nil)
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
    self.onBulkDownload = onBulkDownload
  }

  private var linkAction: (@MainActor @Sendable (PutioFileItem) -> Void)? {
    guard exclusiveLink != nil else { return nil }
    return { linkItem = $0 }
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
        PutioLoadingStateView.files
      case .loaded(let contents):
        loadedContent(contents)
      case .failed(let failure) where failure.isOffline:
        offlineContent(failure)
      case .failed(let failure):
        failureState(failure)
      }
    }
    .navigationTitle(folderTitle)
    .navigationBarTitleDisplayMode(route.id == .root && !isEditing ? .large : .inline)
    .navigationBarBackButtonHidden(navigationLocked || isEditing)
    .putioContentBackground()
    .toolbar {
      if !isEditing, model.supportsActions {
        if #available(iOS 27, *) {
          if let castButton {
            ToolbarItem(placement: .primaryAction) { castButton }
          }
          ToolbarItemGroup(placement: .primaryAction) {
            sortMenu
            browseMenu
          }
          .visibilityPriority(.high)
        } else {
          ToolbarItemGroup(placement: .primaryAction) {
            if let castButton { castButton }
            sortMenu
            browseMenu
          }
        }
      } else if !isEditing, let castButton {
        ToolbarItem(placement: .primaryAction) { castButton }
      }
    }
    .putioToast($toast)
    .putioSelectionMode(
      $selection, among: currentItems.map(\.id), actions: selectionActions,
      isBusy: fileActionPending
    )
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
    .putioExclusiveLinkSheet($linkItem)
    .onChange(of: share.state) { _, state in
      if case .fetching = state { return }
      if toast?.id == preparingToast { toast = nil }
      preparingToast = nil
    }
    .onDisappear { share.leave() }
    .modifier(
      PutioPinnedMoveHost(
        request: $pinMoveRequest, itemActions: pinItemActions, actions: actions, load: load,
        continueLoad: continueLoad, trashEnabled: trashEnabled,
        refreshRequests: refreshRequests, pins: pinnedSectionContext?.model)
    )
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
    .task(id: isOffline && retryRequest == nil) {
      await retryWhileOffline()
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
      await pinnedSectionContext?.model.load()
    }
    .onChange(of: model.state, initial: true) { _, state in
      if case .loaded(let contents) = state,
        let folder = contents.folder, folder.id == route.id
      {
        lastKnownFolderName = folder.name
      }
      guard !reportedLoaded, case .loaded = state else { return }
      reportedLoaded = true
      onLoaded()
    }
    .onChange(of: fileActionPending) { _, pending in
      guard !pending, let pins = pinned?.model, !pins.items.isEmpty else { return }
      Task { await pins.load() }
    }
    .onChange(of: isEditing) { _, editing in
      if editing { share.leave() }
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
            PutioEmptyStateView.folder(
              createFolder: model.supportsActions ? { nameAlert = newFolderAlert() } : nil
            )
            .disabled(!model.canStartAction || actionRequest != nil)
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
            await Task.yield()
            withAnimation {
              proxy.scrollTo(accountNotice == nil ? ListTop.header : ListTop.notice, anchor: .top)
            }
          }
      }
    }
  }

  private static let prefetchDistance = 5

  private enum ListTop: Hashable {
    case notice
    case header
  }

  private func folderList(_ contents: PutioFolderContents) -> some View {
    List {
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
      pinnedSection
      let items = contents.items.filter { !trashingIDs.contains($0.id) }
      let prefetchIDs = contents.hasMore ? Set(items.suffix(Self.prefetchDistance).map(\.id)) : []
      ForEach(items) { item in
        row(
          PutioBrowserItemPresentation(
            item: item,
            relativeTo: relativeDateReference ?? .now,
            locale: locale,
            sort: contents.sort ?? defaultSort
          )
        )
        .task(id: prefetchIDs.contains(item.id) ? model.continuationKey : nil) {
          guard prefetchIDs.contains(item.id), model.loadMoreFailure == nil else { return }
          await model.loadMore()
        }
      }

      if contents.hasMore {
        loadMoreRow
          .listRowInsets(EdgeInsets())
          .listRowSeparator(.hidden)
          .listRowBackground(PutioTheme.Colors.background)
          .selectionDisabled()
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
      await pinnedSectionContext?.model.load()
    }
    .accessibilityIdentifier("files.screen.\(route.id.rawValue)")
  }

  private var pinnedSectionContext: PutioPinnedFilesContext? {
    route.id == .root ? pinned : nil
  }

  @ViewBuilder
  private var pinnedSection: some View {
    if let pinnedSectionContext, !isEditing {
      PutioPinnedSection(
        context: pinnedSectionContext,
        canEdit: model.supportsActions,
        isDisabled: navigationLocked || pinItemActions?.canStartAction == false,
        onOpen: onFileSelected,
        onMove: { pinMoveRequest = .move($0) },
        onLink: linkAction)
    }
  }

  private func hasHeader(_ contents: PutioFolderContents) -> Bool {
    route.id != .root && contents.folder?.id == route.id
  }

  @ViewBuilder
  private func listTop(_ contents: PutioFolderContents) -> some View {
    if isEditing || hasHeader(contents) || model.isUpdatingSortOrder {
      VStack(alignment: .leading, spacing: PutioTheme.Spacing.space3) {
        if isEditing {
          selectionSummary(contents)
        } else {
          folderHeader(contents)
        }
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

  private func selectionSummary(_ contents: PutioFolderContents) -> some View {
    HStack(alignment: .firstTextBaseline) {
      Text("\(contents.itemCount ?? contents.items.count) items")
        .putioFont(PutioTheme.Typography.numeric)
      Spacer(minLength: PutioTheme.Spacing.space2)
      if !selectedItems.isEmpty {
        let bytes = selectedItems.reduce(Int64(0)) { $0 + $1.sizeBytes }
        Text("\(PutioFileRowModel.sizeText(bytes: bytes, locale: locale)) selected")
          .putioFont(PutioTheme.Typography.numeric)
      }
    }
    .foregroundStyle(PutioTheme.Colors.textSecondary)
    .accessibilityElement(children: .combine)
    .accessibilityIdentifier("files.selection.summary")
  }

  @ViewBuilder
  private func row(_ presentation: PutioBrowserItemPresentation) -> some View {
    if isEditing {
      PutioSelectableRow(isSelected: selection.contains(presentation.id)) {
        selection.toggle(presentation.id)
      } content: {
        PutioFileRow(presentation.row)
      }
      .disabled(fileActionPending)
      .accessibilityIdentifier("files.item.\(presentation.id.rawValue)")
      .accessibilityValue(Text(selectionAccessibilityValue(for: presentation.item)))
    } else if let folderRoute = presentation.folderRoute {
      fileActions(
        for: presentation.item,
        content: NavigationLink(value: folderRoute) {
          PutioFileRow(presentation.row)
        }
        .disabled(navigationLocked)
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
        .disabled(navigationLocked)
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
        tracksWatched: tracksWatched,
        canShare: fileShare != nil,
        canLink: exclusiveLink != nil,
        pinned: pinned.map { $0.model.isPinned(item.id) }),
      isDownloaded: PutioFileShareSource.dependsOnDownload(item)
        && fileShare.map { share.isDownloaded(item, using: $0) } ?? false)
    let row = content.frame(maxWidth: .infinity, alignment: .leading)
      .listRowBackground(PutioTheme.Colors.background)
      .background {
        if let file = share.presented(for: item.id) {
          PutioShareSheetAnchor(file: file, name: item.name, model: share)
        }
      }
      .onDisappear { share.leave(item.id) }
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
    case .share:
      return PutioItemAction(
        id: "share", title: String(localized: "Share"), icon: .export,
        isDisabled: fileActionPending
      ) { startShare(item) }
    case .select:
      return PutioItemAction(
        id: "select", title: String(localized: "Select"), icon: .checkCircle,
        isDisabled: fileActionPending
      ) {
        selection.begin()
        selection.toggle(item.id)
      }
    case .pin, .unpin:
      let pins = pinned?.model
      let location = folderTitle
      return row == .pin
        ? PutioItemAction(id: "pin", title: String(localized: "Pin"), icon: .pushPin) {
          Task { await pins?.pin(item, in: location) }
        }
        : PutioItemAction(id: "unpin", title: String(localized: "Unpin"), icon: .pushPinSlash) {
          Task { await pins?.unpin(item) }
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
    case .exclusiveLink:
      return PutioItemAction(
        id: "exclusive-link", title: String(localized: "Exclusive link"), icon: .link,
        isDisabled: fileActionPending
      ) { linkItem = item }
    case .trash:
      return PutioItemAction(
        id: "trash", title: deleteActionTitle, icon: .trash, role: .destructive,
        isDisabled: !model.canDelete || actionRequest != nil,
        subtitle: model.trashSettingKnown ? nil : PutioFileDeletionCopy.settingUnknown,
        asksFirst: !trashEnabled
      ) { requestDeletion(of: item) }
    }
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
      Text(failure.isOffline ? PutioScreenErrorKind.failed.message : failure.message)
        .putioFont(PutioTheme.Typography.body)
        .foregroundStyle(PutioTheme.Colors.textSecondary)
      Button("Try again") {
        requestRetry(.refresh)
      }
      .buttonStyle(.borderless)
    }
    .accessibilityIdentifier("files.refresh-error.\(route.id.rawValue)")
  }

  private var selectionActions: [PutioSelectionAction] {
    guard isEditing else { return [] }
    let items = selectedItems
    let menu = PutioFileSelectionMenu(
      selected: items, canDownload: onBulkDownload != nil, tracksWatched: tracksWatched)
    return menu.actions.map { selectionAction($0, for: items) }
  }

  private func selectionAction(
    _ action: PutioFileSelectionAction, for items: [PutioFileItem]
  ) -> PutioSelectionAction {
    let editingBlocked = !model.canStartAction || actionRequest != nil
    switch action {
    case .move:
      return PutioSelectionAction(
        id: "move", title: String(localized: "Move"), icon: .folderSimpleDashed,
        isDisabled: editingBlocked
      ) { pendingMove = MoveSelection(items: items, isBulk: true) }
    case .download:
      return PutioSelectionAction(
        id: "download", title: String(localized: "Download"), icon: .arrowCircleDown
      ) {
        selection.end()
        onBulkDownload?(items.map(PutioFileRoute.init(item:)))
      }
    case .markWatched, .markUnwatched:
      let watched = action == .markWatched
      return PutioSelectionAction(
        id: watched ? "watched" : "unwatched",
        title: watched ? String(localized: "Watched") : String(localized: "Unwatched"),
        icon: watched ? .eye : .eyeSlash,
        isDisabled: editingBlocked
      ) { actionRequest = .bulkWatched(items, watched) }
    case .trash:
      return PutioSelectionAction(
        id: "trash",
        title: trashEnabled ? String(localized: "Trash") : String(localized: "Delete"),
        icon: .trash, isDestructive: true,
        isDisabled: !model.canDelete || actionRequest != nil
      ) { requestBulkDeletion(of: items) }
    }
  }

  private func requestBulkDeletion(of items: [PutioFileItem]) {
    guard !items.isEmpty, model.canDelete, actionRequest == nil else { return }
    if trashEnabled {
      actionRequest = .bulkDelete(items)
    } else {
      confirmAlert = PutioFileDeletionCopy.permanentDeleteAlert(itemCount: items.count) {
        startDeletion(.bulkDelete(items))
      }
    }
  }

  private var sortMenu: some View {
    PutioFolderSortMenu(
      current: model.sort ?? defaultSort,
      isDisabled: !model.canStartAction || actionRequest != nil || model.isUpdatingSortOrder
    ) { sort in
      actionRequest = .sort(sort)
    }
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
              selection.begin()
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
    if model.loadMoreFailure != nil {
      PutioNextPageFailedFooter.files(retryIdentifier: "files.more-retry.\(route.id.rawValue)") {
        Task { await model.loadMore() }
      }
      .accessibilityElement(children: .contain)
      .accessibilityIdentifier("files.more-error.\(route.id.rawValue)")
    } else {
      PutioNextPageLoadingFooter(accessibilityLabel: String(localized: "Loading more files"))
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
    selection.contains(item.id)
      ? String(localized: "Selected") : String(localized: "Not selected")
  }

  private func failureState(_ failure: PutioBrowserErrorPresentation) -> some View {
    PutioErrorStateView(
      title: failure.title,
      message: failure.message,
      retryTitle: String(localized: "Try again"),
      retryIdentifier: "files.retry.\(route.id.rawValue)"
    ) {
      requestRetry(.load)
    }
  }

  private func offlineContent(_ failure: PutioBrowserErrorPresentation) -> some View {
    GeometryReader { geometry in
      ScrollView {
        VStack(spacing: PutioTheme.Spacing.space3) {
          let items = offlineFiles?.items(route.id) ?? []
          if let offlineFiles, !items.isEmpty {
            PutioOfflineBanner()
              .accessibilityIdentifier("files.offline-banner")
            ForEach(items) { item in
              offlineRow(item, open: offlineFiles.open)
            }
          }
          failureState(failure)
            .frame(maxHeight: .infinity, alignment: .top)
        }
        .padding(.horizontal, PutioTheme.Spacing.space3)
        .frame(minHeight: geometry.size.height, alignment: .top)
      }
    }
  }

  private func offlineRow(_ item: PutioFileItem, open: @escaping (PutioFileID) -> Void)
    -> some View
  {
    let presentation = PutioBrowserItemPresentation(
      item: item, relativeTo: relativeDateReference ?? .now, locale: locale,
      sort: defaultSort)
    let row = presentation.row
    return Button {
      open(item.id)
    } label: {
      PutioFileRow(
        PutioFileRowModel(
          name: row.name, kind: row.kind, sizeText: row.sizeText, dateText: row.dateText,
          isOnDevice: true, isWatched: row.isWatched, showsDisclosure: false)
      )
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .accessibilityIdentifier("files.offline-item.\(item.id.rawValue)")
  }

  private var isOffline: Bool {
    if case .failed(let failure) = model.state { return failure.isOffline }
    return false
  }

  private static func offlineRetryDelay(attempt: Int) -> Duration {
    .seconds(min(3 << min(attempt, 4), 30))
  }

  private func retryWhileOffline() async {
    var attempt = 0
    while isOffline, retryRequest == nil {
      do {
        try await Task.sleep(for: Self.offlineRetryDelay(attempt: attempt))
      } catch {
        return
      }
      guard isOffline, retryRequest == nil else { return }
      let pending = refreshRequests.sequence(for: route.id, owner: refreshRegistration.owner)
      if await model.retryKeepingFailure() {
        if let pending, !Task.isCancelled {
          refreshRequests.markConsumed(pending, for: route.id, owner: refreshRegistration.owner)
        }
        return
      }
      attempt += 1
    }
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
    selection.isActive
  }

  private var selectedItems: [PutioFileItem] {
    currentItems.filter { selection.contains($0.id) }
  }

  private var fileActionPending: Bool {
    actionRequest != nil || model.activeAction != nil || model.activeBulkAction != nil
  }

  private var navigationLocked: Bool {
    if model.isUpdatingSortOrder { return false }
    if case .sort = actionRequest { return false }
    return fileActionPending
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
      failureText: String(localized: "Couldn’t create folder.")
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
      case .restore(let items):
        await model.restore(items)
      case .setWatched(let item, let watched):
        await model.setWatched(item, watched)
      case .bulkDelete(let items):
        await model.delete(items)
      case .bulkWatched(let items, let watched):
        await model.setWatched(items, watched)
      case .bulkMove(let items, let destination):
        await model.move(items, to: destination)
      case .bulkRetry(let outcome):
        switch await model.prepareBulkRetry(outcome) {
        case .ready(let items):
          if items.isEmpty {
            selection.end()
          } else {
            switch outcome.action {
            case .delete:
              await model.delete(items)
            case .move(let destination):
              await model.move(items, to: destination)
            case .setWatched(let watched):
              await model.setWatched(items, watched)
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
    selection.retain(currentItems.map(\.id))
    if case .delete(let item, _) = request {
      presentActionOutcome(deleting: item)
    } else {
      presentActionOutcome()
    }
    presentBulkOutcome()
    if let items = queuedUndo {
      queuedUndo = nil
      actionRequest = .restore(items)
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
          PutioToast.Action(PutioFileDeletionCopy.undo) { undoTrash(of: [item]) }
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

  private func undoTrash(of items: [PutioFileItem]) {
    guard actionRequest == nil else {
      queuedUndo = items
      return
    }
    actionRequest = .restore(items)
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

    model.clearBulkOutcome()
    if outcome.failures.isEmpty {
      selection.end()
      toast = bulkSuccessToast(outcome)
    } else {
      selection = PutioSelection(
        isActive: true, selectedIDs: Set(outcome.retryableItems(in: currentItems).map(\.id)))
      toast = PutioToast(
        bulkFailureMessage(outcome),
        action: PutioToast.Action(String(localized: "Try again")) {
          retryBulk(outcome)
        })
    }
  }

  private func retryBulk(_ outcome: PutioBulkFileOutcome) {
    guard actionRequest == nil else { return }
    actionRequest = .bulkRetry(outcome)
  }

  private func bulkSuccessToast(_ outcome: PutioBulkFileOutcome) -> PutioToast {
    let count = outcome.succeeded.count
    switch outcome.action {
    case .delete where trashEnabled:
      let trashed = outcome.succeeded
      return PutioToast(
        String(localized: "Moved \(count) items to trash"),
        action: PutioToast.Action(PutioFileDeletionCopy.undo) { undoTrash(of: trashed) })
    case .delete:
      return PutioToast(deletionPresentation.outcomeMessage(succeeded: count, failed: 0))
    case .move:
      return PutioToast(PutioMoveCopy.moved(count))
    case .setWatched(let watched):
      return PutioToast(
        watched
          ? String(localized: "Marked as watched") : String(localized: "Marked as unwatched"))
    }
  }

  private func bulkFailureMessage(_ outcome: PutioBulkFileOutcome) -> String {
    let failed = outcome.failures.count
    switch outcome.action {
    case .delete, .move:
      return String(localized: "\(failed) items are still in Files.")
    case .setWatched(let watched):
      return watched
        ? String(localized: "Couldn’t mark \(failed) items as watched.")
        : String(localized: "Couldn’t mark \(failed) items as unwatched.")
    }
  }

  private func bulkProgressTitle(_ progress: PutioBulkFileProgress) -> String {
    let currentCount = min(progress.completedCount + 1, progress.totalCount)
    switch progress.action {
    case .delete:
      return deletionPresentation.progressTitle(
        currentItem: currentCount,
        totalItems: progress.totalCount
      )
    case .setWatched:
      return String(localized: "Updating item \(currentCount) of \(progress.totalCount)…")
    case .move:
      break
    }
    return String(localized: "Moving item \(currentCount) of \(progress.totalCount)…")
  }

  private func successToast(for action: PutioFileAction) -> PutioToast? {
    switch action {
    case .createFolder, .rename, .sort:
      nil
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
    case restore([PutioFileItem])
    case setWatched(PutioFileItem, Bool)
    case bulkDelete([PutioFileItem])
    case bulkWatched([PutioFileItem], Bool)
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
