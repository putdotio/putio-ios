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

public struct PutioToastView: View {
  private let toast: PutioToast

  public init(_ toast: PutioToast) {
    self.toast = toast
  }

  public var body: some View {
    let palette = toast.variant.palette
    HStack(alignment: .firstTextBaseline, spacing: PutioToastLayout.contentGap) {
      PutioIconView(toast.variant.icon, size: PutioToastLayout.iconSize)
        .foregroundStyle(palette.icon)
      VStack(alignment: .leading, spacing: PutioTheme.Spacing.space1) {
        Text(toast.title)
          .putioFont(PutioToastLayout.titleFont)
          .foregroundStyle(palette.foreground)
        if let message = toast.message {
          Text(message)
            .putioFont(PutioToastLayout.messageFont)
            .foregroundStyle(palette.foreground)
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)
    }
    .padding(PutioToastLayout.contentPadding)
    .background(palette.background, in: PutioToastLayout.shape)
    .overlay(
      PutioToastLayout.shape.strokeBorder(palette.border, lineWidth: PutioTheme.Border.width)
    )
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

struct PutioToastPalette {
  let background: Color
  let border: Color
  let foreground: Color
  let icon: Color
}

extension PutioToast.Variant {
  var palette: PutioToastPalette {
    switch self {
    case .neutral:
      PutioToastPalette(
        background: PutioTheme.Components.Notification.background,
        border: PutioTheme.Components.Notification.border,
        foreground: PutioTheme.Components.Notification.foreground,
        icon: PutioTheme.Components.Notification.icon
      )
    case .success:
      PutioToastPalette(
        background: PutioTheme.Components.Notification.successBackground,
        border: PutioTheme.Components.Notification.successBorder,
        foreground: PutioTheme.Components.Notification.successForeground,
        icon: PutioTheme.Components.Notification.successForeground
      )
    case .danger:
      PutioToastPalette(
        background: PutioTheme.Components.Notification.dangerBackground,
        border: PutioTheme.Components.Notification.dangerBorder,
        foreground: PutioTheme.Components.Notification.dangerForeground,
        icon: PutioTheme.Components.Notification.dangerForeground
      )
    case .info:
      PutioToastPalette(
        background: PutioTheme.Components.Notification.infoBackground,
        border: PutioTheme.Components.Notification.border,
        foreground: PutioTheme.Components.Notification.foreground,
        icon: PutioTheme.Components.Notification.icon
      )
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
    static let contentGap = PutioTheme.TV.Spacing.small
    static let contentPadding = PutioTheme.TV.Spacing.medium
    static let presentationPadding = PutioTheme.TV.Spacing.large
    static let iconSize = PutioMetricRole(value: PutioTheme.TV.Spacing.medium, relativeTo: .body)
    static let zIndex = PutioTheme.TV.ZIndex.toast
    static let shape = RoundedRectangle(cornerRadius: PutioTheme.TV.radius)
  #else
    static let titleFont = PutioTheme.Typography.subheading
    static let messageFont = PutioTheme.Typography.caption
    static let contentGap = PutioTheme.Spacing.space2
    static let contentPadding = PutioTheme.Spacing.space3
    static let presentationPadding = PutioTheme.Spacing.space3
    static let iconSize = PutioMetricRole(
      value: PutioTheme.Typography.sizeMd,
      relativeTo: .body
    )
    static let zIndex = 1.0
    static let shape = RoundedRectangle(cornerRadius: PutioTheme.Radius.medium)
  #endif
}
