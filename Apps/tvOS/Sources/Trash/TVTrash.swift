import PutioCore
import SwiftUI

struct TVTrashView: View {
  @State private var model: PutioTrashModel
  @State private var now: Date
  @State private var shownItemID: PutioFileID?
  @State private var deleting: PutioTrashItem?
  @State private var confirmedDeletion: PutioTrashItem?
  @State private var confirmsEmpty = false
  @State private var toast: PutioToast?
  @State private var stillMoving: (title: String, message: String)?
  @State private var showsPanel = true
  @FocusState private var focus: Focus?
  private let locale: Locale
  private let loadsOnAppear: Bool

  private enum Focus: Hashable {
    case item(PutioFileID)
    case restoreAll
    case panel
    case panelDelete
    case moreRetry
  }

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
    shownItemID: PutioFileID? = nil, loadsOnAppear: Bool = true
  ) {
    _model = State(initialValue: model)
    _now = State(initialValue: now)
    _shownItemID = State(initialValue: shownItemID)
    self.locale = locale
    self.loadsOnAppear = loadsOnAppear
  }

  var body: some View {
    content
      .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
      .tvOverscanPadding()
      .background(PutioTheme.Colors.background.ignoresSafeArea())
      .alert(
        String(localized: "Delete permanently?", bundle: .putioCore),
        isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
        presenting: deleting
      ) { item in
        Button(String(localized: "Delete", bundle: .putioCore), role: .destructive) {
          confirmedDeletion = item
        }
        .accessibilityIdentifier("trash.delete-confirm")
        Button(String(localized: "Cancel", bundle: .putioCore), role: .cancel) {}
          .accessibilityIdentifier("trash.delete-cancel")
      } message: { item in
        Text(
          String(
            localized:
              "“\(item.name)” will be removed from trash right away. This cannot be undone.",
            bundle: .putioCore))
      }
      .alert(String(localized: "Empty trash?", bundle: .putioCore), isPresented: $confirmsEmpty) {
        Button(String(localized: "Empty trash", bundle: .putioCore), role: .destructive) {
          Task { await model.empty() }
        }
        .accessibilityIdentifier("trash.empty-confirm")
        Button(String(localized: "Cancel", bundle: .putioCore), role: .cancel) {}
          .accessibilityIdentifier("trash.empty-cancel")
      } message: {
        Text(
          String(
            localized: "Every item in trash will be removed right away. This cannot be undone.",
            bundle: .putioCore))
      }
      .alert(
        stillMoving?.title ?? "",
        isPresented: Binding(get: { stillMoving != nil }, set: { if !$0 { stillMoving = nil } })
      ) {
        Button(String(localized: "OK", bundle: .putioCore), role: .cancel) {}
          .accessibilityIdentifier("trash.still-moving.ok")
      } message: {
        Text(stillMoving?.message ?? "")
      }
      .putioToast($toast)
      .task { if loadsOnAppear { await model.refreshOnAppear() } }
      .onAppear { if loadsOnAppear { now = .now } }
      .onDisappear { model.abandonListing() }
      .onChange(of: focus) { _, focus in
        switch focus {
        case .item(let id):
          shownItemID = id
          showsPanel = true
        case .moreRetry:
          showsPanel = false
        case .restoreAll, .panel, .panelDelete, nil:
          break
        }
        if focus != nil, let item = confirmedDeletion {
          confirmedDeletion = nil
          mutate(item) { await model.permanentlyDelete(item) }
        }
      }
      .onChange(of: model.page?.items.map(\.id) ?? []) { old, new in
        moveFocus(from: old, to: new)
      }
      .onChange(of: model.reconciliationVersion) { _, _ in
        Task {
          await model.applyReconciliation()
          if let deleting, model.page?.items.contains(deleting) != true { self.deleting = nil }
          if !model.hasContents { confirmsEmpty = false }
        }
      }
      .onChange(of: model.mutationOutcome) { _, outcome in
        guard let outcome else { return }
        present(outcome.notice)
        model.clearMutationOutcome()
      }
  }

  /// A row that leaves the list hands focus to the row after it, or to
  /// Restore all when it was the last.
  private func moveFocus(from old: [PutioFileID], to new: [PutioFileID]) {
    guard let shown = shownItemID ?? old.first, old.contains(shown), !new.contains(shown)
    else { return }
    let next = old.drop { $0 != shown }.dropFirst().first { new.contains($0) }
    shownItemID = next
    guard !new.isEmpty else { return }
    focus = next.map(Focus.item) ?? .restoreAll
  }

  private func present(_ notice: PutioTrashNotice) {
    switch notice {
    case .done(let text):
      toast = PutioToast(text, width: .fit)
    case .failed(let text):
      toast = PutioToast(text, icon: .warning, width: .fit)
    case .restoreFailed(let text, let items):
      toast = PutioToast(
        text, icon: .warning,
        action: PutioToast.Action(String(localized: "Try again", bundle: .putioCore)) {
          [model] in
          let listed = items.filter { model.page?.items.contains($0) == true }
          guard !listed.isEmpty else { return }
          Task { await model.restore(listed) }
        })
    case .stillMoving(let title, let message):
      stillMoving = (title, message)
    }
  }

  /// Another screen may have removed the row while its alert was up.
  private func mutate(_ item: PutioTrashItem, _ operation: @escaping @MainActor () async -> Void) {
    guard model.canMutate, model.page?.items.contains(item) == true else { return }
    Task { await operation() }
  }

  private var header: some View {
    VStack(alignment: .leading, spacing: PutioTheme.TV.Spacing.xxs) {
      Text(String(localized: "Account", bundle: .putioCore))
        .putioFont(PutioTheme.TV.Typography.caption)
        .foregroundStyle(PutioTheme.TV.Colors.textSecondary)
      Text(String(localized: "Trash", bundle: .putioCore))
        .putioFont(PutioTheme.TV.Typography.heading)
        .foregroundStyle(PutioTheme.TV.Colors.textPrimary)
        .accessibilityAddTraits(.isHeader)
    }
  }

  private func titled(@ViewBuilder _ state: () -> some View) -> some View {
    VStack(alignment: .leading, spacing: PutioTheme.TV.Spacing.medium) {
      header
      state()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
  }

  @ViewBuilder
  private var content: some View {
    switch model.state {
    case .loading:
      titled {
        PutioLoadingStateView(
          title: String(localized: "Loading trash…", bundle: .putioCore), titleVisibility: .hidden)
      }
    case .failed:
      titled {
        PutioErrorStateView(
          title: String(localized: "Couldn’t load your trash.", bundle: .putioCore),
          message: String(
            localized: "Check your internet connection and try again.", bundle: .putioCore),
          retryTitle: String(localized: "Try again", bundle: .putioCore),
          retryIdentifier: "trash.retry"
        ) {
          Task { await model.refresh() }
        }
      }
    case .loaded(let page):
      if page.items.isEmpty, page.nextCursor == nil, model.refreshFailure == nil,
        model.storageFailure == nil
      {
        titled {
          PutioEmptyStateView(
            kaomoji: .shrug,
            title: String(localized: "Your trash is empty", bundle: .putioCore),
            message: String(
              localized: "Files you move to trash stay here for 14 days.", bundle: .putioCore)
          )
          .accessibilityIdentifier("trash.empty-state")
        }
      } else {
        HStack(alignment: .top, spacing: PutioTheme.TV.Spacing.large) {
          VStack(alignment: .leading, spacing: PutioTheme.TV.Spacing.small) {
            header
              .padding(.bottom, PutioTheme.TV.Spacing.small)
            toolbar(page)
            list(page)
          }
          .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
          if showsPanel,
            let item = page.items.first(where: { $0.id == shownItemID }) ?? page.items.first
          {
            panel(item)
          } else {
            Color.clear.frame(width: TVDetailPanelLayout.width)
          }
        }
      }
    }
  }

  private func toolbar(_ page: PutioTrashPage) -> some View {
    VStack(alignment: .leading, spacing: PutioTheme.TV.Spacing.small) {
      HStack(spacing: PutioTheme.TV.Spacing.xs) {
        Text(PutioFileRowModel.sizeText(bytes: page.sizeBytes, locale: locale))
          .putioFont(PutioTheme.TV.Typography.numeric)
        Text(verbatim: "·")
          .accessibilityHidden(true)
        Text(String(localized: "Deleted items stay 14 days", bundle: .putioCore))
      }
      .putioFont(PutioTheme.TV.Typography.caption)
      .foregroundStyle(PutioTheme.TV.Colors.textSecondary)
      .lineLimit(1)
      .accessibilityElement(children: .combine)
      .accessibilityIdentifier("trash.summary")
      HStack(spacing: PutioTheme.TV.Spacing.small) {
        PutioButton(
          String(localized: "Refresh", bundle: .putioCore), icon: .arrowsClockwise,
          tier: .secondary
        ) {
          guard model.canMutate else { return }
          Task { await model.refresh() }
        }
        .fixedSize()
        .accessibilityIdentifier("trash.refresh")
        if model.hasContents {
          PutioButton(
            String(localized: "Restore all", bundle: .putioCore), icon: .arrowCounterClockwise,
            tier: .secondary
          ) {
            guard model.canMutate else { return }
            Task { await model.restoreAll() }
          }
          .fixedSize()
          .focused($focus, equals: .restoreAll)
          .accessibilityIdentifier("trash.restore-all")
          PutioButton(
            String(localized: "Empty trash", bundle: .putioCore), icon: .trash, tier: .secondary
          ) {
            guard model.canMutate else { return }
            confirmsEmpty = true
          }
          .fixedSize()
          .accessibilityIdentifier("trash.empty")
        }
        if model.activeMutation != nil {
          ProgressView()
            .accessibilityLabel(String(localized: "Updating trash…", bundle: .putioCore))
            .accessibilityIdentifier("trash.progress")
        }
        Spacer(minLength: 0)
      }
      .focusSection()
    }
  }

  private func list(_ page: PutioTrashPage) -> some View {
    TVRowList {
      if let failure = model.refreshFailure {
        TVRetrySection(message: failure.message, identifier: "trash.refresh-retry") {
          await model.refresh()
        }
      }
      if let failure = model.storageFailure {
        TVRetrySection(message: failure.message, identifier: "trash.storage-retry") {
          await model.retryStorageRefresh()
        }
      }
      ForEach(page.items) { item in
        Button {
          focus = .panel
        } label: {
          PutioFileRow(item.rowModel(relativeTo: now, locale: locale))
        }
        .tvRowOpen(!isFocusedRow && showsPanel && shownItemID == item.id)
        .focused($focus, equals: .item(item.id))
        .accessibilityIdentifier("trash.item.\(item.id.rawValue)")
      }
      if let cursor = page.nextCursor {
        if model.paginationFailure != nil {
          TVLoadMoreFailedRow(
            message: String(localized: "Couldn’t load more items.", bundle: .putioCore),
            identifier: "trash.more-retry", focus: $focus, focusValue: .moreRetry
          ) { await model.loadMore() }
        } else {
          ProgressView()
            .accessibilityLabel(String(localized: "Loading trash…", bundle: .putioCore))
            .frame(maxWidth: .infinity)
            .accessibilityIdentifier("trash.load-more")
            .task(id: PageRequest(cursor: cursor, isBusy: isBusyOutsidePaging)) {
              guard !isBusyOutsidePaging else { return }
              await model.loadMore()
            }
        }
      }
    }
    .focusSection()
  }

  private var isFocusedRow: Bool {
    if case .item = focus { return true }
    return false
  }

  private func panel(_ item: PutioTrashItem) -> some View {
    let row = item.rowModel(relativeTo: now, locale: locale)
    return TVDetailPanel(
      icon: row.kind.icon, title: item.name, identifier: "trash.panel"
    ) {
      HStack(spacing: PutioTheme.TV.Spacing.xs) {
        Text(row.sizeText ?? "")
          .putioFont(PutioTheme.TV.Typography.numeric)
        Text(verbatim: "·")
          .accessibilityHidden(true)
        Text(row.dateText ?? "")
      }
    } facts: {
      TVDetailFact(
        label: String(localized: "Deleted", bundle: .putioCore),
        value: item.deletedAt.formatted(
          .dateTime.month(.abbreviated).day().locale(locale)))
    } actions: {
      TVDetailAction(
        title: String(localized: "Restore", bundle: .putioCore), icon: .arrowCounterClockwise
      ) {
        mutate(item) { await model.restore(item) }
      }
      .focused($focus, equals: .panel)
      .accessibilityIdentifier("trash.panel.restore")
      TVDetailDivider()
      TVDetailAction(
        title: String(localized: "Delete permanently", bundle: .putioCore), icon: .trash,
        isDestructive: true
      ) {
        guard model.canMutate else { return }
        deleting = item
      }
      .focused($focus, equals: .panelDelete)
      .accessibilityIdentifier("trash.panel.delete")
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
