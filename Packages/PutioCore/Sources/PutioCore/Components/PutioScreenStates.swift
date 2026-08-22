import SwiftUI

public struct PutioSpinner: View {
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @PutioScaledMetric private var diameter: CGFloat
  @State private var isSpinning = false

  public init(diameter: PutioMetricRole = PutioScreenStateLayout.spinnerDiameter) {
    _diameter = PutioScaledMetric(diameter)
  }

  public var body: some View {
    Circle()
      .trim(from: 0, to: 0.75)
      .stroke(style: StrokeStyle(lineWidth: PutioTheme.Border.width * 2, lineCap: .round))
      .frame(width: diameter, height: diameter)
      .rotationEffect(.degrees(isSpinning ? 360 : 0))
      .onAppear {
        guard !reduceMotion else { return }
        withAnimation(
          .linear(duration: PutioTheme.Motion.durationSlow * 2).repeatForever(autoreverses: false)
        ) {
          isSpinning = true
        }
      }
      .accessibilityLabel(Text("Loading"))
  }
}

public struct PutioLoadingStateView: View {
  private let title: String?

  public init(title: String? = nil) {
    self.title = title
  }

  public var body: some View {
    VStack(spacing: PutioScreenStateLayout.contentGap) {
      PutioSpinner()
        .foregroundStyle(PutioTheme.Colors.accent)
      if let title {
        Text(title)
          .putioFont(PutioScreenStateLayout.messageFont)
          .foregroundStyle(PutioTheme.Colors.textSecondary)
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(PutioTheme.Colors.background)
  }
}

public struct PutioEmptyStateView: View {
  private let icon: PutioIcon
  private let title: String
  private let message: String?
  private let actionTitle: String?
  private let action: (() -> Void)?

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
  }

  public var body: some View {
    PutioScreenStateContent(
      icon: icon,
      iconColor: PutioTheme.Colors.textSecondary,
      title: title,
      message: message,
      actionIcon: nil,
      actionTitle: actionTitle,
      action: action
    )
  }
}

public struct PutioErrorStateView: View {
  private let title: String
  private let message: String?
  private let retryTitle: String?
  private let retry: (() -> Void)?

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
  }

  public var body: some View {
    PutioScreenStateContent(
      icon: .warningCircle,
      iconColor: PutioTheme.Colors.destructive,
      title: title,
      message: message,
      actionIcon: .arrowCounterClockwise,
      actionTitle: retryTitle,
      action: retry
    )
  }
}

private struct PutioScreenStateContent: View {
  let icon: PutioIcon
  let iconColor: Color
  let title: String
  let message: String?
  let actionIcon: PutioIcon?
  let actionTitle: String?
  let action: (() -> Void)?

  var body: some View {
    VStack(spacing: PutioScreenStateLayout.contentGap) {
      PutioIconView(icon, size: PutioScreenStateLayout.iconSize)
        .foregroundStyle(iconColor)
      Text(title)
        .putioFont(PutioScreenStateLayout.titleFont)
        .foregroundStyle(PutioTheme.Colors.textPrimary)
        .multilineTextAlignment(.center)
      if let message {
        Text(message)
          .putioFont(PutioScreenStateLayout.messageFont)
          .foregroundStyle(PutioTheme.Colors.textSecondary)
          .multilineTextAlignment(.center)
      }
      if let actionTitle, let action {
        PutioButton(actionTitle, icon: actionIcon, tier: .secondary, action: action)
      }
    }
    .padding(PutioScreenStateLayout.contentPadding)
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(PutioTheme.Colors.background)
  }
}

public enum PutioScreenStateLayout {
  #if os(tvOS)
    static let titleFont = PutioTheme.TV.Typography.heading
    static let messageFont = PutioTheme.TV.Typography.body
    static let contentGap = PutioTheme.TV.Spacing.medium
    static let contentPadding = PutioTheme.TV.Spacing.large
    static let iconSize = PutioMetricRole(value: PutioTheme.TV.Spacing.large, relativeTo: .title)
    public static let spinnerDiameter = PutioMetricRole(
      value: PutioTheme.TV.Spacing.medium,
      relativeTo: .body
    )
  #else
    static let titleFont = PutioTheme.Typography.heading
    static let messageFont = PutioTheme.Typography.body
    static let contentGap = PutioTheme.Spacing.space3
    static let contentPadding = PutioTheme.Spacing.space4
    static let iconSize = PutioMetricRole(value: PutioTheme.Typography.size2xl, relativeTo: .title)
    public static let spinnerDiameter = PutioMetricRole(
      value: PutioTheme.Typography.sizeLg,
      relativeTo: .body
    )
  #endif
}
