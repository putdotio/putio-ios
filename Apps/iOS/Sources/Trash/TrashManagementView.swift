import Observation
import PutioCore
import SwiftUI

struct TrashManagementView: View {
  @State private var model: PutioTrashModel
  @State private var pendingDeletion: PutioTrashItem?
  @State private var confirmAlert: PutioConfirmAlert?
  @State private var pendingBulkDeletion: [PutioTrashItem] = []
  @State private var toast: PutioToast?
  @State private var stillMovingMessage = ""
  @State private var stillMovingAlertPresented = false
  @State private var selectedIDs: Set<PutioFileID> = []
  @State private var editMode: EditMode = .inactive
  @Environment(\.locale) private var locale
  @Environment(\.calendar) private var calendar
  @PutioScaledMetric private var rowMinHeight: CGFloat

  init(
    runtime: PutioRuntime,
    reconciliation: PutioTrashReconciliation,
    onRestored: @escaping PutioTrashDidRestore
  ) {
    _model = State(
      initialValue: PutioTrashModel(
        runtime: runtime, reconciliation: reconciliation, onRestored: onRestored))
    _rowMinHeight = PutioScaledMetric(Self.rowMinHeight)
  }

  private static let rowMinHeight = PutioMetricRole(value: 60, relativeTo: .body)

