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
  @State private var confirmAlert: PutioConfirmAlert?
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
            ToolbarItem(placement: .primaryAction) { moreMenu }
          }
        }
        .putioConfirmAlert($confirmAlert)
        .putioAlert(
          String(localized: "Couldn’t clear history"),
          isPresented: Binding(
            get: { model.failedMutation == .clear },
            set: { if !$0 { model.dismissMutationFailure() } }),
          message: String(localized: "Check your connection and try again."),
          actions: [
            PutioAlertAction(
              String(localized: "OK"), tier: .cancel, id: "history.clear-failed.ok")
          ]
        )
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
        .task(id: isLoading) { await model.loadIfNeeded() }
        .task(id: isOffline) { await retryWhileOffline() }
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
    .frame(maxWidth: path.isEmpty ? HistoryLayout.readableWidth : .infinity)
    .frame(maxWidth: .infinity)
    .background(PutioTheme.Colors.background)
    .putioToast($toast)
  }

  private var isBusy: Bool { model.mutation != nil || model.openingEventID != nil }

  private var moreMenu: some View {
    Menu {
      PutioItemMenuContent(
        PutioItemMenu([
          [
            PutioItemAction(
              id: "clear-history",
              title: String(localized: "Clear history"),
              icon: .trash,
              role: .destructive
            ) {
              confirmAlert = clearAlert
            }
          ]
        ])
      )
    } label: {
      Label("More", systemImage: "ellipsis")
    }
    .disabled(isBusy || !model.deletingEventIDs.isEmpty)
    .accessibilityIdentifier("history.menu")
  }

  private var clearAlert: PutioConfirmAlert {
    PutioConfirmAlert(
      title: String(localized: "Clear history?"),
      message: String(localized: "This removes all activity from your put.io history."),
      confirmTitle: String(localized: "Clear")
    ) {
      Task { await model.clear() }
    }
  }

  private var isLoading: Bool {
    if case .loading = model.state { return true }
    return false
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
      await model.refresh()
      attempt += 1
    }
  }

  @ViewBuilder
  private var content: some View {
    switch model.state {
    case .loading:
      PutioLoadingStateView(title: String(localized: "Loading history"), titleVisibility: .hidden)
    case .failed(let failure):
      scrollableState {
        PutioErrorStateView(
          title: failure.isOffline
            ? PutioScreenErrorKind.offline.title : String(localized: "Couldn’t load history"),
          message: failure.isOffline
            ? PutioScreenErrorKind.offline.message : PutioScreenErrorKind.failed.message,
          retryTitle: String(localized: "Try again"), retryIdentifier: "history.retry"
        ) {
          model.retryFailedLoad()
        }
      }
    case .loaded:
      let page = model.page ?? PutioHistoryPage(items: [], nextBefore: nil)
      if page.items.isEmpty, page.nextBefore == nil,
        model.refreshFailure == nil, model.mutationFailure == nil,
        model.openFailure.map(\.isNotFound) ?? true
      {
        scrollableState {
          PutioEmptyStateView.history
            .accessibilityIdentifier("history.empty")
        }
      } else {
        historyList(page)
      }
    }
  }

  private func scrollableState<Content: View>(@ViewBuilder _ state: () -> Content) -> some View {
    let content = state()
    return GeometryReader { geometry in
      ScrollView {
        content
          .frame(minHeight: geometry.size.height)
      }
      .scrollBounceBehavior(.always)
      .refreshable { await Task { await model.refresh() }.value }
    }
  }

  private func historyList(_ page: PutioHistoryPage) -> some View {
    List {
      if let failure = model.refreshFailure {
        retryRow(failure.message, identifier: "history.retry") { await model.refresh() }
      }
      if let failure = model.openFailure, !failure.isNotFound {
        retryRow(failure.message, identifier: "history.open-retry") { await model.retryOpen() }
      }
      let days = PutioHistoryDay.group(page.items, now: groupingDate, locale: locale)
      let pageRequest = page.nextBefore.map {
        PageRequest(
          before: $0, generation: model.generation,
          isRefreshing: model.isRefreshing, epoch: model.paginationEpoch)
      }
      let prefetchIDs: Set<PutioHistoryEventItem.ID> =
        pageRequest == nil
        ? [] : Set(days.flatMap(\.items).suffix(Self.prefetchDistance).map(\.id))
      ForEach(days) { day in
        PutioHistoryDayHeader(title: day.title)
          .listRowInsets(.vertical, 0)
          .listRowSeparator(.hidden)
          .listRowBackground(PutioTheme.Colors.background)
        ForEach(day.items) { event in
          eventRow(event)
            .padding(.trailing, PutioTheme.Spacing.space1)
            .listRowInsets(.vertical, PutioTheme.Spacing.space2)
            .listRowInsets(.trailing, 0)
            .alignmentGuide(.listRowSeparatorTrailing) { $0[.trailing] }
            .listRowSeparator(
              event.id == day.items.last?.id ? .hidden : .automatic, edges: .bottom
            )
            .listRowBackground(PutioTheme.Colors.background)
            .task(id: prefetchIDs.contains(event.id) ? pageRequest : nil) {
              guard prefetchIDs.contains(event.id), model.loadMoreFailure == nil else { return }
              await model.loadMore()
            }
        }
      }
      if let pageRequest, model.refreshFailure == nil {
        if model.loadMoreFailure != nil {
          PutioNextPageFailedFooter(
            message: String(localized: "Couldn’t load more history."),
            retryIdentifier: "history.more-retry"
          ) {
            Task { await model.loadMore() }
          }
          .accessibilityElement(children: .contain)
          .accessibilityIdentifier("history.more-error")
          .listRowInsets(
            EdgeInsets(
              top: PutioTheme.Spacing.space1, leading: 0, bottom: PutioTheme.Spacing.space1,
              trailing: 0)
          )
          .listRowSeparator(.hidden)
          .listRowBackground(PutioTheme.Colors.background)
        } else {
          ProgressView()
            .tint(PutioTheme.Colors.textSecondary)
            .accessibilityLabel(String(localized: "Loading more history"))
            .frame(maxWidth: .infinity)
            .padding(.vertical, PutioTheme.Spacing.space3)
            .accessibilityIdentifier("history.more")
            .listRowInsets(.vertical, 0)
            .listRowSeparator(.hidden)
            .listRowBackground(PutioTheme.Colors.background)
            .task(id: pageRequest) {
              await model.loadMore()
            }
        }
      }
    }
    .listStyle(.plain)
    .environment(\.defaultMinListRowHeight, 0)
    .disabled(isBusy)
    .refreshable { await model.refresh() }
    .accessibilityIdentifier("history.list")
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
    .swipeActions(edge: .trailing, allowsFullSwipe: true) {
      Button(role: .destructive) {
        delete(event)
      } label: {
        Label {
          Text("Delete")
        } icon: {
          Image(putioIcon: .trash)
        }
        .labelStyle(.iconOnly)
      }
      .tint(PutioTheme.Colors.destructive)
      .accessibilityIdentifier("history.swipe.delete")
    }
  }

  private func delete(_ event: PutioHistoryEventItem) {
    let started = withAnimation { model.beginDelete(eventID: event.id) }
    guard started else { return }
    Task {
      guard await model.finishDelete(eventID: event.id) != nil else { return }
      toast = PutioToast(String(localized: "Couldn’t delete"), icon: .warning, width: .fit)
    }
  }

  private static let prefetchDistance = 5

  private struct PageRequest: Equatable {
    let before: Int
    let generation: UInt64
    let isRefreshing: Bool
    let epoch: UInt64
  }
}

