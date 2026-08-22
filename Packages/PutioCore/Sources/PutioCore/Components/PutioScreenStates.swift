import SwiftUI

// Screen states are the stock system components with token tints: the HIG
// already defines loading, empty, and error presentation, so the kit does not
// paint its own.
public struct PutioLoadingStateView: View {
  private let title: String?

  public init(title: String? = nil) {
    self.title = title
  }

  public var body: some View {
    VStack(spacing: PutioScreenStateLayout.contentGap) {
      ProgressView()
        .controlSize(.large)
        .tint(PutioTheme.Colors.accent)
      if let title {
        Text(title)
          .putioFont(PutioScreenStateLayout.messageFont)
          .foregroundStyle(PutioTheme.Colors.textSecondary)
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }
}

public struct PutioEmptyStateView: View {
  private let icon: PutioIcon
  private let title: String
  private let message: String?
  private let actionTitle: String?
  private let action: (() -> Void)?

  @PutioScaledMetric private var iconSize: CGFloat

  public init(
    icon: PutioIcon = .folderFill,
    title: String,
    message: String? = nil,
    actionTitle: String? = nil,
    action: (() -> Void)? = nil
  ) {
    self.icon = icon
    self.title = title
    self.message = message
    self.actionTitle = actionTitle
    self.action = action
    _iconSize = PutioScaledMetric(PutioScreenStateLayout.iconSize)
  }

  public var body: some View {
    ContentUnavailableView {
      Label {
        Text(title)
      } icon: {
        Image(putioIcon: icon)
          .resizable()
          .scaledToFit()
          .frame(width: iconSize, height: iconSize)
          .foregroundStyle(PutioTheme.Colors.textSecondary)
      }
    } description: {
      if let message {
        Text(message)
      }
    } actions: {
      if let actionTitle, let action {
        PutioButton(actionTitle, tier: .secondary, size: .medium, action: action)
      }
    }
  }
}

public struct PutioErrorStateView: View {
  private let title: String
  private let message: String?
  private let retryTitle: String?
  private let retry: (() -> Void)?

  @PutioScaledMetric private var iconSize: CGFloat

  public init(
    title: String,
    message: String? = nil,
    retryTitle: String? = nil,
    retry: (() -> Void)? = nil
  ) {
    self.title = title
    self.message = message
    self.retryTitle = retryTitle
    self.retry = retry
    _iconSize = PutioScaledMetric(PutioScreenStateLayout.iconSize)
  }

  public var body: some View {
    ContentUnavailableView {
      Label {
        Text(title)
      } icon: {
        Image(putioIcon: .warningCircle)
          .resizable()
          .scaledToFit()
          .frame(width: iconSize, height: iconSize)
          .foregroundStyle(PutioTheme.Colors.destructive)
      }
    } description: {
      if let message {
        Text(message)
      }
    } actions: {
      if let retryTitle, let retry {
        PutioButton(retryTitle, icon: .arrowCounterClockwise, tier: .secondary, size: .medium) {
          retry()
        }
      }
    }
  }
}

enum PutioScreenStateLayout {
  #if os(tvOS)
    static let messageFont = PutioTheme.TV.Typography.body
    static let contentGap = PutioTheme.TV.Spacing.medium
    static let iconSize = PutioMetricRole(
      value: PutioTheme.TV.Typography.heading.size,
      relativeTo: .title
    )
  #else
    static let messageFont = PutioTheme.Typography.body
    static let contentGap = PutioTheme.Spacing.space3
    static let iconSize = PutioMetricRole(value: PutioTheme.Typography.size2xl, relativeTo: .title)
  #endif
}
