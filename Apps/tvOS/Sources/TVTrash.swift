import PutioCore
import SwiftUI

enum TVTrashPresentation {
  static func row(
    _ item: PutioTrashItem, now: Date, locale: Locale = .current
  ) -> PutioFileRowModel {
    let size = PutioFileRowModel.sizeText(bytes: item.sizeBytes, locale: locale)
    let deleted = PutioBrowserItemPresentation.relativeDateText(
      for: item.deletedAt, relativeTo: now, locale: locale)
    let expires = item.expiresAt.formatted(Date.FormatStyle(locale: locale).month(.wide).day())
    return PutioFileRowModel(
      name: item.name,
      kind: PutioBrowserItemPresentation.rowKind(for: item.kind),
      sizeText: "\(size) · Deleted \(deleted)",
      secondaryText: "Expires on \(expires)",
      showsDisclosure: false
    )
  }

  static func toast(for outcome: PutioTrashMutationOutcome) -> PutioToast {
    switch outcome {
    case .restored(let item):
      PutioToast(variant: .success, title: "Item restored", message: item.name)
    case .permanentlyDeleted(let item, let storageRefreshed):
      PutioToast(
        variant: storageRefreshed ? .success : .info, title: "Item deleted",
        message: storageRefreshed ? item.name : staleStorageMessage)
    case .restoredItems(let items):
      PutioToast(
        variant: .success, title: "Items restored", message: "Restored \(items.count) items.")
    case .permanentlyDeletedItems(let items, let storageRefreshed):
      PutioToast(
        variant: storageRefreshed ? .success : .info, title: "Items deleted",
        message: storageRefreshed ? "Deleted \(items.count) items." : staleStorageMessage)
    case .restoredAll:
      PutioToast(
        variant: .success, title: "Restore started!",
        message: "It may take a long time if there are too many files.")
    case .emptied(let storageRefreshed):
      PutioToast(
        variant: storageRefreshed ? .success : .info, title: "Trash emptied",
        message: storageRefreshed ? nil : staleStorageMessage)
    case .failed(_, let failure):
      PutioToast(variant: .danger, title: failure.title, message: failure.message)
    }
  }

  private static let staleStorageMessage =
    "Storage totals could not be updated. Use Update storage to retry."
}

struct TVTrashView: View {
  @State private var model: PutioTrashModel
  @State private var now: Date
  @State private var selectedItem: PutioTrashItem?
  @State private var confirmsEmpty = false
  @State private var toast: PutioToast?
  private let locale: Locale
  private let loadsOnAppear: Bool

  init(runtime: PutioRuntime, reconciliation: PutioTrashReconciliation) {
    self.init(model: Self.model(runtime: runtime, reconciliation: reconciliation))
  }

  static func model(
    runtime: PutioRuntime, reconciliation: PutioTrashReconciliation
  ) -> PutioTrashModel {
    // Restores never reload account storage, and one can commit after Trash
    // is gone; Account's trash size must still follow it.
    PutioTrashModel(runtime: runtime, reconciliation: reconciliation) { _ in
      Task { await runtime.refreshAccount() }
    }
  }

  /// `loadsOnAppear: false` keeps an already loaded model as it is, for
  /// rendering a fixed state.
  init(
    model: PutioTrashModel, now: Date = .now, locale: Locale = .current,
    loadsOnAppear: Bool = true
  ) {
    _model = State(initialValue: model)
    _now = State(initialValue: now)
    self.locale = locale
    self.loadsOnAppear = loadsOnAppear
  }

