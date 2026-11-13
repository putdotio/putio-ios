import PutioCore
import SwiftUI

@MainActor
struct HistoryView: View {
  let runtime: PutioRuntime
  let trashEnabled: Bool
  let refreshRequests: PutioFolderRefreshRequests
  let onFileSelected: PutioFileSelection

  @Environment(\.scenePhase) private var scenePhase
  @Environment(\.locale) private var locale
  @State private var groupingDate = Date.now
  @State private var model: PutioHistoryModel
  @State private var path: [PutioFolderRoute] = []
  @State private var clearConfirmationPresented = false
  @State private var toast: PutioToast?

  init(
    runtime: PutioRuntime,
    trashEnabled: Bool,
    refreshRequests: PutioFolderRefreshRequests,
    onFileSelected: @escaping PutioFileSelection
  ) {
    self.runtime = runtime
    self.trashEnabled = trashEnabled
    self.refreshRequests = refreshRequests
    self.onFileSelected = onFileSelected
    _model = State(initialValue: PutioHistoryModel(actions: PutioHistoryActions(runtime: runtime)))
  }

  var body: some View {
    NavigationStack(path: $path) {
      content
        .navigationTitle("History")
        .putioContentBackground()
        .toolbar {
          if let page = model.page, !page.items.isEmpty || page.nextBefore != nil {
            ToolbarItem(placement: .primaryAction) {
              Button("Clear", role: .destructive) { clearConfirmationPresented = true }
                .disabled(isBusy)
                .accessibilityIdentifier("history.clear")
            }
          }
        }
        .confirmationDialog(
          "Clear all history?", isPresented: $clearConfirmationPresented, titleVisibility: .visible
        ) {
          Button("Clear History", role: .destructive) { Task { await model.clear() } }
            .accessibilityIdentifier("history.clear-confirm")
          Button("Cancel", role: .cancel) {}
        } message: {
          Text("Every event will be removed from your history. Your files will stay in place.")
        }
        .navigationDestination(for: PutioFolderRoute.self) { route in
          PutioFolderScreen(
            route: route,
            load: {
              try await runtime.listFiles(parentID: $0, perPage: PutioRuntime.folderPageSize)
            },
            continueLoad: { try await runtime.continueFiles(cursor: $0) },
            actions: PutioFileActions(runtime: runtime),
            trashEnabled: trashEnabled,
            refreshRequests: refreshRequests,
            onFileSelected: onFileSelected
          )
        }
        .task { await model.loadIfNeeded() }
        .onAppear { groupingDate = .now }
        .onDisappear { model.cancelOpen() }
        .onReceive(NotificationCenter.default.publisher(for: .NSCalendarDayChanged)) { _ in
          groupingDate = .now
        }
        .onChange(of: scenePhase) { _, phase in
          if phase == .active { groupingDate = .now }
        }
        .onChange(of: model.openFailure) { _, failure in
          guard failure?.isNotFound == true else { return }
          model.cancelOpen()
          toast = PutioToast(
            String(localized: "This item cannot be opened right now. Check Files, then try again."))
        }
        .onChange(of: model.openedFile) { _, file in
          guard let file else { return }
          model.clearOpenedFile()
          let presentation = PutioBrowserItemPresentation(item: file)
          if let folder = presentation.folderRoute {
            path.append(folder)
          } else if let route = presentation.fileRoute {
            onFileSelected(route)
          }
        }
    }
    .putioToast($toast)
  }

  private var isBusy: Bool { model.mutation != nil || model.openingEventID != nil }

  @ViewBuilder
  private var content: some View {
    switch model.state {
    case .loading:
      PutioLoadingStateView(title: String(localized: "Loading history"))
    case .failed(let failure):
      PutioErrorStateView(
        title: String(localized: "Could not load history"), message: failure.message,
        retryTitle: String(localized: "Try again"), retryIdentifier: "history.retry"
      ) {
        Task { await model.refresh() }
      }
    case .loaded(let page):
      if page.items.isEmpty, page.nextBefore == nil,
        model.refreshFailure == nil, model.mutationFailure == nil,
        model.openFailure.map(\.isNotFound) ?? true
      {
        GeometryReader { geometry in
          ScrollView {
            PutioEmptyStateView(
              icon: .clockCounterClockwise, title: String(localized: "No history"),
              message: String(localized: "New account events will appear here.")
            )
            .frame(minHeight: geometry.size.height)
          }
          .scrollBounceBehavior(.always)
          .refreshable { await model.refresh() }
        }
      } else {
        historyList(page)
      }
    }
  }

