import PutioCore
import SwiftUI

struct TVHistoryView: View {
  let open: (PutioFileItem) -> Void

  @Environment(\.scenePhase) private var scenePhase
  @Environment(\.tvHistoryActivations) private var activations
  @State private var model: PutioHistoryModel
  @State private var groupingDate: Date
  @State private var confirmsClear = false
  @State private var toast: PutioToast?
  @State private var shownEventID: Int?
  @State private var showsPanel = true
  @FocusState private var focus: Focus?
  private let locale: Locale

  private enum Focus: Hashable {
    case event(Int)
    case clear
    case moreRetry
  }

  init(runtime: PutioRuntime, open: @escaping (PutioFileItem) -> Void) {
    self.init(
      model: PutioHistoryModel(actions: PutioHistoryActions(runtime: runtime)), open: open)
  }

  init(
    model: PutioHistoryModel, now: Date = .now, locale: Locale = .current,
    shownEventID: Int? = nil, open: @escaping (PutioFileItem) -> Void
  ) {
    self.open = open
    self.locale = locale
    _model = State(initialValue: model)
    _groupingDate = State(initialValue: now)
    _shownEventID = State(initialValue: shownEventID)
  }

  var body: some View {
    content
      .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
      .tvOverscanPadding()
      .background(PutioTheme.Colors.background.ignoresSafeArea())
      .alert(
        String(localized: "Clear history?", bundle: .putioCore), isPresented: $confirmsClear
      ) {
        Button(String(localized: "Clear", bundle: .putioCore), role: .destructive) {
          Task { await model.clear() }
        }
        .accessibilityIdentifier("history.clear-confirm")
        Button(String(localized: "Cancel", bundle: .putioCore), role: .cancel) {}
          .accessibilityIdentifier("history.clear-cancel")
      } message: {
        Text(
          String(
            localized: "This removes all activity from your put.io history.", bundle: .putioCore))
      }
      .task { await model.loadIfNeeded() }
      .onChange(of: activations) {
        guard case .loaded = model.state else { return }
        Task { await model.refresh() }
      }
      .onDisappear { model.cancelOpen() }
      .onReceive(NotificationCenter.default.publisher(for: .NSCalendarDayChanged)) { _ in
        groupingDate = .now
      }
      .onChange(of: scenePhase) { _, phase in
        if phase == .active { groupingDate = .now }
      }
      .onChange(of: focus) { _, focus in
        switch focus {
        case .event(let id):
          shownEventID = id
          showsPanel = true
        case .moreRetry:
          showsPanel = false
        case .clear, nil:
          break
        }
      }
      .onChange(of: model.fileGone) { _, gone in
        guard gone != nil else { return }
        model.dismissFileGone()
        showFileGone()
      }
      .onChange(of: model.failedMutation) { _, failed in
        guard failed == .clear else { return }
        model.dismissMutationFailure()
        focus = .clear
        toast = PutioToast(
          String(localized: "Couldn’t clear history", bundle: .putioCore), icon: .warning,
          width: .fit)
      }
      .putioToast($toast)
      .onChange(of: model.openedFile) { _, file in
        guard let file else { return }
        model.clearOpenedFile()
        open(file)
      }
  }

