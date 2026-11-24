import PutioCore
import SwiftUI

struct TVTrashView: View {
  @State private var model: PutioTrashModel
  @State private var now: Date
  @State private var selectedItem: PutioTrashItem?
  @State private var confirmsEmpty = false
  @State private var toast: PutioToast?
  @State private var stillMoving: (title: String, message: String)?
  private let locale: Locale
  private let loadsOnAppear: Bool

  init(
    runtime: PutioRuntime, reconciliation: PutioTrashReconciliation,
    refreshRequests: PutioFolderRefreshRequests
  ) {
    self.init(
      model: Self.model(
        runtime: runtime, reconciliation: reconciliation, refreshRequests: refreshRequests))
  }

  static func model(
    runtime: PutioRuntime, reconciliation: PutioTrashReconciliation,
    refreshRequests: PutioFolderRefreshRequests
  ) -> PutioTrashModel {
    PutioTrashModel(runtime: runtime, reconciliation: reconciliation) { destinationID in
      PutioRestoredFileReconciliation.apply(destinationID: destinationID, to: refreshRequests)
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
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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
    .alert(
      stillMoving?.title ?? "",
      isPresented: Binding(get: { stillMoving != nil }, set: { if !$0 { stillMoving = nil } })
    ) {
      Button("OK", role: .cancel) {}
        .accessibilityIdentifier("trash.still-moving.ok")
    } message: {
      Text(stillMoving?.message ?? "")
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
      present(outcome.notice)
      model.clearMutationOutcome()
    }
  }

  private func present(_ notice: PutioTrashNotice) {
    switch notice {
    case .done(let text):
      toast = PutioToast(text)
    case .failed(let text):
      toast = PutioToast(text, icon: .warning, width: .fit)
    case .restoreFailed(let text, let items):
      toast = PutioToast(
        text,
        action: PutioToast.Action("Try again") { [model] in
          let listed = items.filter { model.page?.items.contains($0) == true }
          guard !listed.isEmpty else { return }
          Task { await model.restore(listed) }
        })
    case .stillMoving(let title, let message):
      stillMoving = (title, message)
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
            PutioFileRow(item.rowModel(relativeTo: now, locale: locale))
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