  private func historyList(_ page: PutioHistoryPage) -> some View {
    List {
      if let failure = model.refreshFailure {
        retryRow(failure.message, identifier: "history.retry") { await model.refresh() }
      }
      if let failure = model.mutationFailure {
        retryRow(failure.message, identifier: "history.mutation-retry") {
          await model.retryMutation()
        }
      }
      if let failure = model.openFailure, !failure.isNotFound {
        retryRow(failure.message, identifier: "history.open-retry") { await model.retryOpen() }
      }
      if model.mutation != nil {
        ProgressView("Updating history")
          .listRowBackground(PutioTheme.Colors.background)
          .accessibilityIdentifier("history.progress")
      }
      ForEach(PutioHistoryDay.group(page.items, now: groupingDate, locale: locale)) { day in
        Section {
          ForEach(day.items) { event in
            eventRow(event)
              .listRowInsets(.vertical, PutioTheme.Spacing.space2)
              .listRowBackground(PutioTheme.Colors.background)
          }
        } header: {
          Text(day.title)
            .putioFont(PutioTheme.Typography.caption)
            .foregroundStyle(PutioTheme.Colors.textSecondary)
            .accessibilityAddTraits(.isHeader)
            .listRowInsets(.top, PutioTheme.Spacing.space3)
            .listRowInsets(.bottom, PutioTheme.Spacing.space1)
        }
      }
      if let before = page.nextBefore, model.refreshFailure == nil {
        if let failure = model.loadMoreFailure {
          retryRow(failure.message, identifier: "history.more-retry") { await model.loadMore() }
        } else {
          ProgressView("Loading more history")
            .listRowBackground(PutioTheme.Colors.background)
            .task(
              id: PageRequest(
                before: before, generation: model.generation,
                isRefreshing: model.isRefreshing, epoch: model.paginationEpoch)
            ) {
              await model.loadMore()
            }
        }
      }
    }
    .listStyle(.plain)
    .disabled(isBusy)
    .refreshable { await model.refresh() }
  }

  private func retryRow(
    _ message: String, identifier: String,
    retry: @escaping @MainActor @Sendable () async -> Void
  ) -> some View {
    VStack(alignment: .leading, spacing: PutioTheme.Spacing.space2) {
      Text(message)
        .putioFont(PutioTheme.Typography.caption)
        .foregroundStyle(PutioTheme.Colors.textSecondary)
      Button("Try again") { Task { await retry() } }
        .accessibilityIdentifier(identifier)
    }
    .listRowBackground(PutioTheme.Colors.background)
  }

  private func eventRow(_ event: PutioHistoryEventItem) -> some View {
    Group {
      if event.fileID != nil {
        Button {
          Task { await model.openFile(event: event) }
        } label: {
          PutioHistoryRow(event: event, isOpening: model.openingEventID == event.id)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
      } else {
        PutioHistoryRow(event: event, isOpening: false)
      }
    }
    .accessibilityIdentifier("history.item.\(event.id)")
    .contextMenu {
      Button("Delete Event", role: .destructive) { Task { await model.delete(eventID: event.id) } }
    }
    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
      Button("Delete", role: .destructive) { Task { await model.delete(eventID: event.id) } }
    }
    .accessibilityAction(named: "Delete Event") { Task { await model.delete(eventID: event.id) } }
  }

  private struct PageRequest: Equatable {
    let before: Int
    let generation: UInt64
    let isRefreshing: Bool
    let epoch: UInt64
  }
}

private struct PutioHistoryRow: View {
  let event: PutioHistoryEventItem
  let isOpening: Bool

  @Environment(\.dynamicTypeSize) private var dynamicTypeSize
  @Environment(\.locale) private var locale
  @PutioScaledMetric(PutioTheme.ScaledMetrics.contentGap) private var contentGap
  @PutioScaledMetric(PutioTheme.ScaledMetrics.compactContentGap) private var textGap
  @PutioScaledMetric(PutioMetricRole(value: 6, relativeTo: .caption)) private var separatorGap

  var body: some View {
    let presentation = PutioHistoryEventPresentation(event)
    HStack(spacing: contentGap) {
      PutioIconView(
        presentation.icon,
        size: PutioMetricRole(value: PutioTheme.Typography.sizeLg, relativeTo: .body)
      )
      .foregroundStyle(PutioTheme.Colors.textSecondary)
      .accessibilityHidden(true)
      VStack(alignment: .leading, spacing: textGap) {
        Text(presentation.name)
          .putioFont(PutioTheme.Typography.body)
          .foregroundStyle(PutioTheme.Colors.textPrimary)
          .lineLimit(dynamicTypeSize.isAccessibilitySize ? 3 : 1)
          .truncationMode(.middle)
        HStack(alignment: .firstTextBaseline, spacing: separatorGap) {
          Text(presentation.kind)
            .putioFont(PutioTheme.Typography.caption)
            .foregroundStyle(
              presentation.tone == .destructive
                ? PutioTheme.Colors.destructive : PutioTheme.Colors.textSecondary
            )
            .lineLimit(dynamicTypeSize > .large ? nil : 1)
            .fixedSize(horizontal: false, vertical: true)
          Text(verbatim: "·")
            .putioFont(PutioTheme.Typography.caption)
            .foregroundStyle(PutioTheme.Colors.textSecondary)
            .accessibilityHidden(true)
          Text(PutioHistoryEventPresentation.time(event.createdAt, locale: locale))
            .putioFont(PutioTheme.Typography.numeric)
            .foregroundStyle(PutioTheme.Colors.textSecondary)
            .lineLimit(1)
            .fixedSize()
        }
      }
      Spacer(minLength: 0)
      if isOpening { ProgressView().accessibilityLabel("Opening file") }
    }
    .accessibilityElement(children: .combine)
  }
}
