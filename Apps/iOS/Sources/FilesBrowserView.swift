import Foundation
import PutioCore
import SwiftUI

typealias PutioFileSelection = @MainActor @Sendable (PutioFileRoute) -> Void
typealias PutioRootLoaded = @MainActor @Sendable () -> Void

struct PutioFileDeletionPresentation: Equatable, Sendable {
  let trashEnabled: Bool

  var actionTitle: String {
    trashEnabled
      ? String(localized: "Trash", comment: "File action that moves an item to Trash")
      : String(localized: "Delete", comment: "File action that permanently deletes an item")
  }

  var singleSuccessTitle: String {
    trashEnabled
      ? String(localized: "Moved to Trash", comment: "File action success title")
      : String(localized: "Item deleted", comment: "Permanent file deletion success title")
  }

  var bulkSuccessTitle: String {
    trashEnabled
      ? String(localized: "Items moved to Trash", comment: "Bulk file action success title")
      : String(localized: "Items deleted", comment: "Bulk permanent deletion success title")
  }

  var singleFailureTitle: String {
    trashEnabled
      ? String(localized: "Could not move item to Trash", comment: "File action failure title")
      : String(localized: "Could not delete item", comment: "Permanent deletion failure title")
  }

  func confirmationTitle(itemName: String) -> String {
    if trashEnabled {
      return String(
        localized: "Move “\(itemName)” to Trash?",
        comment: "Confirmation title for moving one file to Trash"
      )
    }
    return String(
      localized: "Delete “\(itemName)” permanently?",
      comment: "Confirmation title for permanently deleting one file"
    )
  }

  func confirmationTitle(itemCount: Int) -> String {
    if trashEnabled {
      return String(
        localized: "Move \(itemCount) \(itemNoun(itemCount)) to Trash?",
        comment: "Confirmation title for moving selected files to Trash"
      )
    }
    return String(
      localized: "Delete \(itemCount) \(itemNoun(itemCount)) permanently?",
      comment: "Confirmation title for permanently deleting selected files"
    )
  }

  func confirmationMessage(itemCount: Int) -> String {
    if trashEnabled {
      return itemCount == 1
        ? String(localized: "You can restore this item from Trash.")
        : String(localized: "You can restore these items from Trash.")
    }
    return itemCount == 1
      ? String(localized: "This item cannot be restored.")
      : String(localized: "These items cannot be restored.")
  }

  func progressTitle(currentItem: Int, totalItems: Int) -> String {
    if trashEnabled {
      return String(
        localized: "Moving item \(currentItem) of \(totalItems) to Trash…",
        comment: "Progress title for a bulk Trash action"
      )
    }
    return String(
      localized: "Deleting item \(currentItem) of \(totalItems)…",
      comment: "Progress title for bulk permanent deletion"
    )
  }

  func failureTitle(allItemsFailed: Bool) -> String {
    switch (trashEnabled, allItemsFailed) {
    case (true, true):
      String(localized: "Could not move items to Trash")
    case (true, false):
      String(localized: "Some items couldn’t be moved to Trash")
    case (false, true):
      String(localized: "Could not delete items")
    case (false, false):
      String(localized: "Some items couldn’t be deleted")
    }
  }

  func outcomeMessage(succeeded: Int, failed: Int) -> String {
    let successText =
      trashEnabled
      ? String(localized: "Moved \(succeeded) \(itemNoun(succeeded)) to Trash.")
      : String(localized: "Deleted \(succeeded) \(itemNoun(succeeded)).")
    guard failed > 0 else { return successText }
    let failureText =
      trashEnabled
      ? String(localized: "\(failed) couldn’t be moved to Trash.")
      : String(localized: "\(failed) couldn’t be deleted.")
    return "\(successText) \(failureText)"
  }

  private func itemNoun(_ count: Int) -> String {
    count == 1 ? String(localized: "item") : String(localized: "items")
  }
}

@MainActor
struct FilesBrowserView: View {
  private let load: PutioFolderLoad
  private let actions: PutioFileActions?
  private let trashEnabled: Bool
  private let onFileSelected: PutioFileSelection
  private let onRootLoaded: PutioRootLoaded
  private let onReturnToRoot: @MainActor @Sendable () -> Void
  private let refreshRequests: PutioFolderRefreshRequests
  @State private var path: [PutioFolderRoute] = []

