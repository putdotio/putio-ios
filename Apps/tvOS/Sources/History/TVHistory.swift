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
  private let locale: Locale

  init(runtime: PutioRuntime, open: @escaping (PutioFileItem) -> Void) {
    self.init(
      model: PutioHistoryModel(actions: PutioHistoryActions(runtime: runtime)), open: open)
  }

  init(
    model: PutioHistoryModel, now: Date = .now, locale: Locale = .current,
    open: @escaping (PutioFileItem) -> Void
  ) {
    self.open = open
    self.locale = locale
    _model = State(initialValue: model)
    _groupingDate = State(initialValue: now)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: PutioTheme.TV.Spacing.medium) {
      TVScreenHeader(title: "History") {
        if let page = model.page, !page.items.isEmpty || page.nextBefore != nil {
          PutioButton("Clear", tier: .secondary) { confirmsClear = true }
            .disabled(model.mutation != nil)
            .accessibilityIdentifier("history.clear")
        }
      }
      content
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    .tvOverscanPadding()
    .background(PutioTheme.Colors.background.ignoresSafeArea())
    .alert("Clear your history?", isPresented: $confirmsClear) {
      Button("Clear history", role: .destructive) { Task { await model.clear() } }
        .accessibilityIdentifier("history.clear-confirm")
      Button("Cancel", role: .cancel) {}
    } message: {
      Text("Every event will be removed from your history. Your files will stay in place.")
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
    .onChange(of: model.fileGone) { _, gone in
      guard gone != nil else { return }
      model.dismissFileGone()
      toast = PutioToast("File not found", icon: .warning, width: .fit)
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
      PutioLoadingStateView(title: "Loading history")
    case .failed(let failure):
      PutioErrorStateView(
        title: "Could not load history", message: failure.message,
        retryTitle: "Try again", retryIdentifier: "history.retry"
      ) {
        Task { await model.refresh() }
      }
    case .loaded(let page):
      if page.items.isEmpty, page.nextBefore == nil, model.refreshFailure == nil,
        model.mutationFailure == nil, model.openFailure == nil
      {
        PutioEmptyStateView.history
          .accessibilityIdentifier("history.empty")
      } else {
        list(page)
      }
    }
  }

  private func list(_ page: PutioHistoryPage) -> some View {
    TVRowList {
      if let failure = model.refreshFailure {
        TVRetrySection(message: failure.message, identifier: "history.refresh-retry") {
          await model.refresh()
        }
      }
      if let failure = model.mutationFailure {
        TVRetrySection(message: failure.message, identifier: "history.mutation-retry") {
          await model.retryMutation()
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
      if model.mutation != nil {
        ProgressView("Updating history")
          .accessibilityIdentifier("history.progress")
      }
      ForEach(PutioHistoryDay.group(page.items, now: groupingDate, locale: locale)) { day in
        TVSectionHeader(title: day.title)
        ForEach(day.items) { event in
          eventRow(event)
        }
      }
      if let before = page.nextBefore, model.refreshFailure == nil {
        if let failure = model.loadMoreFailure {
          TVRetrySection(message: failure.message, identifier: "history.more-retry") {
            await model.loadMore()
          }
        } else {
          ProgressView("Loading more history")
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
  }

  @ViewBuilder
  private func eventRow(_ event: PutioHistoryEventItem) -> some View {
    let row = TVHistoryEventRow(
      event: event, isOpening: model.openingEventID == event.id, locale: locale)
    if let fileID = event.fileID, fileID.rawValue > 0 {
      Button {
        Task { await model.openFile(event: event) }
      } label: {
        row
      }
      .disabled(model.mutation != nil)
      .accessibilityIdentifier("history.item.\(event.id)")
    } else {
      row.accessibilityIdentifier("history.item.\(event.id)")
    }
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
      VStack(alignment: .leading, spacing: PutioTheme.TV.Spacing.xs) {
        Text(presentation.name)
          .putioFont(PutioTheme.TV.Typography.body)
          .foregroundStyle(.putioRowPrimary)
          .lineLimit(1)
          .truncationMode(.middle)
        HStack(spacing: PutioTheme.TV.Spacing.xs) {
          Text(presentation.kind)
            .foregroundStyle(
              presentation.tone == .destructive
                ? AnyShapeStyle(PutioTheme.Colors.destructiveText)
                : AnyShapeStyle(.putioRowSecondary))
          Text(verbatim: "·").accessibilityHidden(true)
            .foregroundStyle(.putioRowSecondary)
          Text(PutioHistoryEventPresentation.time(event.createdAt, locale: locale))
            .foregroundStyle(.putioRowSecondary)
        }
        .putioFont(PutioTheme.TV.Typography.caption)
        .lineLimit(1)
      }
      Spacer(minLength: PutioTheme.TV.Spacing.small)
      if isOpening { ProgressView().accessibilityLabel("Opening file") }
    }
    .tvRowPadding()
    .accessibilityElement(children: .combine)
  }
}
