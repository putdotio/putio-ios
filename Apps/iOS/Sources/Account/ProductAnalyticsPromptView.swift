import PutioCore
import SwiftUI

/// The once-per-account product analytics question, as a sheet sized to its
/// content. Closing it without answering stores nothing, so the next launch
/// asks again.
struct ProductAnalyticsPromptView: View {
  @Environment(\.dismiss) private var dismiss
  let model: PutioProductAnalyticsPromptModel
  @State private var contentHeight: CGFloat = 0

  var body: some View {
    ScrollView {
      content
        .padding(.horizontal, 20)
        .padding(.top, 28)
        .padding(.bottom, PutioTheme.Spacing.space4)
        .onGeometryChange(for: CGFloat.self) {
          $0.size.height
        } action: {
          contentHeight = $0
        }
    }
    .scrollBounceBehavior(.basedOnSize)
    .background(PutioTheme.Colors.surface)
    .presentationDetents(contentHeight > 0 ? [.height(contentHeight)] : [.large])
    .presentationDragIndicator(.visible)
    .presentationBackground(PutioTheme.Colors.surface)
    .interactiveDismissDisabled(model.isSaving)
    .onChange(of: model.isAnswered) { _, answered in
      if answered { dismiss() }
    }
    .accessibilityIdentifier("analytics-prompt")
  }

  private var content: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text(PutioProductAnalyticsPrompt.title)
        .putioFont(PromptTypography.title)
        .foregroundStyle(PutioTheme.Colors.textPrimary)
        .accessibilityAddTraits(.isHeader)
      Text(PutioProductAnalyticsPrompt.intro)
        .putioFont(PromptTypography.text)
        .foregroundStyle(PutioTheme.Colors.textSecondary)
        .padding(.bottom, 8)
      ViewThatFits(in: .horizontal) {
        HStack(alignment: .top, spacing: 12) { lists }
          .frame(minWidth: 460)
        VStack(spacing: 12) { lists }
      }
      .padding(.bottom, 8)
      if let failure = model.failure {
        Text(failure)
          .putioFont(PutioTheme.Typography.caption)
          .foregroundStyle(PutioTheme.Colors.destructive)
          .accessibilityIdentifier("analytics-prompt.failure")
      }
      HStack(spacing: 8) {
        answerButton("Don't allow", choice: false, identifier: "analytics-prompt.deny")
        answerButton("Allow", choice: true, identifier: "analytics-prompt.allow")
      }
      Link(destination: PutioPrivacyControls.privacyPolicyURL) {
        Text("Privacy policy")
          .putioFont(PutioTheme.Typography.caption)
          .underline()
          .foregroundStyle(PutioTheme.Colors.textSecondary)
          .frame(maxWidth: .infinity, minHeight: 44)
      }
      .accessibilityIdentifier("analytics-prompt.privacy-policy")
    }
  }

  @ViewBuilder private var lists: some View {
    PromptList(
      title: PutioProductAnalyticsPrompt.neverSentTitle,
      items: PutioProductAnalyticsPrompt.neverSent,
      icon: .xCircle,
      iconColor: PutioTheme.Colors.destructive,
      itemColor: PutioTheme.Colors.textSecondary
    )
    PromptList(
      title: PutioProductAnalyticsPrompt.sentTitle,
      items: PutioProductAnalyticsPrompt.sent,
      icon: .checkCircle,
      iconColor: PutioTheme.Colors.success,
      itemColor: PutioTheme.Colors.textPrimary
    )
  }

  private func answerButton(_ title: String, choice: Bool, identifier: String) -> some View {
    Button {
      Task { await model.answer(choice) }
    } label: {
      ZStack {
        Text(title).opacity(model.savingChoice == choice ? 0 : 1)
        if model.savingChoice == choice { ProgressView() }
      }
      .putioFont(PromptTypography.button)
      .frame(maxWidth: .infinity, minHeight: 44)
    }
    .buttonStyle(.bordered)
    .buttonBorderShape(.roundedRectangle(radius: PutioTheme.Radius.medium))
    .tint(PutioTheme.Colors.textPrimary)
    .disabled(model.isSaving)
    .accessibilityIdentifier(identifier)
  }
}

private struct PromptList: View {
  let title: String
  let items: [String]
  let icon: PutioIcon
  let iconColor: Color
  let itemColor: Color
  @ScaledMetric(relativeTo: .subheadline) private var textSize = PromptTypography.text.size
  @ScaledMetric(relativeTo: .subheadline) private var iconSize: CGFloat = 18
  @ScaledMetric(relativeTo: .subheadline) private var iconGap: CGFloat = 10

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      Text(title)
        .putioFont(PromptTypography.label)
        .textCase(.uppercase)
        .kerning(1)
        .foregroundStyle(PutioTheme.Colors.textSecondary)
        .accessibilityAddTraits(.isHeader)
        .padding(.bottom, 2)
      ForEach(items, id: \.self) { item in
        HStack(alignment: .firstTextBaseline, spacing: iconGap) {
          Image(putioIcon: icon)
            .resizable()
            .scaledToFit()
            .frame(width: iconSize, height: iconSize)
            // Centred on the first line's capitals, so a wrapped item keeps
            // its icon beside where the text starts.
            .alignmentGuide(.firstTextBaseline) {
              $0[VerticalAlignment.center] + capHeight / 2
            }
            .foregroundStyle(iconColor)
            .accessibilityHidden(true)
          Text(item)
            .putioFont(PromptTypography.text)
            .foregroundStyle(itemColor)
        }
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(16)
    .overlay(
      RoundedRectangle(cornerRadius: PutioTheme.Radius.medium)
        .strokeBorder(PutioTheme.Colors.separator)
    )
  }

  private var capHeight: CGFloat {
    (UIFont(name: PromptTypography.text.fontName, size: textSize)
      ?? .systemFont(ofSize: textSize)).capHeight
  }
}

/// The App Store app's sizes in the token faces: Title 2, Subheadline, and a
/// Caption 1 label.
private enum PromptTypography {
  static let title = PutioFontRole(
    fontName: PutioTheme.Typography.title.fontName,
    size: 22,
    lineHeight: 1.2,
    textStyle: .title2
  )
  static let text = PutioFontRole(
    fontName: PutioTheme.Typography.body.fontName,
    size: 15,
    lineHeight: 1.35,
    textStyle: .subheadline
  )
  static let label = PutioFontRole(
    fontName: PutioTheme.Typography.subheading.fontName,
    size: 12,
    lineHeight: 1.25,
    textStyle: .caption
  )
  static let button = PutioFontRole(
    fontName: PutioTheme.Typography.subheading.fontName,
    size: 15,
    lineHeight: 1.2,
    textStyle: .subheadline
  )
}
