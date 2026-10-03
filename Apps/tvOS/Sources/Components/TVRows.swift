import PutioCore
import SwiftUI

/// A scrolling column of rows. Rows that act as controls use the stock card
/// style, which owns the focus lift; the shipped app's lists are this shape.
struct TVRowList<Content: View>: View {
  @ViewBuilder let content: Content

  var body: some View {
    ScrollView {
      LazyVStack(alignment: .leading, spacing: PutioTheme.TV.Spacing.small) {
        content
      }
      .padding(.vertical, PutioTheme.TV.Spacing.small)
    }
    // The card lift grows past the column; clipping would cut it off.
    .scrollClipDisabled()
    .buttonStyle(.card)
  }
}

struct TVSectionHeader: View {
  let title: String

  var body: some View {
    Text(title)
      .putioFont(PutioTheme.TV.Typography.caption)
      .foregroundStyle(PutioTheme.TV.Colors.textSecondary)
      .padding(.top, PutioTheme.TV.Spacing.small)
      .accessibilityAddTraits(.isHeader)
  }
}

/// The chevron on a row that opens another screen.
struct TVDisclosure: View {
  var body: some View {
    Image(putioIcon: .caretRight)
      .resizable()
      .scaledToFit()
      .frame(width: TVRowLayout.disclosureSize, height: TVRowLayout.disclosureSize)
      .foregroundStyle(PutioTheme.TV.Colors.textSecondary)
      .accessibilityHidden(true)
  }
}

extension View {
  /// The inset a row's content keeps from its card edges.
  func tvRowPadding() -> some View {
    padding(.horizontal, PutioTheme.TV.Spacing.medium)
      .padding(.vertical, PutioTheme.TV.Spacing.small)
      .frame(maxWidth: .infinity, alignment: .leading)
  }
}

/// A screen's title with its header actions on the trailing edge.
struct TVScreenHeader<Actions: View>: View {
  let title: String
  @ViewBuilder let actions: Actions

  var body: some View {
    HStack(alignment: .center, spacing: PutioTheme.TV.Spacing.small) {
      Text(title)
        .putioFont(PutioTheme.TV.Typography.heading)
        .foregroundStyle(PutioTheme.TV.Colors.textPrimary)
        .accessibilityAddTraits(.isHeader)
      Spacer(minLength: PutioTheme.TV.Spacing.medium)
      actions
    }
    // Header actions sit far from the list's leading edge; the section lets
    // an upward swipe from any row reach them.
    .focusSection()
  }
}

enum TVRowLayout {
  static let iconSize = PutioTheme.TV.Typography.label.size
  static let disclosureSize = PutioTheme.TV.Typography.caption.size
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
