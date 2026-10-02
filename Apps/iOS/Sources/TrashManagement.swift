import Observation
import PutioCore
import SwiftUI

struct TrashManagementView: View {
  @State private var model: PutioTrashModel
  @State private var pendingDeletion: PutioTrashItem?
  @State private var pendingBulkDeletion: [PutioTrashItem] = []
  @State private var emptyConfirmationPresented = false
  @State private var toast: PutioToast?
  @State private var selectedIDs: Set<PutioFileID> = []
  @State private var editMode: EditMode = .inactive

  init(
    runtime: PutioRuntime,
    reconciliation: PutioTrashReconciliation,
    onRestored: @escaping PutioTrashDidRestore
  ) {
    _model = State(
      initialValue: PutioTrashModel(
        runtime: runtime, reconciliation: reconciliation, onRestored: onRestored))
  }

  init(
    actions: PutioTrashActions,
    onRestored: @escaping PutioTrashDidRestore = { _ in }
  ) {
    _model = State(initialValue: PutioTrashModel(actions: actions, onRestored: onRestored))
  }

  var body: some View {
    Group {
      switch model.state {
      case .loading:
        PutioLoadingStateView(title: "Loading Trash")
      case .failed(let failure):
        PutioErrorStateView(
          title: failure.title,
          message: failure.message,
          retryTitle: "Try again"
        ) {
          Task { await model.refresh() }
        }
      case .loaded(let page):
        loadedContent(page)
      }
    }
    .navigationTitle("Trash")
    .putioContentBackground()
    .navigationBarBackButtonHidden(isEditing)
    .toolbar {
      if isEditing {
        ToolbarItem(placement: .topBarLeading) {
          Button(allLoadedItemsAreSelected ? "Deselect All" : "Select All") {
            selectedIDs = allLoadedItemsAreSelected ? [] : Set(loadedItems.map(\.id))
          }
          .disabled(loadedItems.isEmpty)
          .accessibilityIdentifier(
            allLoadedItemsAreSelected
              ? "trash.selection.deselect-all" : "trash.selection.select-all")
        }
        ToolbarItem(placement: .principal) {
          Text("Select Items")
        }
        ToolbarItem(placement: .confirmationAction) {
          Button("Done") { editMode = .inactive }
            .accessibilityIdentifier("trash.selection.done")
        }
        ToolbarItemGroup(placement: .bottomBar) {
          Button("Restore") {
            let items = selectedItems
            Task { await model.restore(items) }
          }
          .disabled(selectedItems.isEmpty || !model.canMutate)
          .accessibilityIdentifier("trash.bulk.restore")
          Spacer()
          Button("Delete", role: .destructive) { pendingBulkDeletion = selectedItems }
            .disabled(selectedItems.isEmpty || !model.canMutate)
            .accessibilityIdentifier("trash.bulk.delete")
        }
      } else if model.hasContents {
        ToolbarItem(placement: .primaryAction) {
          Menu {
            Button {
              editMode = .active
            } label: {
              Label("Select", systemImage: "checkmark.circle")
            }
            .disabled(loadedItems.isEmpty)
            .accessibilityIdentifier("trash.select")
            Button {
              Task { await model.restoreAll() }
            } label: {
              Label("Restore All", systemImage: "arrow.uturn.backward")
            }
            .accessibilityIdentifier("trash.restore-all")
            Button(role: .destructive) {
              emptyConfirmationPresented = true
            } label: {
              Label("Empty Trash", systemImage: "trash")
            }
            .accessibilityIdentifier("trash.empty")
          } label: {
            Label("Trash Actions", systemImage: "ellipsis.circle")
          }
          .disabled(!model.canMutate)
          .accessibilityLabel("Trash Actions")
          .accessibilityIdentifier("trash.menu")
        }
      }
    }
    .modifier(PutioSelectionTabBarVisibility(isEditing: isEditing))
    .environment(\.editMode, $editMode)
    .confirmationDialog(
      deletionConfirmationTitle,
      isPresented: deletionConfirmationPresented,
      titleVisibility: .visible
    ) {
      Button("Delete Permanently", role: .destructive) {
        guard let item = pendingDeletion else { return }
        pendingDeletion = nil
        // Another screen may have removed this row while the dialog was up.
        guard model.page?.items.contains(item) == true else { return }
        Task { await model.permanentlyDelete(item) }
      }
      .accessibilityIdentifier("trash.delete-confirm")
      Button("Cancel", role: .cancel) { pendingDeletion = nil }
    } message: {
      Text("This item cannot be restored.")
    }
    .confirmationDialog(
      "Delete \(pendingBulkDeletion.count) \(pendingBulkDeletion.count == 1 ? "item" : "items") permanently?",
      isPresented: bulkDeletionConfirmationPresented,
      titleVisibility: .visible
    ) {
      Button("Delete Permanently", role: .destructive) {
        let items = pendingBulkDeletion.filter { model.page?.items.contains($0) == true }
        pendingBulkDeletion = []
        Task { await model.permanentlyDelete(items) }
      }
      .accessibilityIdentifier("trash.bulk.delete-confirm")
      Button("Cancel", role: .cancel) { pendingBulkDeletion = [] }
    } message: {
      Text("Are you sure to permanently delete those files?")
    }
    .confirmationDialog(
      "Empty Trash permanently?",
      isPresented: $emptyConfirmationPresented,
      titleVisibility: .visible
    ) {
      Button("Empty Trash", role: .destructive) {
        Task { await model.empty() }
      }
      .accessibilityIdentifier("trash.empty-confirm")
      Button("Cancel", role: .cancel) {}
    } message: {
      Text("Every item in Trash will be deleted and cannot be restored.")
    }
    .putioToast($toast)
    .overlay {
      if model.activeMutation != nil {
        ProgressView("Updating Trash…")
          .controlSize(.large)
          .padding(PutioTheme.Spacing.space4)
          .glassEffect()
          .accessibilityElement(children: .combine)
          .accessibilityLabel("Updating Trash")
          .accessibilityIdentifier("trash.progress")
      }
    }
    .task { await model.refreshOnAppear() }
    .onDisappear { model.abandonListing() }
    .onChange(of: model.reconciliationVersion) { _, _ in
      Task {
        await model.applyReconciliation()
        // Confirmations for rows another screen has since removed are moot.
        if let pending = pendingDeletion, model.page?.items.contains(pending) != true {
          pendingDeletion = nil
        }
        pendingBulkDeletion.removeAll { model.page?.items.contains($0) != true }
        if !model.hasContents { emptyConfirmationPresented = false }
      }
    }
    .onChange(of: model.mutationOutcome) { _, outcome in
      present(outcome)
    }
    .onChange(of: model.page) { _, page in
      selectedIDs.formIntersection(page?.items.map(\.id) ?? [])
      if page?.items.isEmpty != false { editMode = .inactive }
    }
    .onChange(of: editMode) { _, mode in
      if mode != .active { selectedIDs = [] }
    }
    .task(id: toast) {
      guard let presentedToast = toast else { return }
      try? await Task.sleep(for: .seconds(3))
      guard !Task.isCancelled, toast == presentedToast else { return }
      toast = nil
    }
  }