  var body: some View {
    Group {
      switch model.state {
      case .loading:
        TrashLoadingView(accessibilityLabel: String(localized: "Loading Trash"))
          .modifier(TrashStatePlacement(.loading))
      case .failed(let failure):
        TrashErrorView(
          title: failure.title,
          message: failure.message,
          retryTitle: String(localized: "Try again"),
          retryIdentifier: "trash.retry"
        ) {
          Task { await model.retryFailedLoad() }
        }
        .modifier(TrashStatePlacement(.failed))
      case .loaded(let page):
        loadedContent(
          Self.shownPage(page, restoring: restoringItem),
          isEmpty: page.items.isEmpty && page.nextCursor == nil)
      }
    }
    .navigationTitle("Trash")
    .navigationBarTitleDisplayMode(.inline)
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
            PutioItemMenuContent(moreMenu)
          } label: {
            Label("More", systemImage: "ellipsis")
          }
          .disabled(!model.canMutate)
          .accessibilityIdentifier("trash.menu")
        }
      }
    }
    .modifier(PutioSelectionTabBarVisibility(isEditing: isEditing))
    .environment(\.editMode, $editMode)
    .putioConfirmAlert($confirmAlert)
    .onChange(of: confirmAlert?.id) { _, id in
      if id == nil { pendingDeletion = nil }
    }
    .confirmationDialog(
      "Delete \(pendingBulkDeletion.count) items permanently?",
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
    .putioAlert(
      String(localized: "Restore could not start"),
      isPresented: $stillMovingAlertPresented,
      message: stillMovingMessage,
      actions: [
        PutioAlertAction(String(localized: "OK"), tier: .neutral, id: "trash.still-moving.ok")
      ]
    )
    .putioToast($toast)
    .overlay {
      if showsBlockingProgress {
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
    .task(id: isOffline) { await retryWhileOffline() }
    .onDisappear { model.abandonListing() }
    .onChange(of: model.reconciliationVersion) { _, _ in
      Task {
        await model.applyReconciliation()
        if let pending = pendingDeletion, model.page?.items.contains(pending) != true {
          pendingDeletion = nil
          confirmAlert = nil
        }
        pendingBulkDeletion.removeAll { model.page?.items.contains($0) != true }
        if !model.hasContents { confirmAlert = nil }
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
  }

  @ViewBuilder
  private func loadedContent(_ page: PutioTrashPage, isEmpty: Bool) -> some View {
    if isEmpty && model.refreshFailure == nil {
      ScrollView {
        emptyState
          .modifier(TrashStatePlacement(.empty))
          .containerRelativeFrame([.horizontal, .vertical])
      }
      .scrollBounceBehavior(.always)
      .refreshable { await Task { await model.refresh() }.value }
    } else {
      List(selection: isEditing ? $selectedIDs : nil) {
        if !page.items.isEmpty || restoringItem != nil {
          header(page)
            .listRowInsets(.top, PutioTheme.Spacing.space0)
            .listRowInsets(.bottom, PutioTheme.Spacing.space2)
            .listRowSeparator(.hidden)
            .listRowBackground(PutioTheme.Colors.background)
            .selectionDisabled()
        }
        if let failure = model.refreshFailure {
          Section {
            PutioErrorStateView(
              title: failure.title,
              message: failure.message,
              retryTitle: String(localized: "Try again")
            ) {
              Task { await model.refresh() }
            }
          }
        }
        if isEmpty {
          // The page is still empty; errors above do not change that.
          Section { emptyState }.listRowBackground(Color.clear)
        }
        let prefetchIDs =
          page.nextCursor == nil ? [] : Set(page.items.suffix(Self.prefetchDistance).map(\.id))
        ForEach(page.items) { item in
          PutioFileRow(rowModel(for: item))
            .frame(minHeight: rowMinHeight)
            .tag(item.id)
            .listRowInsets(.vertical, PutioTheme.Spacing.space0)
            .listRowInsets(.trailing, PutioTheme.Spacing.space1)
            .alignmentGuide(.listRowSeparatorTrailing) {
              $0[.trailing] + PutioTheme.Spacing.space1
            }
            .listRowSeparator(
              item.id == page.items.last?.id && page.nextCursor == nil ? .hidden : .automatic,
              edges: .bottom
            )
            .listRowBackground(PutioTheme.Colors.background)
            .task(id: prefetchRequest(item.id, in: prefetchIDs)) {
              guard prefetchIDs.contains(item.id), model.paginationFailure == nil,
                !isBusyOutsidePaging
              else { return }
              await model.loadMore()
            }
            .accessibilityIdentifier("trash.item.\(item.id.rawValue)")
            .contextMenu {
              if !isEditing {
                PutioItemMenuContent(rowMenu(for: item))
              }
            }
            .swipeActions(edge: .leading, allowsFullSwipe: true) {
              if !isEditing {
                Button {
                  restore(item)
                } label: {
                  Label {
                    Text("Restore")
                  } icon: {
                    Image(putioIcon: .arrowCounterClockwise)
                  }
                  .labelStyle(.iconOnly)
                }
                .disabled(!model.canMutate)
                .tint(PutioTheme.Components.Button.secondaryBackground)
                .accessibilityIdentifier("trash.restore.\(item.id.rawValue)")
              }
            }
            .swipeActions(edge: .trailing, allowsFullSwipe: true) {
              if !isEditing {
                Button {
                  askToDelete(item)
                } label: {
                  Label {
                    Text("Delete permanently")
                  } icon: {
                    Image(putioIcon: .trash)
                  }
                  .labelStyle(.iconOnly)
                }
                .disabled(!model.canMutate)
                .tint(PutioTheme.Colors.destructive)
                .accessibilityIdentifier("trash.delete.\(item.id.rawValue)")
              }
            }
        }
        if let cursor = page.nextCursor {
          pagingFooter(cursor: cursor)
            .listRowInsets(EdgeInsets())
            .listRowSeparator(.hidden)
            .listRowBackground(PutioTheme.Colors.background)
            .selectionDisabled()
        }
      }
      .listStyle(.plain)
      .environment(\.defaultMinListRowHeight, PutioTheme.Spacing.space0)
      .refreshable { await model.refresh() }
      .tint(PutioTheme.Colors.accent)
      .accessibilityIdentifier("trash.list")
    }
  }

  @ViewBuilder
  private func pagingFooter(cursor: String) -> some View {
    if model.paginationFailure != nil {
      PutioNextPageFailedFooter(
        message: PutioScreenErrorKind.failed.title, retryIdentifier: "trash.more-retry"
      ) {
        Task { await model.loadMore() }
      }
      .accessibilityElement(children: .contain)
      .accessibilityIdentifier("trash.more-error")
    } else {
      PutioNextPageLoadingFooter(accessibilityLabel: String(localized: "Loading more Trash items"))
        .accessibilityIdentifier("trash.load-more")
        .task(id: pageRequest(cursor: cursor)) {
          guard !isBusyOutsidePaging else { return }
          await model.loadMore()
        }
    }
  }

  private func prefetchRequest(_ id: PutioFileID, in ids: Set<PutioFileID>) -> PageRequest? {
    guard ids.contains(id), let cursor = model.page?.nextCursor else { return nil }
    return pageRequest(cursor: cursor)
  }

  private func pageRequest(cursor: String) -> PageRequest {
    PageRequest(cursor: cursor, isBusy: isBusyOutsidePaging, epoch: model.pageRequestEpoch)
  }

  private static let prefetchDistance = 5

  private struct PageRequest: Equatable {
    let cursor: String
    let isBusy: Bool
    let epoch: UInt64
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

  private var restoringItem: PutioTrashItem? {
    guard case .restore(let item) = model.activeMutation else { return nil }
    return item
  }

  static func shownPage(_ page: PutioTrashPage, restoring item: PutioTrashItem?) -> PutioTrashPage {
    guard let item, page.items.contains(item) else { return page }
    return PutioTrashPage(
      items: page.items.filter { $0 != item },
      nextCursor: page.nextCursor,
      totalCount: page.totalCount.map { max(0, $0 - 1) },
      sizeBytes: max(0, page.sizeBytes - item.sizeBytes)
    )
  }

  private var showsBlockingProgress: Bool {
    switch model.activeMutation {
    case .none, .restore, .restoreAll, .empty: false
    default: true
    }
  }

  private var emptyState: some View {
    PutioEmptyStateView(
      kaomoji: .shrug,
      title: String(localized: "Your trash is empty"),
      message: String(localized: "Files you move to trash stay here for 14 days.")
    )
  }

  private func header(_ page: PutioTrashPage) -> some View {
    ViewThatFits(in: .horizontal) {
      HStack(alignment: .firstTextBaseline) {
        headerSize(page)
        Spacer(minLength: PutioTheme.Spacing.space2)
        headerRetention
      }
      VStack(alignment: .leading, spacing: PutioTheme.Spacing.space1) {
        headerSize(page)
        headerRetention
      }
    }
    .foregroundStyle(PutioTheme.Colors.textSecondary)
    .accessibilityElement(children: .combine)
    .accessibilityIdentifier("trash.header")
  }

  private func headerSize(_ page: PutioTrashPage) -> some View {
    PutioNumericText(PutioFileRowModel.sizeText(bytes: page.sizeBytes, locale: locale))
  }

  private var headerRetention: some View {
    Text("Deleted items stay 14 days")
      .putioFont(PutioTheme.Typography.caption)
      .fixedSize(horizontal: false, vertical: true)
  }

  private var isOffline: Bool {
    if case .failed(let failure) = model.state { return failure.isOffline }
    return false
  }

  private func retryWhileOffline() async {
    var attempt = 0
    while isOffline {
      do {
        try await Task.sleep(for: .seconds(min(3 << min(attempt, 4), 30)))
      } catch {
        return
      }
      guard isOffline else { return }
      await Task { await model.retryKeepingFailure() }.value
      attempt += 1
    }
  }

  private var moreMenu: PutioItemMenu {
    PutioItemMenu([
      [
        PutioItemAction(
          id: "trash-select", title: String(localized: "Select"), icon: .checkCircle,
          isDisabled: loadedItems.isEmpty
        ) { editMode = .active },
        PutioItemAction(
          id: "trash-restore-all", title: String(localized: "Restore all"),
          icon: .arrowCounterClockwise
        ) { [model] in Task { await model.restoreAll() } },
        PutioItemAction(
          id: "trash-empty", title: String(localized: "Empty trash"), icon: .trash,
          role: .destructive
        ) { askToEmpty() },
      ]
    ])
  }

  private func askToEmpty() {
    pendingDeletion = nil
    confirmAlert = PutioConfirmAlert(
      title: String(localized: "Empty trash?"),
      message: String(
        localized: "Every item in trash will be removed right away. This cannot be undone."),
      confirmTitle: String(localized: "Empty trash")
    ) { [model] in
      guard model.hasContents else { return }
      Task { await model.empty() }
    }
  }

  private func rowMenu(for item: PutioTrashItem) -> PutioItemMenu {
    PutioItemMenu([
      [
        PutioItemAction(
          id: "trash-restore", title: String(localized: "Restore"),
          icon: .arrowCounterClockwise, isDisabled: !model.canMutate
        ) { [model] in Task { await model.restore(item) } },
        PutioItemAction(
          id: "trash-delete", title: String(localized: "Delete permanently"),
          icon: .trash, role: .destructive, isDisabled: !model.canMutate
        ) { askToDelete(item) },
      ]
    ])
  }

  private func askToDelete(_ item: PutioTrashItem) {
    pendingDeletion = item
    confirmAlert = PutioConfirmAlert(
      title: String(localized: "Delete permanently?"),
      message: String(
        localized: "“\(item.name)” will be removed from trash right away. This cannot be undone."),
      confirmTitle: String(localized: "Delete")
    ) { [model] in
      guard model.page?.items.contains(item) == true else { return }
      Task { await model.permanentlyDelete(item) }
    }
  }

  private func restore(_ item: PutioTrashItem) {
    Task { await model.restore(item) }
  }

  private func rowModel(for item: PutioTrashItem) -> PutioFileRowModel {
    Self.rowModel(for: item, locale: locale, calendar: calendar)
  }

  static func rowModel(
    for item: PutioTrashItem, relativeTo now: Date = .now, locale: Locale = .current,
    calendar: Calendar = .current
  ) -> PutioFileRowModel {
    PutioFileRowModel(
      name: item.name,
      kind: PutioBrowserItemPresentation.rowKind(for: item.kind),
      sizeText: PutioFileRowModel.sizeText(bytes: item.sizeBytes, locale: locale),
      dateText: PutioTrashExpiry.text(until: item.expiresAt, from: now, calendar: calendar),
      showsDisclosure: false
    )
  }

  private func present(_ outcome: PutioTrashMutationOutcome?) {
    guard let outcome else { return }
    switch outcome {
    case .restored:
      toast = PutioToast(String(localized: "Restore started"))
    case .permanentlyDeleted(let item, _):
      toast = PutioToast(String(localized: "“\(item.name)” is no longer in trash."))
    case .restoredItems:
      toast = PutioToast(String(localized: "Items restored"))
    case .permanentlyDeletedItems:
      toast = PutioToast(
        String(localized: "Items deleted"))
    case .restoredAll:
      toast = PutioToast(String(localized: "Restore started"))
    case .emptied:
      toast = PutioToast(String(localized: "Trash is empty."))
    case .failed(_, let failure) where failure.isStillMovingToTrash:
      stillMovingMessage = failure.message
      stillMovingAlertPresented = true
    case .failed(.permanentlyDelete, _), .failed(.empty, _):
      toast = PutioToast(
        String(localized: "The request could not start"), icon: .warning, width: .fit)
    case .failed(.restore, _), .failed(.restoreAll, _):
      toast = PutioToast(
        String(localized: "Restore could not start"), icon: .warning, width: .fit)
    case .failed(_, let failure):
      toast = PutioToast(failure.title)
    }
    model.clearMutationOutcome()
  }
}

private struct TrashStatePlacement: ViewModifier {
  enum State {
    case loading
    case empty
    case failed

    var lift: CGFloat {
      switch self {
      case .loading: 74
      case .empty: 51
      case .failed: 68
      }
    }
  }

  private let state: State
  @PutioScaledMetric private var width: CGFloat

  init(_ state: State) {
    self.state = state
    _width = PutioScaledMetric(PutioMetricRole(value: 370, relativeTo: .body))
  }

  func body(content: Content) -> some View {
    content
      .frame(maxWidth: width)
      .padding(.bottom, state.lift)
      .frame(maxWidth: .infinity, maxHeight: .infinity)
  }
}
