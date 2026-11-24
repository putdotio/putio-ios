import PutioCore
import SwiftUI

struct TVRowList<Content: View>: View {
  @ViewBuilder let content: Content

  var body: some View {
    GeometryReader { proxy in
      ScrollView {
        LazyVStack(alignment: .leading, spacing: PutioTheme.TV.Spacing.small) {
          content
        }
        .padding(.vertical, PutioTheme.TV.Spacing.small)
      }
      .padding(
        .bottom, max(0, TVRowLayout.bottomClearance - proxy.safeAreaInsets.bottom))
    }
    .buttonStyle(TVRowButtonStyle())
  }
}

struct TVRowButtonStyle: ButtonStyle {
  func makeBody(configuration: Configuration) -> some View {
    TVRowButtonBody(configuration: configuration)
  }
}

private struct TVRowButtonBody: View {
  let configuration: ButtonStyleConfiguration
  @Environment(\.isFocused) private var isFocused
  @Environment(\.putioTVRowState) private var inherited

  private var state: PutioTVRowState {
    isFocused ? .focused : inherited
  }

  var body: some View {
    configuration.label
      .environment(\.putioTVRowState, state)
      .background {
        RoundedRectangle(cornerRadius: PutioTVRowFocus.cornerRadius, style: .continuous)
          .fill(fill)
          .shadow(
            color: .black.opacity(state == .focused ? TVRowLayout.shadowOpacity : 0),
            radius: TVRowLayout.shadowRadius, y: TVRowLayout.shadowOffset)
      }
      .opacity(configuration.isPressed ? TVRowLayout.pressedOpacity : 1)
      .animation(.easeOut(duration: TVRowLayout.focusDuration), value: state)
  }

  private var fill: Color {
    switch state {
    case .focused: PutioTVRowFocus.fill
    case .open: PutioTVRowFocus.openFill
    case .resting: .clear
    }
  }
}

extension View {
  func tvRowOpen(_ isOpen: Bool) -> some View {
    environment(\.putioTVRowState, isOpen ? .open : .resting)
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
      .foregroundStyle(.putioRowSecondary)
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
  static let bottomClearance: CGFloat = 60
  static let shadowOpacity = 0.45
  static let shadowRadius: CGFloat = 15
  static let shadowOffset: CGFloat = 12
  static let pressedOpacity = 0.85
  static let focusDuration = 0.15
}

/// A failure message with its retry, and optionally a way to set it aside.
struct TVRetrySection: View {
  let message: String
  let identifier: String
  var retryTitle = String(localized: "Try again", bundle: .putioCore)
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
          PutioButton(
            String(localized: "Dismiss", bundle: .putioCore), tier: .secondary, action: dismiss
          )
          .accessibilityIdentifier("\(identifier).dismiss")
        }
      }
    }
    .padding(.horizontal, PutioTheme.TV.Spacing.medium)
    .focusSection()
  }
}