  init(
    runtime: PutioRuntime,
    trashEnabled: Bool,
    onFileSelected: @escaping PutioFileSelection,
    onRootLoaded: @escaping PutioRootLoaded = {},
    onReturnToRoot: @escaping @MainActor @Sendable () -> Void = {},
    refreshRequests: PutioFolderRefreshRequests = PutioFolderRefreshRequests()
  ) {
    load = { folderID in
      try await runtime.listFiles(parentID: folderID)
    }
    actions = PutioFileActions(runtime: runtime)
    self.trashEnabled = trashEnabled
    self.onFileSelected = onFileSelected
    self.onRootLoaded = onRootLoaded
    self.onReturnToRoot = onReturnToRoot
    self.refreshRequests = refreshRequests
  }

  init(
    load: @escaping PutioFolderLoad,
    actions: PutioFileActions? = nil,
    trashEnabled: Bool = true,
    onFileSelected: @escaping PutioFileSelection,
    onRootLoaded: @escaping PutioRootLoaded = {},
    onReturnToRoot: @escaping @MainActor @Sendable () -> Void = {},
    refreshRequests: PutioFolderRefreshRequests = PutioFolderRefreshRequests()
  ) {
    self.load = load
    self.actions = actions
    self.trashEnabled = trashEnabled
    self.onFileSelected = onFileSelected
    self.onRootLoaded = onRootLoaded
    self.onReturnToRoot = onReturnToRoot
    self.refreshRequests = refreshRequests
  }

  var body: some View {
    NavigationStack(path: $path) {
      PutioFolderScreen(
        route: .root,
        load: load,
        actions: actions,
        trashEnabled: trashEnabled,
        onLoaded: onRootLoaded,
        refreshRequests: refreshRequests,
        onFileSelected: onFileSelected
      )
      .navigationDestination(for: PutioFolderRoute.self) { route in
        PutioFolderScreen(
          route: route,
          load: load,
          actions: actions,
          trashEnabled: trashEnabled,
          refreshRequests: refreshRequests,
          onFileSelected: onFileSelected
        )
      }
    }
    .onChange(of: path) { oldPath, newPath in
      if !oldPath.isEmpty, newPath.isEmpty {
        onReturnToRoot()
      }
    }
  }
}

@MainActor
struct PutioFolderScreen: View {
  let route: PutioFolderRoute

  @State private var model: PutioFolderModel
  @State private var retryRequest: RetryRequest?
  @State private var retrySequence: UInt64 = 0
  @State private var reportedLoaded = false
  @State private var editor: FileEditor?
  @State private var editorName = ""
  @State private var pendingDeletion: PutioFileItem?
  @State private var pendingBulkDeletion: [PutioFileItem] = []
  @State private var pendingMove: MoveSelection?
  @State private var actionRequest: FileActionRequest?
  @State private var startedActionRequest: FileActionRequest?
  @State private var toast: PutioToast?
  @State private var selectedIDs: Set<PutioFileID> = []
  @State private var editMode: EditMode = .inactive
  private let relativeDateReference: Date?
  private let locale: Locale
  private let load: PutioFolderLoad
  private let trashEnabled: Bool
  private let onLoaded: @MainActor @Sendable () -> Void
  private let onFileSelected: PutioFileSelection
  private let refreshRequests: PutioFolderRefreshRequests

