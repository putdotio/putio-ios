import SwiftUI

public struct PutioToast: Equatable, Sendable {
  public enum Variant: CaseIterable, Sendable {
    case neutral
    case success
    case danger
    case info
  }

  public let variant: Variant
  public let title: String
  public let message: String?

  public init(variant: Variant = .neutral, title: String, message: String? = nil) {
    self.variant = variant
    self.title = title
    self.message = message
  }
}

// The variant only tints the icon; the surface comes from PutioToastSurface.
public struct PutioToastView: View {
  private let toast: PutioToast

  @PutioScaledMetric private var iconSize: CGFloat

  public init(_ toast: PutioToast) {
    self.toast = toast
    _iconSize = PutioScaledMetric(PutioToastLayout.iconSize)
  }

  public var body: some View {
    HStack(alignment: .firstTextBaseline, spacing: PutioToastLayout.contentGap) {
      Image(putioIcon: toast.variant.icon)
        .resizable()
        .scaledToFit()
        .frame(width: iconSize, height: iconSize)
        .foregroundStyle(toast.variant.iconColor)
      VStack(alignment: .leading, spacing: PutioTheme.Spacing.space1) {
        Text(toast.title)
          .putioFont(PutioToastLayout.titleFont)
          .foregroundStyle(PutioToastLayout.titleColor)
        if let message = toast.message {
          Text(message)
            .putioFont(PutioToastLayout.messageFont)
            .foregroundStyle(PutioToastLayout.messageColor)
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)
    }
    .padding(PutioToastLayout.contentPadding)
    .modifier(PutioToastSurface())
  }
}

// The toast floats above content, so on iOS it rides Liquid Glass. tvOS is a
// solid token surface (the TV contract forbids materials); the watchOS and
// macOS-test fallback is the plain system material.
private struct PutioToastSurface: ViewModifier {
  @ViewBuilder func body(content: Content) -> some View {
    #if os(tvOS)
      content.background(
        RoundedRectangle(cornerRadius: PutioTheme.TV.radius)
          .fill(PutioTheme.Components.Notification.background)
          .stroke(PutioTheme.Components.Notification.border, lineWidth: PutioTheme.Border.width)
      )
    #elseif os(iOS)
      if HarnessRendering.usesRasterFallback {
        content.background(
          .regularMaterial,
          in: RoundedRectangle(cornerRadius: PutioTheme.Radius.large)
        )
      } else {
        content.glassEffect(
          .regular,
          in: RoundedRectangle(cornerRadius: PutioTheme.Radius.large)
        )
      }
    #else
      content.background(
        .regularMaterial,
        in: RoundedRectangle(cornerRadius: PutioTheme.Radius.large)
      )
    #endif
  }
}

extension View {
  public func putioToast(_ toast: Binding<PutioToast?>) -> some View {
    modifier(PutioToastPresenter(toast: toast))
  }
}

private struct PutioToastPresenter: ViewModifier {
  @Binding var toast: PutioToast?

  func body(content: Content) -> some View {
    content.overlay(alignment: .bottom) {
      if let toast {
        PutioToastView(toast)
          .padding(PutioToastLayout.presentationPadding)
          .transition(.move(edge: .bottom).combined(with: .opacity))
          .zIndex(PutioToastLayout.zIndex)
      }
    }
    .animation(
      PutioTheme.Motion.easingOut.animation(duration: PutioTheme.Motion.durationBase),
      value: toast
    )
  }
}

extension PutioToast.Variant {
  var iconColor: Color {
    switch self {
    case .neutral: PutioTheme.Colors.textSecondary
    case .success: PutioTheme.Colors.success
    case .danger: PutioTheme.Colors.destructive
    case .info: PutioTheme.Colors.accent
    }
  }

  var icon: PutioIcon {
    switch self {
    case .neutral: .info
    case .success: .checkCircle
    case .danger: .xCircle
    case .info: .info
    }
  }
}

enum PutioToastLayout {
  #if os(tvOS)
    static let titleFont = PutioTheme.TV.Typography.label
    static let messageFont = PutioTheme.TV.Typography.body
    static let titleColor = PutioTheme.Components.Notification.foreground
    static let messageColor = PutioTheme.Components.Notification.foreground
    static let contentGap = PutioTheme.TV.Spacing.small
    static let contentPadding = PutioTheme.TV.Spacing.medium
    static let presentationPadding = PutioTheme.TV.Spacing.large
    static let iconSize = PutioMetricRole(
      value: PutioTheme.TV.Typography.caption.size,
      relativeTo: .body
    )
    static let zIndex = PutioTheme.TV.ZIndex.toast
  #else
    static let titleFont = PutioTheme.Typography.subheading
    static let messageFont = PutioTheme.Typography.caption
    static let titleColor = PutioTheme.Colors.textPrimary
    static let messageColor = PutioTheme.Colors.textSecondary
    static let contentGap = PutioTheme.Spacing.space2
    static let contentPadding = PutioTheme.Spacing.space3
    static let presentationPadding = PutioTheme.Spacing.space3
    static let iconSize = PutioMetricRole(
      value: PutioTheme.Typography.sizeMd,
      relativeTo: .body
    )
    static let zIndex = 1.0
  #endif
}
