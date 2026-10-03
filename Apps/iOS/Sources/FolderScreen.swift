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
  @State private var editor: FileEditor?
  @State private var pendingDeletion: PutioFileItem?
  @State private var pendingBulkDeletion: [PutioFileItem] = []
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
  private let relativeDateReference: Date?
  private let locale: Locale
  private let load: PutioFolderLoad
  private let continueLoad: PutioFolderContinue?
  private let actions: PutioFileActions?
  private let trashEnabled: Bool
  private let onLoaded: @MainActor @Sendable () -> Void
  private let onFileSelected: PutioFileSelection
  private let onExternalPlayback: PutioFileSelection?
  private let onDownload: PutioFileSelection?
  private let onCast: PutioFileSelection?
  private let castButton: AnyView?
  private let refreshRequests: PutioFolderRefreshRequests

  init(
    route: PutioFolderRoute,
    load: @escaping PutioFolderLoad,
    continueLoad: PutioFolderContinue? = nil,
    actions: PutioFileActions? = nil,
    trashEnabled: Bool = true,
    initialContents: PutioFolderContents? = nil,
    relativeTo relativeDateReference: Date? = nil,
    locale: Locale = .current,
    onLoaded: @escaping @MainActor @Sendable () -> Void = {},
    refreshRequests: PutioFolderRefreshRequests = PutioFolderRefreshRequests(),
    onFileSelected: @escaping PutioFileSelection,
    onExternalPlayback: PutioFileSelection? = nil,
    onDownload: PutioFileSelection? = nil,
    onCast: PutioFileSelection? = nil,
    castButton: AnyView? = nil
  ) {
    self.onCast = onCast
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
        PutioLoadingStateView(title: "Loading files")
      case .loaded(let contents):
        loadedContent(contents)
      case .failed(let failure):
        PutioErrorStateView(
          title: failure.title,
          message: failure.message,
          retryTitle: "Try again"
        ) {
          requestRetry(.load)
        }
      }
    }
    .navigationTitle(folderTitle)
    .navigationBarTitleDisplayMode(.inline)
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
          browseMenu
        }
      } else if let castButton {
        ToolbarItem(placement: .primaryAction) { castButton }
      }
    }
    .modifier(PutioSelectionTabBarVisibility(isEditing: isEditing))
    .environment(\.editMode, $editMode)
    .sheet(item: $editor) { editor in
      switch editor {
      case .createFolder:
        PutioFileNameEditor(
          title: "New Folder",
          submitTitle: "Create",
          isValid: PutioFileNameEditor.isValidName,
          onCancel: { self.editor = nil },
          onSubmit: { submit(.createFolder($0)) }
        )
      case .rename(let item):
        PutioFileNameEditor(
          title: "Rename Item",
          submitTitle: "Rename",
          initialName: item.name,
          isValid: { PutioFileNameEditor.isValidRename($0, of: item) },
          onCancel: { self.editor = nil },
          onSubmit: { submit(.rename(item, $0)) }
        )
      }
    }
    .sheet(item: $pendingMove) { selection in
      PutioMovePicker(
        items: selection.items,
        load: actions?.loadFolders ?? load,
        continueLoad: actions?.continueFolders ?? continueLoad,
        actions: actions,
        refreshRequests: refreshRequests,
        onMove: { destination in
          pendingMove = nil
          if selection.isBulk {
            actionRequest = .bulkMove(selection.items, destination)
          } else if let item = selection.items.first {
            actionRequest = .move(item, destination)
          }
        }
      )
    }
    .confirmationDialog(
      deleteConfirmationTitle,
      isPresented: deleteConfirmationPresented,
      titleVisibility: .visible
    ) {
      Button(deleteActionTitle, role: .destructive) {
        guard let item = pendingDeletion else { return }
        actionRequest = .delete(item)
        pendingDeletion = nil
      }
      .disabled(!model.canDelete)
      .accessibilityIdentifier("files.delete-confirm")
      Button("Cancel", role: .cancel) {
        pendingDeletion = nil
      }
    } message: {
      Text(deleteConfirmationMessage)
    }
    .confirmationDialog(
      bulkDeleteConfirmationTitle,
      isPresented: bulkDeleteConfirmationPresented,
      titleVisibility: .visible
    ) {
      Button(deleteActionTitle, role: .destructive) {
        let items = pendingBulkDeletion
        pendingBulkDeletion = []
        actionRequest = .bulkDelete(items)
      }
      .disabled(!model.canDelete)
      .accessibilityIdentifier("files.bulk.remove-confirm")
      Button("Cancel", role: .cancel) {
        pendingBulkDeletion = []
      }
    } message: {
      Text(deleteConfirmationMessage)
    }
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
            "\(progress.currentItem.name). \(progress.completedCount) of "
              + "\(progress.totalCount) complete."
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
    .task(id: toast) {
      guard let presentedToast = toast else { return }
      try? await Task.sleep(for: .seconds(3))
      guard !Task.isCancelled, toast == presentedToast else { return }
      toast = nil
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
            PutioEmptyStateView(
              icon: .folderFill,
              title: "This folder is empty",
              message: "Files added here appear in this list."
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
      List(selection: isEditing && !fileActionPending ? $selectedIDs : nil) {
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
          onFileSelected(fileRoute)
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

  private func fileActions<Content: View>(
    for item: PutioFileItem,
    content: Content
  ) -> some View {
    content
      .frame(maxWidth: .infinity, alignment: .leading)
      .contextMenu {
        actionButtons(for: item)
      }
      .swipeActions(edge: .trailing, allowsFullSwipe: false) {
        if model.supportsActions {
          deleteButton(for: item)
            .tint(PutioTheme.Colors.destructive)
        }
      }
      .swipeActions(edge: .leading, allowsFullSwipe: false) {
        if model.supportsActions {
          moveButton(for: item)
            .tint(PutioTheme.Colors.accent)
        }
      }
  }

  @ViewBuilder
  private func actionButtons(for item: PutioFileItem) -> some View {
    if let route = PutioBrowserItemPresentation(item: item).fileRoute,
      (onDownload != nil && route.supportsOfflineDownload)
        || (onExternalPlayback != nil && route.supportsExternalPlayback)
        || (onCast != nil && route.supportsCasting)
    {
      Section {
        if let onCast, route.supportsCasting {
          Button {
            onCast(route)
          } label: {
            Label("Cast", systemImage: "tv")
          }
          .disabled(fileActionPending)
          .accessibilityIdentifier("files.cast.\(item.id.rawValue)")
        }
        if let onDownload, route.supportsOfflineDownload {
          Button {
            onDownload(route)
          } label: {
            Label("Download", systemImage: "arrow.down.circle")
          }
          .disabled(fileActionPending)
          .accessibilityIdentifier("files.download.\(item.id.rawValue)")
        }
        if let onExternalPlayback, route.supportsExternalPlayback {
          Button {
            onExternalPlayback(route)
          } label: {
            Label("Open in VLC", systemImage: "play.rectangle")
          }
          .disabled(fileActionPending)
          .accessibilityIdentifier("files.open-in-vlc.\(item.id.rawValue)")
        }
      }
    }
    if model.supportsActions {
      ControlGroup {
        moveButton(for: item)
      }
      Section {
        renameButton(for: item)
      }
      Section {
        deleteButton(for: item)
      }
    }
  }

  private func moveButton(for item: PutioFileItem) -> some View {
    Button {
      pendingMove = MoveSelection(items: [item], isBulk: false)
    } label: {
      Label("Move", systemImage: "folder")
    }
    .disabled(!model.canStartAction || actionRequest != nil)
    .accessibilityIdentifier("files.move.\(item.id.rawValue)")
  }

  private func renameButton(for item: PutioFileItem) -> some View {
    Button {
      editor = .rename(item)
    } label: {
      Label("Rename", systemImage: "pencil")
    }
    .disabled(!model.canStartAction || actionRequest != nil)
    .accessibilityIdentifier("files.rename.\(item.id.rawValue)")
  }

  private func deleteButton(for item: PutioFileItem) -> some View {
    Button(role: .destructive) {
      // Trash is recoverable, so only a permanent deletion asks first.
      if trashEnabled {
        trashingIDs.insert(item.id)
        actionRequest = .delete(item)
      } else {
        pendingDeletion = item
      }
    } label: {
      Label(deleteActionTitle, systemImage: "trash")
    }
    .disabled(!model.canDelete || actionRequest != nil)
    .accessibilityIdentifier("files.delete.\(item.id.rawValue)")
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
      if trashEnabled {
        let items = selectedItems
        guard !items.isEmpty else { return }
        actionRequest = .bulkDelete(items)
      } else {
        pendingBulkDeletion = selectedItems
      }
    } label: {
      Label(deleteActionTitle, systemImage: "trash")
    }
    .disabled(selectedItems.isEmpty || fileActionPending || !model.canDelete)
    .accessibilityIdentifier("files.bulk.remove")
  }

  private var browseMenu: some View {
    Menu {
      Button {
        editMode = .active
      } label: {
        Label("Select", systemImage: "checkmark.circle")
      }
      .disabled(fileActionPending || currentItems.isEmpty)
      .accessibilityIdentifier("files.selection.toggle")
      Button {
        editor = .createFolder
      } label: {
        Label("New Folder", systemImage: "folder.badge.plus")
      }
      .disabled(!model.canStartAction || actionRequest != nil)
      .accessibilityIdentifier("files.new-folder")
      Section {
        sortSection
      }
    } label: {
      Label("More", systemImage: "ellipsis.circle")
    }
    .accessibilityIdentifier("files.menu")
    .accessibilityLabel(PutioFolderSortRows.menuLabel(for: model.sort))
  }

  private var sortSection: some View {
    PutioFolderSortRows(
      current: model.sort,
      isDisabled: !model.canStartAction || actionRequest != nil
    ) { sort in
      actionRequest = .sort(sort)
    }
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
      guard route.item.isWatched else { return "Not watched" }
      return
        "Watched, resume at \(Self.resumePositionText(seconds: route.item.resumePositionSeconds))"
    case .preview(let preview):
      return preview.kind == .image ? "Image" : "Document"
    case .unsupported:
      return "Unsupported file"
    }
  }

  /// Spoken as a time, such as "12 minutes, 5 seconds", not raw seconds.
  static func resumePositionText(seconds: Int) -> String {
    Duration.seconds(seconds).formatted(
      .units(allowed: [.hours, .minutes, .seconds], width: .wide))
  }

  private func selectionAccessibilityValue(for item: PutioFileItem) -> String {
    selectedIDs.contains(item.id) ? "Selected" : "Not selected"
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

  private var deleteConfirmationPresented: Binding<Bool> {
    Binding(
      get: { pendingDeletion != nil },
      set: { isPresented in
        if !isPresented { pendingDeletion = nil }
      }
    )
  }

  private var deleteActionTitle: String {
    deletionPresentation.actionTitle
  }

  private var deleteConfirmationTitle: String {
    guard let item = pendingDeletion else { return deleteActionTitle }
    return deletionPresentation.confirmationTitle(itemName: item.name)
  }

  private var deleteConfirmationMessage: String {
    deletionPresentation.confirmationMessage(itemCount: max(pendingBulkDeletion.count, 1))
  }

  private var bulkDeleteConfirmationPresented: Binding<Bool> {
    Binding(
      get: { !pendingBulkDeletion.isEmpty },
      set: { isPresented in
        if !isPresented { pendingBulkDeletion = [] }
      }
    )
  }

  private var bulkDeleteConfirmationTitle: String {
    deletionPresentation.confirmationTitle(itemCount: pendingBulkDeletion.count)
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

  private func submit(_ request: FileActionRequest) {
    actionRequest = request
    editor = nil
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
      case .createFolder(let name):
        await model.createFolder(name: name)
      case .sort(let sort):
        await model.setSort(sort)
      case .rename(let item, let name):
        await model.rename(item, to: name)
      case .delete(let item):
        await model.delete(item)
      case .move(let item, let destination):
        await model.move(item, to: destination)
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
    presentActionOutcome()
    presentBulkOutcome()
  }

  private func presentActionOutcome() {
    guard let outcome = model.actionOutcome else { return }
    // A failed mutation may still have reached the server. Notify siblings;
    // this screen's model already reconciles its own mutation outcome.
    let action =
      switch outcome {
      case .succeeded(let action), .failed(let action, _): action
      }
    if case .delete = action {
      // A deleted folder can contain any of the other mounted destinations.
      refreshRequests.requestAllLoadedFolders(excludingOwner: refreshRegistration.owner)
    } else {
      refreshRequests.request(folderID: route.id, excludingOwner: refreshRegistration.owner)
    }
    switch action {
    case .rename(let fileID, _, _):
      refreshRequests.request(folderID: fileID)
    case .move(let fileID, _, _, let destinationID, _):
      refreshRequests.request(folderID: fileID)
      refreshRequests.request(folderID: destinationID)
    default:
      break
    }
    switch outcome {
    case .succeeded(let action):
      toast = successToast(for: action)
    case .failed(let action, let failure):
      let title: String
      if case .delete = action {
        title = deletionPresentation.singleFailureTitle
      } else {
        title = failure.title
      }
      toast = PutioToast(variant: .danger, title: title, message: failure.message)
    }
    model.clearActionOutcome()
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
      toast = PutioToast(
        variant: .success,
        title: bulkSuccessTitle(outcome.action),
        message: bulkOutcomeMessage(outcome)
      )
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
    guard let outcome = model.bulkOutcome else { return "Could not update items" }
    if outcome.action == .delete {
      return deletionPresentation.failureTitle(
        allItemsFailed: outcome.failures.count == outcome.completedCount
      )
    }
    return outcome.failures.count == outcome.completedCount
      ? "Could not move items"
      : "Some items couldn’t be moved"
  }

  private func bulkProgressTitle(_ progress: PutioBulkFileProgress) -> String {
    let currentCount = min(progress.completedCount + 1, progress.totalCount)
    if progress.action == .delete {
      return deletionPresentation.progressTitle(
        currentItem: currentCount,
        totalItems: progress.totalCount
      )
    }
    return "Moving item \(currentCount) of \(progress.totalCount)…"
  }

  private func bulkSuccessTitle(_ action: PutioBulkFileAction) -> String {
    action == .delete ? deletionPresentation.bulkSuccessTitle : "Items moved"
  }

  private func bulkOutcomeMessage(_ outcome: PutioBulkFileOutcome) -> String {
    let succeeded = outcome.succeeded.count
    let failed = outcome.failures.count
    if outcome.action == .delete {
      return deletionPresentation.outcomeMessage(succeeded: succeeded, failed: failed)
    }
    let successText = "Moved \(succeeded) \(itemNoun(succeeded))."
    guard failed > 0 else { return successText }
    return "\(successText) \(failed) couldn’t be moved."
  }

  private func itemNoun(_ count: Int) -> String {
    count == 1 ? "item" : "items"
  }

  private func successToast(for action: PutioFileAction) -> PutioToast {
    switch action {
    case .createFolder(let name):
      PutioToast(variant: .success, title: "Folder created", message: name)
    case .sort(_, let sort):
      PutioToast(
        variant: .success,
        title: "Sorting changed",
        message: sort.title
      )
    case .rename(_, _, let newName):
      PutioToast(variant: .success, title: "Item renamed", message: newName)
    case .delete(_, let name):
      PutioToast(
        variant: .success,
        title: deletionPresentation.singleSuccessTitle,
        message: name
      )
    case .move(_, let name, _, _, let destinationName):
      PutioToast(
        variant: .success,
        title: "Item moved",
        message: "\(name) to \(destinationName)"
      )
    case .setWatched(_, _, let name, let watched):
      PutioToast(
        variant: .success, title: watched ? "Marked as watched" : "Marked as unwatched",
        message: name)
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

  private enum FileEditor: Hashable, Identifiable {
    case createFolder
    case rename(PutioFileItem)

    var id: Self { self }
  }

  private enum FileActionRequest: Equatable {
    case createFolder(String)
    case sort(PutioFolderSort)
    case rename(PutioFileItem, String)
    case delete(PutioFileItem)
    case move(PutioFileItem, PutioFolderRoute)
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