  @ViewBuilder
  private func loadedContent(_ page: PutioTrashPage) -> some View {
    let isEmpty = page.items.isEmpty && page.nextCursor == nil
    if isEmpty && model.refreshFailure == nil && model.storageFailure == nil {
      ScrollView {
        emptyState.containerRelativeFrame([.horizontal, .vertical])
      }
      .refreshable { await model.refresh() }
    } else {
      List(selection: isEditing ? $selectedIDs : nil) {
        if !page.items.isEmpty {
          Section {
            Text("Heads up: Files in trash have an expiry date of 14 days.")
              .putioFont(PutioTheme.Typography.caption)
              .foregroundStyle(PutioTheme.Colors.textSecondary)
              .accessibilityIdentifier("trash.expiry-notice")
          }
          .listRowBackground(Color.clear)
        }
        if let failure = model.refreshFailure {
          Section {
            PutioErrorStateView(
              title: failure.title,
              message: failure.message,
              retryTitle: "Try again"
            ) {
              Task { await model.refresh() }
            }
          }
        }
        storageFailureSection
        if isEmpty {
          // The page is still empty; errors above do not change that.
          Section { emptyState }.listRowBackground(Color.clear)
        }
        ForEach(page.items) { item in
          HStack {
            PutioFileRow(rowModel(for: item))
            if !isEditing {
              Menu {
                Button("Restore") {
                  Task { await model.restore(item) }
                }
                .accessibilityIdentifier("trash.restore.\(item.id.rawValue)")
                Button("Delete Permanently", role: .destructive) {
                  pendingDeletion = item
                }
                .accessibilityIdentifier("trash.delete.\(item.id.rawValue)")
              } label: {
                PutioIconView(.dotsThreeCircle, size: PutioTheme.ScaledMetrics.buttonIconSize)
                  .foregroundStyle(PutioTheme.Colors.accent)
                  .frame(minWidth: 44, minHeight: 44)
                  .contentShape(Rectangle())
              }
              .disabled(!model.canMutate)
              .accessibilityLabel("More actions for \(item.name)")
              .accessibilityIdentifier("trash.item.\(item.id.rawValue).actions")
            }
          }
          .tag(item.id)
          .listRowBackground(PutioTheme.Colors.surface)
          .swipeActions(edge: .leading) {
            Button("Restore") {
              Task { await model.restore(item) }
            }
            .disabled(!model.canMutate)
            .tint(PutioTheme.Colors.success)
          }
          .swipeActions(edge: .trailing) {
            Button("Delete", role: .destructive) { pendingDeletion = item }
              .disabled(!model.canMutate)
          }
        }
        if let cursor = page.nextCursor {
          if let failure = model.paginationFailure {
            Section {
              PutioErrorStateView(
                title: failure.title,
                message: failure.message,
                retryTitle: "Try again"
              ) {
                Task { await model.loadMore() }
              }
            }
          } else {
            HStack {
              Spacer()
              ProgressView()
              Spacer()
            }
            .listRowBackground(Color.clear)
            .accessibilityLabel("Loading more Trash items")
            .accessibilityIdentifier("trash.load-more")
            // Re-keyed when blocking work settles, so a page the model
            // refused while busy is requested again. Its own load is not part
            // of the key, so starting it cannot cancel it.
            .task(id: PageRequest(cursor: cursor, isBusy: isBusyOutsidePaging)) {
              guard !isBusyOutsidePaging else { return }
              await model.loadMore()
            }
          }
        }
      }
      .refreshable { await model.refresh() }
      .accessibilityIdentifier("trash.list")
    }
  }