private struct PutioHistoryDayHeader: View {
  let title: String

  @PutioScaledMetric(PutioMetricRole(value: 14, relativeTo: .caption)) private var topGap
  @PutioScaledMetric(PutioTheme.ScaledMetrics.compactContentGap) private var bottomGap

  var body: some View {
    Text(title)
      .putioFont(PutioTheme.Typography.caption)
      .foregroundStyle(PutioTheme.Colors.textSecondary)
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(.top, topGap)
      .padding(.bottom, bottomGap)
      .accessibilityAddTraits(.isHeader)
  }
}

private enum HistoryLayout {
  static let readableWidth = PutioTheme.Spacing.space8 + PutioTheme.Spacing.space6
}

private struct PutioHistoryRow: View {
  let event: PutioHistoryEventItem
  let isOpening: Bool

  @Environment(\.dynamicTypeSize) private var dynamicTypeSize
  @Environment(\.locale) private var locale
  @PutioScaledMetric(PutioMetricRole(value: 32, relativeTo: .body)) private var leadWidth
  @PutioScaledMetric(PutioMetricRole(value: 12, relativeTo: .body)) private var contentGap
  @PutioScaledMetric(PutioMetricRole(value: 44, relativeTo: .body)) private var minContentHeight
  @PutioScaledMetric(PutioTheme.ScaledMetrics.compactContentGap) private var textGap
  @PutioScaledMetric(PutioMetricRole(value: 6, relativeTo: .caption)) private var separatorGap
  @PutioScaledMetric(PutioMetricRole(value: 3, relativeTo: .caption)) private var timeSpaceKern

