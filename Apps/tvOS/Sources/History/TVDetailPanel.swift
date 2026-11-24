import PutioCore
import SwiftUI

struct TVDetailPanel<Subtitle: View, Facts: View, Actions: View>: View {
  let icon: PutioIcon
  let title: String
  let identifier: String
  @ViewBuilder let subtitle: Subtitle
  @ViewBuilder let facts: Facts
  @ViewBuilder let actions: Actions

  var body: some View {
    VStack(alignment: .leading, spacing: PutioTheme.TV.Spacing.medium) {
      HStack(spacing: PutioTheme.TV.Spacing.medium) {
        Image(putioIcon: icon)
          .resizable()
          .scaledToFit()
          .frame(width: TVDetailPanelLayout.tileIconSize, height: TVDetailPanelLayout.tileIconSize)
          .foregroundStyle(PutioTheme.Colors.accent)
          .frame(width: TVDetailPanelLayout.tileWidth, height: TVDetailPanelLayout.tileHeight)
          .background(
            PutioTheme.Colors.surfaceActive,
            in: RoundedRectangle(cornerRadius: PutioTheme.TV.radius, style: .continuous)
          )
          .accessibilityHidden(true)
        VStack(alignment: .leading, spacing: PutioTheme.TV.Spacing.xxs) {
          Text(title)
            .putioFont(PutioTheme.TV.Typography.label)
            .foregroundStyle(PutioTheme.TV.Colors.textPrimary)
            .lineLimit(1)
          subtitle
            .putioFont(PutioTheme.TV.Typography.caption)
            .foregroundStyle(PutioTheme.TV.Colors.textSecondary)
            .lineLimit(1)
        }
      }
      Grid(
        alignment: .leading, horizontalSpacing: PutioTheme.TV.Spacing.medium,
        verticalSpacing: PutioTheme.TV.Spacing.xs
      ) {
        facts
      }
      .putioFont(PutioTheme.TV.Typography.caption)
      VStack(alignment: .leading, spacing: PutioTheme.TV.Spacing.xs) {
        actions
      }
      .padding(.horizontal, -PutioTheme.TV.Spacing.medium)
      .buttonStyle(TVRowButtonStyle())
    }
    .padding(PutioTheme.TV.Spacing.medium)
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    .background(
      PutioTheme.Colors.surface,
      in: RoundedRectangle(cornerRadius: TVDetailPanelLayout.radius, style: .continuous)
    )
    .padding(.bottom, TVRowLayout.bottomClearance)
    .frame(width: TVDetailPanelLayout.width)
    .frame(maxHeight: .infinity, alignment: .top)
    .focusSection()
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier(identifier)
  }
}

struct TVDetailFact: View {
  let label: String
  let value: String

  var body: some View {
    GridRow {
      Text(label)
        .foregroundStyle(PutioTheme.TV.Colors.textSecondary)
      Text(value)
        .foregroundStyle(PutioTheme.TV.Colors.textPrimary)
    }
  }
}

struct TVDetailAction: View {
  let title: String
  let icon: PutioIcon
  var isDestructive = false
  let perform: () -> Void

  var body: some View {
    Button(action: perform) {
      HStack(spacing: PutioTheme.TV.Spacing.small) {
        Image(putioIcon: icon)
          .resizable()
          .scaledToFit()
          .frame(width: TVRowLayout.iconSize, height: TVRowLayout.iconSize)
          .foregroundStyle(
            isDestructive
              ? AnyShapeStyle(PutioTheme.Colors.destructiveText) : AnyShapeStyle(.putioRowPrimary)
          )
          .accessibilityHidden(true)
        Text(title)
          .putioFont(PutioTheme.TV.Typography.body)
          .foregroundStyle(
            isDestructive
              ? AnyShapeStyle(PutioTheme.Colors.destructiveText) : AnyShapeStyle(.putioRowPrimary)
          )
      }
      .tvRowPadding()
    }
  }
}

struct TVLoadMoreFailedRow<FocusValue: Hashable>: View {
  let message: String
  let identifier: String
  let focus: FocusState<FocusValue?>.Binding
  let focusValue: FocusValue
  let retry: @MainActor () async -> Void

  var body: some View {
    HStack(spacing: PutioTheme.TV.Spacing.small) {
      Image(putioIcon: .warningCircle)
        .resizable()
        .scaledToFit()
        .frame(width: TVRowLayout.iconSize, height: TVRowLayout.iconSize)
        .foregroundStyle(PutioTheme.TV.Colors.textSecondary)
        .accessibilityHidden(true)
      Text(message)
        .putioFont(PutioTheme.TV.Typography.body)
        .foregroundStyle(PutioTheme.TV.Colors.textPrimary)
      Spacer(minLength: PutioTheme.TV.Spacing.medium)
      PutioButton(String(localized: "Try again", bundle: .putioCore), tier: .secondary) {
        Task { await retry() }
      }
      .focused(focus, equals: focusValue)
      .accessibilityIdentifier(identifier)
    }
    .padding(.horizontal, PutioTheme.TV.Spacing.medium)
    .focusSection()
  }
}

enum TVDetailPanelLayout {
  static let width: CGFloat = 640
  static let radius: CGFloat = 40
  static let tileWidth: CGFloat = 160
  static let tileHeight: CGFloat = 90
  static let tileIconSize: CGFloat = 40
}