  @ViewBuilder
  private var content: some View {
    switch model.state {
    case .loading:
      PutioLoadingStateView(
        title: String(localized: "Loading history", bundle: .putioCore),
        titleVisibility: .hidden
      )
      .frame(maxWidth: .infinity, maxHeight: .infinity)
    case .failed:
      PutioErrorStateView(
        title: String(localized: "Couldn’t load your history.", bundle: .putioCore),
        message: String(
          localized: "Check your internet connection and try again.", bundle: .putioCore),
        retryTitle: String(localized: "Try again", bundle: .putioCore),
        retryIdentifier: "history.retry"
      ) {
        Task { await model.refresh() }
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
    case .loaded:
      let page = model.page ?? PutioHistoryPage(items: [], nextBefore: nil)
      if page.items.isEmpty, page.nextBefore == nil, model.refreshFailure == nil,
        model.openFailure == nil
      {
        PutioEmptyStateView(
          kaomoji: .nothingYet,
          title: String(localized: "No activity yet", bundle: .putioCore),
          message: String(
            localized: "Files you watch, upload or share show up here.", bundle: .putioCore)
        )
        .accessibilityIdentifier("history.empty")
        .frame(maxWidth: .infinity, maxHeight: .infinity)
      } else {
        HStack(alignment: .top, spacing: PutioTheme.TV.Spacing.large) {
          list(page)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
          if showsPanel, let event = shownEvent(in: page) {
            panel(event)
          } else {
            Color.clear.frame(width: TVDetailPanelLayout.width)
          }
        }
      }
    }
  }

  private func shownEvent(in page: PutioHistoryPage) -> PutioHistoryEventItem? {
    page.items.first { $0.id == shownEventID } ?? page.items.first
  }

  private func list(_ page: PutioHistoryPage) -> some View {
    VStack(alignment: .leading, spacing: PutioTheme.TV.Spacing.small) {
      HStack {
        Text(String(localized: "Activity", bundle: .putioCore))
          .putioFont(PutioTheme.TV.Typography.caption)
          .foregroundStyle(PutioTheme.TV.Colors.textSecondary)
          .accessibilityAddTraits(.isHeader)
        Spacer(minLength: PutioTheme.TV.Spacing.medium)
        PutioButton(
          String(localized: "Clear history", bundle: .putioCore), icon: .trash, tier: .secondary
        ) { confirmsClear = true }
        .disabled(model.mutation != nil)
        .focused($focus, equals: .clear)
        .accessibilityIdentifier("history.clear")
      }
      .focusSection()
      TVRowList {
        if let failure = model.refreshFailure {
          TVRetrySection(message: failure.message, identifier: "history.refresh-retry") {
            await model.refresh()
          }
        }
        if let failure = model.openFailure {
          TVRetrySection(
            message: failure.message, identifier: "history.open-retry",
            dismiss: { model.cancelOpen() }
          ) {
            await model.retryOpen()
          }
        }
        ForEach(PutioHistoryDay.group(page.items, now: groupingDate, locale: locale)) { day in
          TVSectionHeader(title: day.title)
          ForEach(day.items) { event in
            eventRow(event)
          }
        }
        if let before = page.nextBefore, model.refreshFailure == nil {
          if model.loadMoreFailure != nil {
            TVLoadMoreFailedRow(
              message: String(localized: "Couldn’t load more activity.", bundle: .putioCore),
              identifier: "history.more-retry", focus: $focus, focusValue: .moreRetry
            ) { await model.loadMore() }
          } else {
            ProgressView()
              .accessibilityLabel(String(localized: "Loading more history", bundle: .putioCore))
              .frame(maxWidth: .infinity)
              .accessibilityIdentifier("history.load-more")
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
      .focusSection()
    }
  }

  private func panel(_ event: PutioHistoryEventItem) -> some View {
    let presentation = PutioHistoryEventPresentation(event)
    return TVDetailPanel(
      icon: presentation.icon, title: presentation.name, identifier: "history.panel"
    ) {
      TVHistoryEventLine(
        event: event, presentation: presentation, locale: locale,
        secondary: AnyShapeStyle(PutioTheme.TV.Colors.textSecondary))
    } facts: {
      if let size = presentation.sizeBytes, size > 0, event.fileID != nil {
        TVDetailFact(
          label: String(localized: "Size", bundle: .putioCore),
          value: PutioFileRowModel.sizeText(bytes: size, locale: locale))
      } else {
        TVDetailFact(
          label: String(localized: "Date", bundle: .putioCore),
          value: PutioHistoryDay.group([event], now: groupingDate, locale: locale).first?.title
            ?? "")
      }
    } actions: {
      if presentation.offersFileActions {
        TVDetailAction(title: String(localized: "Play", bundle: .putioCore), icon: .playFill) {
          play(event)
        }
        .accessibilityIdentifier("history.panel.play")
        TVDetailAction(
          title: String(localized: "Go to folder", bundle: .putioCore), icon: .folder
        ) {
          goToFolder(event)
        }
        .accessibilityIdentifier("history.panel.folder")
      }
    }
    .disabled(model.openingEventID == event.id)
  }

  private func eventRow(_ event: PutioHistoryEventItem) -> some View {
    Button {
      play(event)
    } label: {
      TVHistoryEventRow(
        event: event, isOpening: model.openingEventID == event.id, locale: locale)
    }
    .tvRowOpen(!isEventFocused && showsPanel && shownEventID == event.id)
    .focused($focus, equals: .event(event.id))
    .disabled(model.mutation != nil)
    .accessibilityIdentifier("history.item.\(event.id)")
  }

  private var isEventFocused: Bool {
    if case .event = focus { return true }
    return false
  }

  private func play(_ event: PutioHistoryEventItem) {
    guard PutioHistoryEventPresentation(event).offersFileActions else { return }
    guard hasFile(event) else { return showFileGone() }
    Task { await model.openFile(event: event) }
  }

  private func goToFolder(_ event: PutioHistoryEventItem) {
    guard hasFile(event) else { return showFileGone() }
    Task { await model.openFolder(event: event) }
  }

  private func hasFile(_ event: PutioHistoryEventItem) -> Bool {
    event.fileID.map { $0.rawValue > 0 } ?? false
  }

  private func showFileGone() {
    toast = PutioToast(
      String(localized: "File not found", bundle: .putioCore), icon: .warning, width: .fit)
  }

  private struct PageRequest: Equatable {
    let before: Int
    let generation: UInt64
    let isRefreshing: Bool
    let epoch: UInt64
  }
}

struct TVHistoryEventRow: View {
  let event: PutioHistoryEventItem
  var isOpening = false
  var locale: Locale = .current

  var body: some View {
    let presentation = PutioHistoryEventPresentation(event)
    HStack(spacing: PutioTheme.TV.Spacing.small) {
      Image(putioIcon: presentation.icon)
        .resizable()
        .scaledToFit()
        .frame(width: TVRowLayout.iconSize, height: TVRowLayout.iconSize)
        .foregroundStyle(.putioRowIcon)
        .accessibilityHidden(true)
      VStack(alignment: .leading, spacing: PutioTheme.TV.Spacing.xxs) {
        Text(presentation.name)
          .putioFont(PutioTheme.TV.Typography.body)
          .foregroundStyle(.putioRowPrimary)
          .lineLimit(1)
          .truncationMode(.middle)
        TVHistoryEventLine(event: event, presentation: presentation, locale: locale)
      }
      Spacer(minLength: PutioTheme.TV.Spacing.small)
      if isOpening {
        ProgressView()
          .accessibilityLabel(String(localized: "Opening file", bundle: .putioCore))
      }
    }
    .tvRowPadding()
    .accessibilityElement(children: .combine)
  }
}

private struct TVHistoryEventLine: View {
  let event: PutioHistoryEventItem
  let presentation: PutioHistoryEventPresentation
  let locale: Locale
  var secondary: AnyShapeStyle = AnyShapeStyle(.putioRowSecondary)

  var body: some View {
    HStack(spacing: PutioTheme.TV.Spacing.xs) {
      Text(presentation.kind)
        .foregroundStyle(
          presentation.tone == .destructive
            ? AnyShapeStyle(PutioTheme.Colors.destructiveText) : secondary)
      Text(verbatim: "·")
        .foregroundStyle(secondary)
        .accessibilityHidden(true)
      Text(PutioHistoryEventPresentation.time(event.createdAt, locale: locale))
        .putioFont(PutioTheme.TV.Typography.numeric)
        .foregroundStyle(secondary)
    }
    .putioFont(PutioTheme.TV.Typography.caption)
    .lineLimit(1)
  }
}
