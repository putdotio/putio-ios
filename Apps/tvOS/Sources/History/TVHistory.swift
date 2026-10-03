import PutioCore
import SwiftUI

/// The shipped TV app lists only the events that lead to a file you can
/// watch: completed transfers and shares.
enum TVHistoryPresentation {
  static func isShown(_ event: PutioHistoryEventItem) -> Bool {
    switch event.kind {
    case .transferCompleted, .fileShared: true
    default: false
    }
  }

  static func sections(
    _ page: PutioHistoryPage, now: Date, calendar: Calendar = .current
  ) -> [PutioHistorySection] {
    PutioHistorySection.group(page.items.filter(isShown), now: now, calendar: calendar)
  }

  /// Nothing to show and nothing left to load. A page of hidden events with
  /// a continuation is still loading, not empty.
  static func isEmpty(_ page: PutioHistoryPage) -> Bool {
    page.nextBefore == nil && !page.items.contains(where: isShown)
  }

  static func title(_ event: PutioHistoryEventItem) -> String {
    switch event.kind {
    case .transferCompleted(let name, _, _), .fileShared(let name, _, _): name
    default: ""
    }
  }

  static func detail(
    _ event: PutioHistoryEventItem, now: Date, locale: Locale = .current
  ) -> String {
    let time = PutioBrowserItemPresentation.relativeDateText(
      for: event.createdAt, relativeTo: now, locale: locale)
    switch event.kind {
    case .fileShared(_, let user, _):
      return "\(time) · Shared by \(user)"
    case .transferCompleted(_, let size, _):
      return "\(time) · \(PutioFileRowModel.sizeText(bytes: size, locale: locale))"
    default:
      return time
    }
  }

  static func icon(_ event: PutioHistoryEventItem) -> PutioIcon {
    if case .fileShared = event.kind { return .userCircle }
    return .checkCircle
  }
}

struct TVHistoryView: View {
  let open: (PutioFileItem) -> Void

  @Environment(\.scenePhase) private var scenePhase
  @State private var model: PutioHistoryModel
  @State private var groupingDate: Date
  @State private var confirmsClear = false
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
    .onDisappear { model.cancelOpen() }
    .onReceive(NotificationCenter.default.publisher(for: .NSCalendarDayChanged)) { _ in
      groupingDate = .now
    }
    .onChange(of: scenePhase) { _, phase in
      if phase == .active { groupingDate = .now }
    }
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
      if TVHistoryPresentation.isEmpty(page), model.refreshFailure == nil,
        model.mutationFailure == nil, model.openFailure == nil
      {
        PutioEmptyStateView(
          icon: .clockCounterClockwise, title: "No history",
          message: "Completed transfers and files shared with you will appear here."
        )
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
      ForEach(TVHistoryPresentation.sections(page, now: groupingDate)) { section in
        TVSectionHeader(title: section.title)
        ForEach(section.items) { event in
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
      event: event, now: groupingDate, isOpening: model.openingEventID == event.id,
      locale: locale)
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
  let now: Date
  var isOpening = false
  var locale: Locale = .current

  var body: some View {
    HStack(spacing: PutioTheme.TV.Spacing.small) {
      Image(putioIcon: TVHistoryPresentation.icon(event))
        .resizable()
        .scaledToFit()
        .frame(width: TVRowLayout.iconSize, height: TVRowLayout.iconSize)
        .foregroundStyle(PutioTheme.Components.FileRow.icon)
        .accessibilityHidden(true)
      VStack(alignment: .leading, spacing: PutioTheme.TV.Spacing.xs) {
        Text(TVHistoryPresentation.title(event))
          .putioFont(PutioTheme.TV.Typography.body)
          .foregroundStyle(PutioTheme.TV.Colors.textPrimary)
          .lineLimit(1)
          .truncationMode(.middle)
        Text(TVHistoryPresentation.detail(event, now: now, locale: locale))
          .putioFont(PutioTheme.TV.Typography.caption)
          .foregroundStyle(PutioTheme.TV.Colors.textSecondary)
      }
      Spacer(minLength: PutioTheme.TV.Spacing.small)
      if isOpening { ProgressView().accessibilityLabel("Opening file") }
    }
    .tvRowPadding()
    .accessibilityElement(children: .combine)
  }
}

/// A failure message with its retry, and optionally a way to set it aside.
struct TVRetrySection: View {
  let message: String
  let identifier: String
  var retryTitle = "Try again"
  var dismiss: (() -> Void)?
  let retry: @MainActor () async -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: PutioTheme.TV.Spacing.small) {
      Text(message)
        .putioFont(PutioTheme.TV.Typography.body)
        .foregroundStyle(PutioTheme.TV.Colors.textSecondary)
        .accessibilityIdentifier("\(identifier).message")
      HStack(spacing: PutioTheme.TV.Spacing.small) {
        PutioButton(retryTitle, tier: .secondary) { Task { await retry() } }
          .accessibilityIdentifier(identifier)
        if let dismiss {
          PutioButton("Dismiss", tier: .secondary, action: dismiss)
            .accessibilityIdentifier("\(identifier).dismiss")
        }
      }
    }
    .padding(.horizontal, PutioTheme.TV.Spacing.medium)
    .focusSection()
  }
}