  private static let timeFont = PutioTabularFontRole(
    base: PutioFontRole(
      fontName: PutioTheme.Typography.mono.fontName,
      size: PutioTheme.Typography.sizeXs,
      lineHeight: PutioTheme.Typography.mono.lineHeight,
      textStyle: .caption))

  var body: some View {
    let presentation = PutioHistoryEventPresentation(event)
    HStack(spacing: contentGap) {
      PutioIconView(
        presentation.icon,
        size: PutioMetricRole(value: PutioTheme.Typography.sizeLg, relativeTo: .body)
      )
      .foregroundStyle(PutioTheme.Colors.textSecondary)
      .frame(width: leadWidth)
      .accessibilityHidden(true)
      VStack(alignment: .leading, spacing: textGap) {
        Text(presentation.name)
          .putioFont(PutioTheme.Typography.body)
          .foregroundStyle(PutioTheme.Colors.textPrimary)
          .lineLimit(dynamicTypeSize.isAccessibilitySize ? 3 : 1)
          .truncationMode(.middle)
        ViewThatFits(in: .horizontal) {
          HStack(alignment: .firstTextBaseline, spacing: separatorGap) {
            kindText(presentation).fixedSize()
            Text(verbatim: "·")
              .putioFont(PutioTheme.Typography.caption)
              .foregroundStyle(PutioTheme.Colors.textSecondary)
              .accessibilityHidden(true)
            timeText.fixedSize()
          }
          VStack(alignment: .leading, spacing: 0) {
            kindText(presentation).fixedSize(horizontal: false, vertical: true)
            timeText
          }
        }
      }
      Spacer(minLength: 0)
      if isOpening { ProgressView().accessibilityLabel("Opening file") }
    }
    .frame(minHeight: minContentHeight)
    .accessibilityElement(children: .combine)
  }

  private func kindText(_ presentation: PutioHistoryEventPresentation) -> some View {
    Text(presentation.kind)
      .putioFont(PutioTheme.Typography.caption)
      .foregroundStyle(
        presentation.tone == .destructive
          ? PutioTheme.Colors.destructiveText : PutioTheme.Colors.textSecondary
      )
  }

  private var compactTime: AttributedString {
    var time = AttributedString(PutioHistoryEventPresentation.time(event.createdAt, locale: locale))
    var start = time.startIndex
    while let space = time[start...].range(of: " ") {
      time[space].kern = -timeSpaceKern
      start = space.upperBound
    }
    return time
  }

  private var timeText: some View {
    Text(compactTime)
      .putioFont(Self.timeFont)
      .foregroundStyle(PutioTheme.Colors.textSecondary)
      .lineLimit(1)
  }
}
