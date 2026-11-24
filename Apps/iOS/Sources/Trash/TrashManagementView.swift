import Observation
import PutioCore
import SwiftUI

struct TrashManagementView: View {
  @State private var model: PutioTrashModel
  @State private var pendingDeletion: PutioTrashItem?
  @State private var confirmAlert: PutioConfirmAlert?
  @State private var toast: PutioToast?
  @State private var stillMoving: (title: String, message: String)?
  @State private var selection = PutioSelection<PutioFileID>()
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
          model.shownPage ?? page,
          isEmpty: page.items.isEmpty && page.nextCursor == nil)
      }
    }
    .navigationTitle("Trash")
    .navigationBarTitleDisplayMode(.inline)
    .putioContentBackground()
    .toolbar {
      if !selection.isActive && model.hasContents {
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
    .putioSelectionMode(
      $selection, among: loadedItems.map(\.id), actions: selectionActions,
      isBusy: !model.canMutate
    )
    .putioConfirmAlert($confirmAlert)
    .onChange(of: confirmAlert?.id) { _, id in
      if id == nil { pendingDeletion = nil }
    }
    .putioAlert(
      stillMoving?.title ?? "",
      isPresented: Binding(
        get: { stillMoving != nil }, set: { if !$0 { stillMoving = nil } }),
      message: stillMoving?.message ?? "",
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
        if !model.hasContents { confirmAlert = nil }
      }
    }
    .onChange(of: model.mutationOutcome) { _, outcome in
      present(outcome)
    }
    .onChange(of: model.activeMutation == nil) { _, isIdle in
      if isIdle { selection.retain(loadedItems.map(\.id)) }
    }
    .onChange(of: model.page?.items.isEmpty) { _, isEmpty in
      if isEmpty != false { selection.end() }
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
      List {
        if !page.items.isEmpty || !model.restoringItems.isEmpty {
          Group {
            if selection.isActive {
              selectionSummary(page)
            } else {
              header(page)
            }
          }
          .listRowInsets(.top, PutioTheme.Spacing.space0)
          .listRowInsets(.bottom, PutioTheme.Spacing.space2)
          .listRowSeparator(.hidden)
          .listRowBackground(PutioTheme.Colors.background)
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
          row(item)
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
        }
        if let cursor = page.nextCursor {
          pagingFooter(cursor: cursor)
            .listRowInsets(EdgeInsets())
            .listRowSeparator(.hidden)
            .listRowBackground(PutioTheme.Colors.background)
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

  private var loadedItems: [PutioTrashItem] { model.page?.items ?? [] }

  private var selectedItems: [PutioTrashItem] {
    loadedItems.filter { selection.contains($0.id) }
  }

  private static func listed(
    _ items: [PutioTrashItem], in model: PutioTrashModel
  ) -> [PutioTrashItem] {
    items.filter { model.page?.items.contains($0) == true }
  }

  private var showsBlockingProgress: Bool {
    switch model.activeMutation {
    case .none, .restore, .restoreItems, .restoreAll, .empty: false
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

  private func selectionSummary(_ page: PutioTrashPage) -> some View {
    HStack(alignment: .firstTextBaseline) {
      PutioNumericText(String(localized: "\(page.totalCount ?? page.items.count) items"))
      Spacer(minLength: PutioTheme.Spacing.space2)
      if !selectedItems.isEmpty {
        let bytes = selectedItems.reduce(Int64(0)) { $0 + $1.sizeBytes }
        PutioNumericText(
          String(localized: "\(PutioFileRowModel.sizeText(bytes: bytes, locale: locale)) selected"))
      }
    }
    .foregroundStyle(PutioTheme.Colors.textSecondary)
    .accessibilityElement(children: .combine)
    .accessibilityIdentifier("trash.selection.summary")
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
        ) { selection.begin() },
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

  @ViewBuilder
  private func row(_ item: PutioTrashItem) -> some View {
    if selection.isActive {
      PutioSelectableRow(isSelected: selection.contains(item.id)) {
        selection.toggle(item.id)
      } content: {
        PutioFileRow(rowModel(for: item), showsIcon: false)
          .frame(minHeight: rowMinHeight)
      }
      .disabled(!model.canMutate)
      .accessibilityIdentifier("trash.item.\(item.id.rawValue)")
      .accessibilityValue(
        Text(
          selection.contains(item.id)
            ? String(localized: "Selected") : String(localized: "Not selected")))
    } else {
      PutioFileRow(rowModel(for: item))
        .frame(minHeight: rowMinHeight)
        .accessibilityIdentifier("trash.item.\(item.id.rawValue)")
        .contentShape(
          .contextMenuPreview, RoundedRectangle(cornerRadius: PutioTheme.Radius.large)
        )
        .contextMenu {
          PutioItemMenuContent(rowMenu(for: item))
        }
        .swipeActions(edge: .leading, allowsFullSwipe: true) {
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
        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
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

  private var selectionActions: [PutioSelectionAction] {
    guard selection.isActive else { return [] }
    let items = selectedItems
    return [
      PutioSelectionAction(
        id: "restore", title: String(localized: "Restore"), icon: .arrowCounterClockwise
      ) {
        selection.end()
        restore(items)
      },
      PutioSelectionAction(
        id: "delete", title: String(localized: "Delete permanently"), icon: .trash,
        isDestructive: true
      ) { askToDelete(items) },
    ]
  }

  private func rowMenu(for item: PutioTrashItem) -> PutioItemMenu {
    PutioItemMenu([
      [
        PutioItemAction(
          id: "trash-restore", title: String(localized: "Restore"),
          icon: .arrowCounterClockwise, isDisabled: !model.canMutate
        ) { [model] in Task { await model.restore(item) } },
        PutioItemAction(
          id: "trash-row-select", title: String(localized: "Select"), icon: .checkCircle,
          isDisabled: !model.canMutate
        ) {
          selection.begin()
          selection.toggle(item.id)
        },
      ],
      [
        PutioItemAction(
          id: "trash-delete", title: String(localized: "Delete permanently"),
          icon: .trash, role: .destructive, isDisabled: !model.canMutate
        ) { askToDelete(item) }
      ],
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

  private func askToDelete(_ items: [PutioTrashItem]) {
    pendingDeletion = nil
    confirmAlert = PutioConfirmAlert(
      title: String(localized: "Delete \(items.count) items permanently?"),
      message: items.count == 1
        ? String(localized: "It will be removed from trash right away. This cannot be undone.")
        : String(localized: "They will be removed from trash right away. This cannot be undone."),
      confirmTitle: String(localized: "Delete")
    ) { [model] in
      let listed = Self.listed(items, in: model)
      guard !listed.isEmpty else { return }
      Task { await model.permanentlyDelete(listed) }
    }
  }

  private func restore(_ item: PutioTrashItem) {
    Task { await model.restore(item) }
  }

  private func restore(_ items: [PutioTrashItem]) {
    Self.restore(items, in: model)
  }

  private static func restore(_ items: [PutioTrashItem], in model: PutioTrashModel) {
    let listed = listed(items, in: model)
    guard !listed.isEmpty else { return }
    Task { await model.restore(listed) }
  }

  private func rowModel(for item: PutioTrashItem) -> PutioFileRowModel {
    item.rowModel(locale: locale, calendar: calendar)
  }

  private func present(_ outcome: PutioTrashMutationOutcome?) {
    guard let outcome else { return }
    switch outcome {
    case .permanentlyDeletedItems:
      selection.end()
    case .failed(.permanentlyDeleteItems(let items), _):
      selection = PutioSelection(
        isActive: true, selectedIDs: Set(Self.listed(items, in: model).map(\.id)))
    default:
      break
    }
    switch outcome.notice {
    case .done(let text):
      toast = PutioToast(text)
    case .failed(let text):
      toast = PutioToast(text, icon: .warning, width: .fit)
    case .restoreFailed(let text, let items):
      toast = PutioToast(
        text,
        action: PutioToast.Action(String(localized: "Try again")) { [model] in
          Self.restore(items, in: model)
        })
    case .stillMoving(let title, let message):
      stillMoving = (title, message)
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