  private struct PageRequest: Equatable {
    let cursor: String
    let isBusy: Bool
  }

  private var isBusyOutsidePaging: Bool {
    model.activeMutation != nil || model.isRefreshing || model.isRefreshingStorage
  }

  private var isEditing: Bool { editMode == .active }

  private var loadedItems: [PutioTrashItem] { model.page?.items ?? [] }

  private var selectedItems: [PutioTrashItem] {
    loadedItems.filter { selectedIDs.contains($0.id) }
  }

  private var allLoadedItemsAreSelected: Bool {
    !loadedItems.isEmpty && selectedIDs == Set(loadedItems.map(\.id))
  }

  private var bulkDeletionConfirmationPresented: Binding<Bool> {
    Binding(
      get: { !pendingBulkDeletion.isEmpty },
      set: { if !$0 { pendingBulkDeletion = [] } }
    )
  }

  private var deletionConfirmationPresented: Binding<Bool> {
    Binding(
      get: { pendingDeletion != nil },
      set: { if !$0 { pendingDeletion = nil } }
    )
  }

  private var deletionConfirmationTitle: String {
    guard let pendingDeletion else { return "Delete permanently?" }
    return "Delete “\(pendingDeletion.name)” permanently?"
  }

  private var emptyState: some View {
    PutioEmptyStateView(
      icon: .trash,
      title: "Trash is empty",
      message: "When you send files to trash, we keep them here for 14 days."
    )
  }

  @ViewBuilder
  private var storageFailureSection: some View {
    if let failure = model.storageFailure {
      Section {
        PutioErrorStateView(
          title: failure.title,
          message: failure.message,
          retryTitle: model.isRefreshingStorage ? "Updating…" : "Update storage"
        ) {
          Task { await model.retryStorageRefresh() }
        }
        .disabled(model.isRefreshingStorage)
        .accessibilityIdentifier("trash.storage-retry")
      }
    }
  }

  private func rowModel(for item: PutioTrashItem) -> PutioFileRowModel {
    Self.rowModel(for: item)
  }

  static func rowModel(
    for item: PutioTrashItem, relativeTo now: Date = .now, locale: Locale = .current
  ) -> PutioFileRowModel {
    let size = PutioFileRowModel.sizeText(bytes: item.sizeBytes, locale: locale)
    let deleted = PutioBrowserItemPresentation.relativeDateText(
      for: item.deletedAt, relativeTo: now, locale: locale)
    let expires = item.expiresAt.formatted(
      Date.FormatStyle(locale: locale).month(.wide).day())
    return PutioFileRowModel(
      name: item.name,
      kind: rowKind(for: item.kind),
      sizeText: "\(size) · Deleted \(deleted)",
      secondaryText: "Expires on \(expires)"
    )
  }

  private static func rowKind(for kind: PutioFileKind) -> PutioFileRowModel.Kind {
    switch kind {
    case .folder: .folder
    case .video: .video
    case .audio: .audio
    case .image: .image
    case .pdf, .other: .file
    }
  }

  private static let staleStorageMessage =
    "Storage totals could not be updated. Use Update storage to retry."

  private func present(_ outcome: PutioTrashMutationOutcome?) {
    guard let outcome else { return }
    switch outcome {
    case .restored(let item):
      toast = PutioToast(variant: .success, title: "Item restored", message: item.name)
    case .permanentlyDeleted(let item, let storageRefreshed):
      toast = PutioToast(
        variant: storageRefreshed ? .success : .info,
        title: "Item deleted",
        message: storageRefreshed ? item.name : Self.staleStorageMessage
      )
    case .restoredItems(let items):
      toast = PutioToast(
        variant: .success, title: "Items restored",
        message: "Restored \(items.count) \(items.count == 1 ? "item" : "items").")
    case .permanentlyDeletedItems(let items, let storageRefreshed):
      toast = PutioToast(
        variant: storageRefreshed ? .success : .info,
        title: "Items deleted",
        message: storageRefreshed
          ? "Deleted \(items.count) \(items.count == 1 ? "item" : "items")."
          : Self.staleStorageMessage
      )
    case .restoredAll:
      toast = PutioToast(
        variant: .success, title: "Restore started!",
        message: "It may take a long time if there are too many files.")
    case .emptied(let storageRefreshed):
      toast = PutioToast(
        variant: storageRefreshed ? .success : .info,
        title: "Trash emptied",
        message: storageRefreshed ? nil : Self.staleStorageMessage
      )
    case .failed(_, let failure):
      toast = PutioToast(variant: .danger, title: failure.title, message: failure.message)
    }
    model.clearMutationOutcome()
  }
}