  var body: some View {
    VStack(alignment: .leading, spacing: PutioTheme.TV.Spacing.medium) {
      TVScreenHeader(title: "Trash") {
        if model.hasContents {
          PutioButton("Restore all", tier: .secondary) {
            Task { await model.restoreAll() }
          }
          .disabled(!model.canMutate)
          .accessibilityIdentifier("trash.restore-all")
          PutioButton("Empty", tier: .secondary) { confirmsEmpty = true }
            .disabled(!model.canMutate)
            .accessibilityIdentifier("trash.empty")
        }
      }
      content
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    .tvOverscanPadding()
    .background(PutioTheme.Colors.background.ignoresSafeArea())
    // The item-bound alert overload needs the Xcode 27 SDK; CI builds with 26.
    .alert(
      selectedItem?.name ?? "",
      isPresented: Binding(
        get: { selectedItem != nil }, set: { if !$0 { selectedItem = nil } }),
      presenting: selectedItem
    ) { item in
      Button("Restore") { mutate(item) { await model.restore(item) } }
        .accessibilityIdentifier("trash.item-restore")
      Button("Delete permanently", role: .destructive) {
        mutate(item) { await model.permanentlyDelete(item) }
      }
      .accessibilityIdentifier("trash.item-delete")
      Button("Cancel", role: .cancel) {}
    } message: { _ in
      Text(
        "Restore it to where it was, or delete it permanently. Deleted items cannot be restored.")
    }
    .alert("Empty Trash permanently?", isPresented: $confirmsEmpty) {
      Button("Empty Trash", role: .destructive) { Task { await model.empty() } }
        .accessibilityIdentifier("trash.empty-confirm")
      Button("Cancel", role: .cancel) {}
    } message: {
      Text("Every item in Trash will be deleted and cannot be restored.")
    }
    .putioToast($toast)
    .overlay {
      if model.activeMutation != nil {
        ProgressView("Updating Trash…")
          .padding(PutioTheme.TV.Spacing.medium)
          .background(
            PutioTheme.Colors.surface,
            in: RoundedRectangle(cornerRadius: PutioTheme.TV.radius, style: .continuous)
          )
          .accessibilityIdentifier("trash.progress")
      }
    }
    .task { if loadsOnAppear { await model.refreshOnAppear() } }
    .onAppear { if loadsOnAppear { now = .now } }
    .onDisappear { model.abandonListing() }
    .onChange(of: model.reconciliationVersion) { _, _ in
      Task {
        await model.applyReconciliation()
        // A modal for a row another screen has since removed is moot.
        if let selectedItem, model.page?.items.contains(selectedItem) != true {
          self.selectedItem = nil
        }
        if !model.hasContents { confirmsEmpty = false }
      }
    }
    .onChange(of: model.mutationOutcome) { _, outcome in
      guard let outcome else { return }
      toast = TVTrashPresentation.toast(for: outcome)
      model.clearMutationOutcome()
    }
    .task(id: toast) {
      guard let presented = toast else { return }
      try? await Task.sleep(for: .seconds(3))
      guard !Task.isCancelled, toast == presented else { return }
      toast = nil
    }
  }

  /// Another screen may have removed the row while its modal was up.
  private func mutate(_ item: PutioTrashItem, _ operation: @escaping @MainActor () async -> Void) {
    guard model.page?.items.contains(item) == true else { return }
    Task { await operation() }
  }

  @ViewBuilder
  private var content: some View {
    switch model.state {
    case .loading:
      PutioLoadingStateView(title: "Loading Trash")
    case .failed(let failure):
      PutioErrorStateView(
        title: failure.title, message: failure.message, retryTitle: "Try again",
        retryIdentifier: "trash.retry"
      ) {
        Task { await model.refresh() }
      }
    case .loaded(let page):
      let isEmpty = page.items.isEmpty && page.nextCursor == nil
      if isEmpty, model.refreshFailure == nil, model.storageFailure == nil {
        emptyState
      } else {
        list(page, isEmpty: isEmpty)
      }
    }
  }

  private var emptyState: some View {
    PutioEmptyStateView(
      icon: .trash, title: "Your trash is empty",
      message: "When you send files to trash, we keep them here for 14 days."
    )
    .accessibilityIdentifier("trash.empty-state")
  }

  private func list(_ page: PutioTrashPage, isEmpty: Bool) -> some View {
    TVRowList {
      if let failure = model.refreshFailure {
        TVRetrySection(
          message: "\(failure.title). \(failure.message)", identifier: "trash.refresh-retry"
        ) {
          await model.refresh()
        }
      }
      if let failure = model.storageFailure {
        TVRetrySection(
          message: "\(failure.title). \(failure.message)", identifier: "trash.storage-retry",
          retryTitle: model.isRefreshingStorage ? "Updating…" : "Update storage"
        ) {
          await model.retryStorageRefresh()
        }
      }
      if isEmpty {
        emptyState
      } else if !page.items.isEmpty {
        Text("Heads up: Files in trash have an expiry date of 14 days.")
          .putioFont(PutioTheme.TV.Typography.caption)
          .foregroundStyle(PutioTheme.TV.Colors.textSecondary)
          .accessibilityIdentifier("trash.expiry-notice")
        ForEach(page.items) { item in
          Button {
            selectedItem = item
          } label: {
            PutioFileRow(TVTrashPresentation.row(item, now: now, locale: locale))
          }
          .disabled(!model.canMutate)
          .accessibilityIdentifier("trash.item.\(item.id.rawValue)")
        }
      }
      if let cursor = page.nextCursor {
        if let failure = model.paginationFailure {
          TVRetrySection(
            message: "\(failure.title). \(failure.message)", identifier: "trash.more-retry"
          ) {
            await model.loadMore()
          }
        } else {
          ProgressView("Loading more")
            .frame(maxWidth: .infinity)
            .accessibilityIdentifier("trash.load-more")
            // Re-keyed when blocking work settles, so a page the model
            // refused while busy is requested again.
            .task(id: PageRequest(cursor: cursor, isBusy: isBusyOutsidePaging)) {
              guard !isBusyOutsidePaging else { return }
              await model.loadMore()
            }
        }
      }
    }
  }

  private var isBusyOutsidePaging: Bool {
    model.activeMutation != nil || model.isRefreshing || model.isRefreshingStorage
  }

  private struct PageRequest: Equatable {
    let cursor: String
    let isBusy: Bool
  }
}
