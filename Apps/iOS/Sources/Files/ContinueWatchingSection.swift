import PutioCore
import SwiftUI

struct PutioContinueWatchingContext {
  let model: PutioContinueWatchingModel
  let play: @MainActor (PutioVideoRoute) -> Void
  let reconcile: @MainActor () async -> Void
}

extension EnvironmentValues {
  @Entry var putioContinueWatching: PutioContinueWatchingContext? = nil
  @Entry var putioAccountStorage: PutioAccountSnapshot.Storage? = nil
}

struct PutioContinueWatchingSection: View {
  let context: PutioContinueWatchingContext
  let isDisabled: Bool

  var body: some View {
    let entries = context.model.entries
    if !entries.isEmpty {
      VStack(alignment: .leading, spacing: PutioTheme.Spacing.space2) {
        Text("Continue watching")
          .putioFont(PutioTheme.Typography.caption)
          .foregroundStyle(PutioTheme.Colors.textSecondary)
          .accessibilityAddTraits(.isHeader)
          .padding(.horizontal, PutioTheme.Spacing.space3)
        ScrollView(.horizontal) {
          HStack(spacing: ContinueWatchingLayout.cardGap) {
            ForEach(entries) { entry in
              PutioContinueWatchingCard(
                entry: entry, isDisabled: isDisabled, play: context.play,
                remove: { context.model.remove(entry.fileID) })
            }
          }
          .scrollTargetLayout()
        }
        .contentMargins(.horizontal, PutioTheme.Spacing.space3, for: .scrollContent)
        .scrollIndicators(.hidden)
        .accessibilityIdentifier("files.continue-watching")
      }
      .padding(.top, PutioTheme.Spacing.space3)
      .listRowInsets(EdgeInsets())
      .listRowSeparator(.hidden)
      .listRowBackground(PutioTheme.Colors.background)
      .selectionDisabled()
    }
  }
}

private struct PutioContinueWatchingCard: View {
  let entry: PutioContinueWatchingEntry
  let isDisabled: Bool
  let play: @MainActor (PutioVideoRoute) -> Void
  let remove: @MainActor () -> Void

  @PutioScaledMetric private var cardWidth: CGFloat
  @PutioScaledMetric private var iconSize: CGFloat

  init(
    entry: PutioContinueWatchingEntry, isDisabled: Bool,
    play: @escaping @MainActor (PutioVideoRoute) -> Void,
    remove: @escaping @MainActor () -> Void
  ) {
    self.entry = entry
    self.isDisabled = isDisabled
    self.play = play
    self.remove = remove
    _cardWidth = PutioScaledMetric(ContinueWatchingLayout.cardWidth)
    _iconSize = PutioScaledMetric(ContinueWatchingLayout.iconSize)
  }

  var body: some View {
    Button {
      play(entry.videoRoute)
    } label: {
      VStack(alignment: .leading, spacing: PutioTheme.Spacing.space2) {
        HStack(spacing: PutioTheme.Spacing.space2) {
          Image(putioIcon: .fileVideoFill)
            .resizable()
            .scaledToFit()
            .frame(width: iconSize, height: iconSize)
            .foregroundStyle(PutioTheme.Components.FileRow.icon)
          Text(entry.name)
            .putioFont(PutioTheme.Typography.body)
            .foregroundStyle(PutioTheme.Colors.textPrimary)
            .lineLimit(1)
            .truncationMode(.middle)
        }
        ProgressView(value: entry.fraction)
          .tint(PutioTheme.Colors.accent)
        Text("\(entry.remainingClock) left")
          .putioFont(PutioTheme.Typography.numeric)
          .foregroundStyle(PutioTheme.Colors.textSecondary)
          .lineLimit(1)
      }
      .padding(ContinueWatchingLayout.padding)
      .frame(width: cardWidth, alignment: .leading)
      .background(
        PutioTheme.Colors.surface,
        in: RoundedRectangle(cornerRadius: ContinueWatchingLayout.cornerRadius, style: .continuous)
      )
      .contentShape(
        .contextMenuPreview,
        RoundedRectangle(cornerRadius: ContinueWatchingLayout.cornerRadius, style: .continuous))
    }
    .buttonStyle(.plain)
    .disabled(isDisabled)
    .contextMenu {
      PutioItemMenuContent(
        PutioItemMenu([
          [
            PutioItemAction(
              id: "remove-continue-watching",
              title: String(localized: "Remove from Continue watching"), icon: .x,
              perform: remove)
          ]
        ]))
    }
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(Text("Resume \(entry.name), \(entry.remainingSpoken) left"))
    .accessibilityAddTraits(.isButton)
    .accessibilityAction {
      if !isDisabled { play(entry.videoRoute) }
    }
    .accessibilityAction(named: Text("Remove from Continue watching")) {
      if !isDisabled { remove() }
    }
    .accessibilityIdentifier("files.continue-watching.item.\(entry.fileID.rawValue)")
  }
}

private enum ContinueWatchingLayout {
  static let cardWidth = PutioMetricRole(value: 176, relativeTo: .body)
  static let iconSize = PutioMetricRole(value: PutioTheme.Typography.sizeMd, relativeTo: .body)
  static let cornerRadius: CGFloat = 14
  static let padding: CGFloat = 14
  static let cardGap: CGFloat = 12
}

struct PutioAllFilesHeader: View {
  let storage: PutioAccountSnapshot.Storage?
  @Environment(\.locale) private var locale

  var body: some View {
    HStack(alignment: .firstTextBaseline) {
      Text("All files")
        .putioFont(PutioTheme.Typography.caption)
      Spacer(minLength: PutioTheme.Spacing.space2)
      if let storage {
        Text(storage.capacitySummary(locale: locale))
          .putioFont(PutioTheme.Typography.numeric)
      }
    }
    .foregroundStyle(PutioTheme.Colors.textSecondary)
    .accessibilityElement(children: .combine)
    .accessibilityAddTraits(.isHeader)
    .accessibilityIdentifier("files.all-files")
    .listRowInsets(
      EdgeInsets(
        top: PutioTheme.Spacing.space3, leading: PutioTheme.Spacing.space3,
        bottom: 0, trailing: PutioTheme.Spacing.space3)
    )
    .listRowSeparator(.hidden)
    .listRowBackground(PutioTheme.Colors.background)
    .selectionDisabled()
  }
}
