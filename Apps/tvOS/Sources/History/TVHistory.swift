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
  @FocusState private var focusedEventID: Int?
  private let locale: Locale

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
      .onChange(of: focusedEventID) { _, id in
        if let id { shownEventID = id }
      }
      .onChange(of: model.fileGone) { _, gone in
        guard gone != nil else { return }
        model.dismissFileGone()
        showFileGone()
      }
      .onChange(of: model.failedMutation) { _, failed in
        guard failed == .clear else { return }
        model.dismissMutationFailure()
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
        titleVisibility: .hidden)
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
      } else {
        HStack(alignment: .top, spacing: PutioTheme.TV.Spacing.large) {
          list(page)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
          if let event = shownEvent(in: page) {
            TVHistoryPanel(
              event: event, now: groupingDate, locale: locale,
              isOpening: model.openingEventID == event.id,
              play: { play(event) }, goToFolder: { goToFolder(event) }
            )
            .frame(width: TVHistoryLayout.panelWidth)
            .frame(maxHeight: .infinity, alignment: .top)
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
            TVHistoryMoreFailedRow { await model.loadMore() }
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

  private func eventRow(_ event: PutioHistoryEventItem) -> some View {
    Button {
      play(event)
    } label: {
      TVHistoryEventRow(
        event: event, isOpening: model.openingEventID == event.id, locale: locale)
    }
    .tvRowOpen(focusedEventID == nil && shownEventID == event.id)
    .focused($focusedEventID, equals: event.id)
    .disabled(model.mutation != nil)
    .accessibilityIdentifier("history.item.\(event.id)")
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

private struct TVHistoryPanel: View {
  let event: PutioHistoryEventItem
  let now: Date
  let locale: Locale
  let isOpening: Bool
  let play: () -> Void
  let goToFolder: () -> Void

  var body: some View {
    let presentation = PutioHistoryEventPresentation(event)
    VStack(alignment: .leading, spacing: PutioTheme.TV.Spacing.medium) {
      HStack(spacing: PutioTheme.TV.Spacing.medium) {
        Image(putioIcon: presentation.icon)
          .resizable()
          .scaledToFit()
          .frame(width: TVHistoryLayout.tileIconSize, height: TVHistoryLayout.tileIconSize)
          .foregroundStyle(PutioTheme.Colors.accent)
          .frame(width: TVHistoryLayout.tileWidth, height: TVHistoryLayout.tileHeight)
          .background(
            PutioTheme.Colors.surfaceActive,
            in: RoundedRectangle(cornerRadius: PutioTheme.TV.radius, style: .continuous)
          )
          .accessibilityHidden(true)
        VStack(alignment: .leading, spacing: PutioTheme.TV.Spacing.xxs) {
          Text(presentation.name)
            .putioFont(PutioTheme.TV.Typography.label)
            .foregroundStyle(PutioTheme.TV.Colors.textPrimary)
            .lineLimit(1)
          TVHistoryEventLine(
            event: event, presentation: presentation, locale: locale,
            secondary: AnyShapeStyle(PutioTheme.TV.Colors.textSecondary))
        }
      }
      Grid(
        alignment: .leading, horizontalSpacing: PutioTheme.TV.Spacing.medium,
        verticalSpacing: PutioTheme.TV.Spacing.xs
      ) {
        if let size = presentation.sizeBytes, event.fileID != nil {
          fact(
            String(localized: "Size", bundle: .putioCore),
            PutioFileRowModel.sizeText(bytes: size, locale: locale))
        } else {
          fact(String(localized: "Date", bundle: .putioCore), day)
        }
      }
      if presentation.offersFileActions {
        VStack(alignment: .leading, spacing: PutioTheme.TV.Spacing.xs) {
          action(String(localized: "Play", bundle: .putioCore), icon: .playFill, play)
            .accessibilityIdentifier("history.panel.play")
          action(
            String(localized: "Go to folder", bundle: .putioCore), icon: .folder, goToFolder
          )
          .accessibilityIdentifier("history.panel.folder")
        }
        .buttonStyle(TVRowButtonStyle())
        .disabled(isOpening)
      }
    }
    .padding(PutioTheme.TV.Spacing.medium)
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    .background(
      PutioTheme.Colors.surface,
      in: RoundedRectangle(cornerRadius: TVHistoryLayout.panelRadius, style: .continuous)
    )
    .padding(.bottom, TVRowLayout.bottomClearance)
    .focusSection()
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("history.panel")
  }

  private var day: String {
    PutioHistoryDay.group([event], now: now, locale: locale).first?.title ?? ""
  }

  private func fact(_ label: String, _ value: String) -> some View {
    GridRow {
      Text(label)
        .foregroundStyle(PutioTheme.TV.Colors.textSecondary)
      Text(value)
        .foregroundStyle(PutioTheme.TV.Colors.textPrimary)
    }
    .putioFont(PutioTheme.TV.Typography.caption)
  }

  private func action(
    _ title: String, icon: PutioIcon, _ perform: @escaping () -> Void
  ) -> some View {
    Button(action: perform) {
      HStack(spacing: PutioTheme.TV.Spacing.small) {
        Image(putioIcon: icon)
          .resizable()
          .scaledToFit()
          .frame(width: TVRowLayout.iconSize, height: TVRowLayout.iconSize)
          .foregroundStyle(.putioRowIcon)
          .accessibilityHidden(true)
        Text(title)
          .putioFont(PutioTheme.TV.Typography.body)
          .foregroundStyle(.putioRowPrimary)
      }
      .tvRowPadding()
    }
  }
}

private struct TVHistoryMoreFailedRow: View {
  let retry: @MainActor () async -> Void

  var body: some View {
    HStack(spacing: PutioTheme.TV.Spacing.small) {
      Image(putioIcon: .warningCircle)
        .resizable()
        .scaledToFit()
        .frame(width: TVRowLayout.iconSize, height: TVRowLayout.iconSize)
        .foregroundStyle(PutioTheme.TV.Colors.textSecondary)
        .accessibilityHidden(true)
      Text(String(localized: "Couldn’t load more activity.", bundle: .putioCore))
        .putioFont(PutioTheme.TV.Typography.body)
        .foregroundStyle(PutioTheme.TV.Colors.textPrimary)
      Spacer(minLength: PutioTheme.TV.Spacing.medium)
      PutioButton(String(localized: "Try again", bundle: .putioCore), tier: .secondary) {
        Task { await retry() }
      }
      .accessibilityIdentifier("history.more-retry")
    }
    .padding(.horizontal, PutioTheme.TV.Spacing.medium)
    .focusSection()
    .accessibilityIdentifier("history.more-error")
  }
}

enum TVHistoryLayout {
  static let panelWidth: CGFloat = 640
  static let panelRadius: CGFloat = 40
  static let tileWidth: CGFloat = 160
  static let tileHeight: CGFloat = 90
  static let tileIconSize: CGFloat = 40
}