  init(
    route: PutioFolderRoute,
    load: @escaping PutioFolderLoad,
    actions: PutioFileActions? = nil,
    trashEnabled: Bool = true,
    initialContents: PutioFolderContents? = nil,
    relativeTo relativeDateReference: Date? = nil,
    locale: Locale = .current,
    onLoaded: @escaping @MainActor @Sendable () -> Void = {},
    refreshRequests: PutioFolderRefreshRequests = PutioFolderRefreshRequests(),
    onFileSelected: @escaping PutioFileSelection
  ) {
    self.route = route
    _model = State(
      initialValue: PutioFolderModel(
        folderID: route.id,
        load: load,
        actions: actions,
        initialContents: initialContents
      )
    )
    self.relativeDateReference = relativeDateReference
    self.locale = locale
    self.load = load
    self.trashEnabled = trashEnabled
    self.onLoaded = onLoaded
    self.refreshRequests = refreshRequests
    self.onFileSelected = onFileSelected
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
    .navigationTitle(route.title)
    .navigationBarBackButtonHidden(fileActionPending)
    .putioContentBackground()
    .toolbar {
      if model.supportsActions, !currentItems.isEmpty || isEditing {
        ToolbarItemGroup(placement: .primaryAction) {
          if !isEditing {
            Button("New Folder") {
              editorName = ""
              editor = .createFolder
            }
            .disabled(!model.canStartAction || actionRequest != nil)
            .accessibilityIdentifier("files.new-folder")
          }
          EditButton()
            .disabled(fileActionPending)
            .accessibilityIdentifier("files.selection.toggle")
        }
      } else if model.supportsActions {
        ToolbarItem(placement: .primaryAction) {
          Button("New Folder") {
            editorName = ""
            editor = .createFolder
          }
          .disabled(!model.canStartAction || actionRequest != nil)
          .accessibilityIdentifier("files.new-folder")
        }
      }
      if model.supportsActions, isEditing, !currentItems.isEmpty {
        ToolbarItemGroup(placement: .bottomBar) {
          Button(allLoadedItemsAreSelected ? "Deselect All" : "Select All") {
            toggleAllLoadedItems()
          }
          .disabled(fileActionPending)
          .accessibilityIdentifier(
            allLoadedItemsAreSelected
              ? "files.selection.deselect-all" : "files.selection.select-all"
          )
          Button("Move") {
            let items = selectedItems
            guard !items.isEmpty else { return }
            pendingMove = MoveSelection(items: items, isBulk: true)
          }
          .disabled(selectedItems.isEmpty || fileActionPending)
          .accessibilityIdentifier("files.bulk.move")
          Button(deleteActionTitle, role: .destructive) {
            pendingBulkDeletion = selectedItems
          }
          .disabled(selectedItems.isEmpty || fileActionPending)
          .accessibilityIdentifier("files.bulk.remove")
        }
      }
    }
    .modifier(PutioSelectionTabBarVisibility(isEditing: isEditing))
    .environment(\.editMode, $editMode)
    .sheet(isPresented: editorPresented) {
      NavigationStack {
        Form {
          TextField("Name", text: $editorName)
            .accessibilityIdentifier("files.action-name")
        }
        .navigationTitle(editorTitle)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
          ToolbarItem(placement: .cancellationAction) {
            Button("Cancel", role: .cancel) {
              editor = nil
            }
          }
          ToolbarItem(placement: .confirmationAction) {
            Button(editorSubmitTitle) {
              submitEditor()
            }
            .disabled(!editorNameIsValid)
            .accessibilityIdentifier("files.action-submit")
          }
        }
      }
      .presentationDetents([.height(220)])
    }
    .sheet(item: $pendingMove) { selection in
      PutioMovePicker(
        items: selection.items,
        load: load,
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
        retryBulkFailures(outcome)
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
      await model.loadIfNeeded()
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
    .task(id: refreshRequests.sequence(for: route.id)) {
      guard refreshRequests.sequence(for: route.id) != nil else { return }
      _ = await model.refresh()
    }
    .onChange(of: model.state, initial: true) { _, state in
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
    if contents.items.isEmpty {
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
        .containerRelativeFrame([.horizontal, .vertical])
        .padding(PutioTheme.Spacing.space4)
      }
      .refreshable {
        _ = await model.refresh()
      }
      .accessibilityIdentifier("files.screen.\(route.id.rawValue)")
    } else {
      List(selection: isEditing && !fileActionPending ? $selectedIDs : nil) {
        ForEach(
          contents.items.map {
            PutioBrowserItemPresentation(
              item: $0,
              relativeTo: relativeDateReference ?? .now,
              locale: locale
            )
          }
        ) { item in
          row(item)
            .tag(item.id)
            .listRowBackground(PutioTheme.Colors.background)
        }

        if contents.hasMore {
          Section {
          } footer: {
            Text("More files are available in this folder.")
              .putioFont(PutioTheme.Typography.caption)
              .foregroundStyle(PutioTheme.Colors.textSecondary)
              .accessibilityIdentifier("files.more.\(route.id.rawValue)")
          }
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
      PutioFileRow(
        presentation.row,
        showsFolderDisclosure: false
      )
      .contentShape(Rectangle())
      .accessibilityElement(children: .combine)
      .accessibilityIdentifier("files.item.\(presentation.id.rawValue)")
      .accessibilityValue(Text(selectionAccessibilityValue(for: presentation.item)))
    } else if let folderRoute = presentation.folderRoute {
      fileActions(
        for: presentation.item,
        content: NavigationLink(value: folderRoute) {
          PutioFileRow(presentation.row, showsFolderDisclosure: false)
        }
        .disabled(fileActionPending)
        .accessibilityIdentifier("files.item.\(presentation.id.rawValue)")
      )
    } else if let fileRoute = presentation.fileRoute {
      if fileRoute.videoPlaybackRoute != nil {
        fileActions(
          for: presentation.item,
          content: Button {
            onFileSelected(fileRoute)
          } label: {
            PutioFileRow(presentation.row)
          }
          .buttonStyle(.plain)
          .disabled(fileActionPending)
          .accessibilityIdentifier("files.item.\(presentation.id.rawValue)")
          .accessibilityValue(Text(videoAccessibilityValue(for: presentation.item)))
        )
      } else {
        fileActions(
          for: presentation.item,
          content: PutioFileRow(presentation.row)
            .accessibilityIdentifier("files.item.\(presentation.id.rawValue)")
        )
      }
    }
  }

  private func fileActions<Content: View>(
    for item: PutioFileItem,
    content: Content
  ) -> some View {
    HStack(spacing: PutioTheme.Spacing.space2) {
      content
        .frame(maxWidth: .infinity, alignment: .leading)
      if model.supportsActions {
        Menu {
          actionButtons(for: item)
        } label: {
          PutioIconView(.dotsThreeCircle, size: PutioTheme.ScaledMetrics.buttonIconSize)
            .frame(minWidth: 44, minHeight: 44)
            .contentShape(Rectangle())
        }
        .accessibilityLabel(Text("More actions for \(item.name)"))
        .accessibilityIdentifier("files.actions.\(item.id.rawValue)")
        .disabled(!model.canStartAction || actionRequest != nil)
      }
    }
    .contextMenu {
      actionButtons(for: item)
    }
    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
      actionButtons(for: item)
    }
  }

  @ViewBuilder
  private func actionButtons(for item: PutioFileItem) -> some View {
    if model.supportsActions {
      Button("Move") {
        pendingMove = MoveSelection(items: [item], isBulk: false)
      }
      .disabled(!model.canStartAction || actionRequest != nil)
      .accessibilityIdentifier("files.move.\(item.id.rawValue)")
      Button("Rename") {
        editorName = item.name
        editor = .rename(item)
      }
      .disabled(!model.canStartAction || actionRequest != nil)
      .accessibilityIdentifier("files.rename.\(item.id.rawValue)")
      Button(deleteActionTitle, role: .destructive) {
        pendingDeletion = item
      }
      .disabled(!model.canStartAction || actionRequest != nil)
      .accessibilityIdentifier("files.delete.\(item.id.rawValue)")
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

  private func videoAccessibilityValue(for item: PutioFileItem) -> String {
    guard item.isWatched else { return "Not watched" }
    return "Watched, resume position \(item.resumePositionSeconds) seconds"
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
      await model.retry()
    case .refresh:
      guard model.refreshFailure != nil else {
        retryRequest = nil
        return
      }
      _ = await model.refresh()
    }
    guard retryRequest == request else { return }
    retryRequest = nil
  }

  private var editorPresented: Binding<Bool> {
    Binding(
      get: { editor != nil },
      set: { isPresented in
        if !isPresented { editor = nil }
      }
    )
  }

  private var deleteConfirmationPresented: Binding<Bool> {
    Binding(
      get: { pendingDeletion != nil },
      set: { isPresented in
        if !isPresented { pendingDeletion = nil }
      }
    )
  }

  private var editorTitle: String {
    switch editor {
    case .createFolder: "New Folder"
    case .rename: "Rename Item"
    case nil: "Edit Item"
    }
  }

  private var editorSubmitTitle: String {
    switch editor {
    case .createFolder: "Create"
    case .rename: "Rename"
    case nil: "Save"
    }
  }

  private var editorNameIsValid: Bool {
    let name = editorName.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !name.isEmpty else { return false }
    guard case .rename(let item) = editor else { return true }
    return name != item.name
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

  private func submitEditor() {
    guard editorNameIsValid, let editor else { return }
    switch editor {
    case .createFolder:
      actionRequest = .createFolder(editorName)
    case .rename(let item):
      actionRequest = .rename(item, editorName)
    }
    self.editor = nil
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
    actionRequest = nil
    startedActionRequest = nil
    selectedIDs.formIntersection(currentItems.map(\.id))
    presentActionOutcome()
    presentBulkOutcome()
  }

  private func presentActionOutcome() {
    guard let outcome = model.actionOutcome else { return }
    switch outcome {
    case .succeeded(let action):
      if case .move(_, _, _, let destinationID, _) = action {
        refreshRequests.request(folderID: destinationID)
      }
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
    if case .move(let destination) = outcome.action {
      refreshRequests.request(folderID: destination.id)
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

  private func retryBulkFailures(_ outcome: PutioBulkFileOutcome) {
    actionRequest = .bulkRetry(outcome)
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

  private enum FileEditor: Equatable {
    case createFolder
    case rename(PutioFileItem)
  }

  private enum FileActionRequest: Equatable {
    case createFolder(String)
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

@MainActor
private struct PutioMovePicker: View {
  let items: [PutioFileItem]
  let load: PutioFolderLoad
  let onMove: @MainActor (PutioFolderRoute) -> Void

  @Environment(\.dismiss) private var dismiss
  @State private var path: [PutioFolderRoute] = []

  var body: some View {
    NavigationStack(path: $path) {
      PutioMoveDestinationScreen(route: .root, items: items, load: load, onMove: onMove)
        .navigationDestination(for: PutioFolderRoute.self) { route in
          PutioMoveDestinationScreen(route: route, items: items, load: load, onMove: onMove)
        }
    }
    .toolbar {
      ToolbarItem(placement: .cancellationAction) {
        Button("Cancel", role: .cancel) {
          dismiss()
        }
        .accessibilityIdentifier("files.move-cancel")
      }
    }
    .accessibilityIdentifier("files.move-picker")
  }
}

@MainActor
private struct PutioMoveDestinationScreen: View {
  let route: PutioFolderRoute
  let items: [PutioFileItem]
  let onMove: @MainActor (PutioFolderRoute) -> Void

  @State private var model: PutioFolderModel

  init(
    route: PutioFolderRoute,
    items: [PutioFileItem],
    load: @escaping PutioFolderLoad,
    onMove: @escaping @MainActor (PutioFolderRoute) -> Void
  ) {
    self.route = route
    self.items = items
    self.onMove = onMove
    _model = State(initialValue: PutioFolderModel(folderID: route.id, load: load))
  }

  var body: some View {
    Group {
      switch model.state {
      case .loading:
        PutioLoadingStateView(title: "Loading folders")
      case .failed(let failure):
        PutioErrorStateView(
          title: failure.title,
          message: failure.message,
          retryTitle: "Try again"
        ) {
          Task { await model.retry() }
        }
      case .loaded(let contents):
        destinationList(contents)
      }
    }
    .navigationTitle(route.title)
    .navigationBarTitleDisplayMode(.inline)
    .putioContentBackground()
    .toolbar {
      ToolbarItem(placement: .confirmationAction) {
        Button("Move Here") {
          onMove(route)
        }
        .disabled(!canMoveHere)
        .accessibilityIdentifier("files.move-here.\(route.id.rawValue)")
      }
    }
    .task(id: route.id) {
      await model.loadIfNeeded()
    }
    .accessibilityIdentifier("files.move-screen.\(route.id.rawValue)")
  }

  @ViewBuilder
  private func destinationList(_ contents: PutioFolderContents) -> some View {
    let folders = policy.folders(in: contents)
    if folders.isEmpty {
      PutioEmptyStateView(
        icon: .folderFill,
        title: "No folders here",
        message: canMoveHere ? emptyDestinationMessage : "Choose another folder."
      )
    } else {
      List(folders) { folder in
        NavigationLink(value: PutioFolderRoute(id: folder.id, title: folder.name)) {
          PutioFileRow(
            PutioBrowserItemPresentation(item: folder).row,
            showsFolderDisclosure: false
          )
        }
        .accessibilityIdentifier("files.move-folder.\(folder.id.rawValue)")
        .listRowBackground(PutioTheme.Colors.background)
      }
      .listStyle(.plain)
    }
  }

  private var emptyDestinationMessage: String {
    items.count == 1
      ? "Move this item here or go back."
      : "Move the selected items here or go back."
  }

  private var canMoveHere: Bool {
    policy.canMove(to: route)
  }

  private var policy: PutioMovePickerPolicy {
    PutioMovePickerPolicy(items: items)
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

private struct PutioSelectionTabBarVisibility: ViewModifier {
  let isEditing: Bool

  @ViewBuilder func body(content: Content) -> some View {
    if isEditing {
      content.toolbar(.hidden, for: .tabBar)
    } else {
      content
    }
  }
}
