import SwiftUI

public enum PutioButtonTier: CaseIterable, Sendable {
  case primary
  case secondary
  case ghost
  case success
  case danger
  case info
}

public enum PutioButtonSize: CaseIterable, Sendable {
  case regular
  case medium
  case small
  case extraSmall
}

public struct PutioButton: View {
  private let title: String
  private let icon: PutioIcon?
  private let tier: PutioButtonTier
  private let size: PutioButtonSize
  private let action: () -> Void

  @PutioScaledMetric private var contentGap: CGFloat
  @PutioScaledMetric private var iconSize: CGFloat

  public init(
    _ title: String,
    icon: PutioIcon? = nil,
    tier: PutioButtonTier = .secondary,
    size: PutioButtonSize = .regular,
    action: @escaping () -> Void
  ) {
    self.title = title
    self.icon = icon
    self.tier = tier
    self.size = size
    self.action = action
    _contentGap = PutioScaledMetric(PutioTheme.ScaledMetrics.buttonContentGap)
    _iconSize = PutioScaledMetric(PutioTheme.ScaledMetrics.buttonIconSize)
  }

  public var body: some View {
    Button(action: action) {
      HStack(spacing: contentGap) {
        if let icon {
          Image(putioIcon: icon)
            .resizable()
            .scaledToFit()
            .frame(width: iconSize, height: iconSize)
        }
        Text(title)
          .tracking(size.metrics.tracking)
          .textCase(.uppercase)
      }
    }
    .buttonStyle(PutioButtonStyle(tier: tier, size: size))
  }
}

struct PutioButtonStyle: ButtonStyle {
  let tier: PutioButtonTier
  let size: PutioButtonSize

  @Environment(\.isEnabled) private var isEnabled
  #if os(tvOS)
    @Environment(\.isFocused) private var isFocused
  #endif
  @PutioScaledMetric private var height: CGFloat
  @PutioScaledMetric private var paddingX: CGFloat

  init(tier: PutioButtonTier, size: PutioButtonSize) {
    self.tier = tier
    self.size = size
    _height = PutioScaledMetric(size.metrics.height)
    _paddingX = PutioScaledMetric(size.metrics.paddingX)
  }

  func makeBody(configuration: Configuration) -> some View {
    let state = resolvedState(isPressed: configuration.isPressed)
    return configuration.label
      .putioFont(size.metrics.label)
      .lineLimit(1)
      .foregroundStyle(state.foreground)
      .padding(.horizontal, paddingX)
      .frame(minHeight: height)
      .background(state.background, in: shape)
      .overlay(shape.strokeBorder(state.border, lineWidth: PutioTheme.Border.width))
      .opacity(state.dimsWhenDisabled && !isEnabled ? PutioButtonStyle.disabledOpacity : 1)
      .animation(
        PutioTheme.Motion.easingOut.animation(duration: PutioTheme.Motion.durationFast),
        value: configuration.isPressed
      )
  }

  // The web contract fades disabled filled buttons (`button:disabled`); the
  // ratio is not in the token graph.
  static let disabledOpacity = 0.3

  private var shape: RoundedRectangle {
    #if os(tvOS)
      RoundedRectangle(cornerRadius: PutioTheme.TV.radius)
    #else
      RoundedRectangle(cornerRadius: PutioTheme.Radius.standard)
    #endif
  }

  private struct ResolvedState {
    let background: Color
    let foreground: Color
    let border: Color
    let dimsWhenDisabled: Bool
  }

  private func resolvedState(isPressed: Bool) -> ResolvedState {
    let palette = tier.palette
    if !isEnabled && !palette.dimsWhenDisabled {
      return ResolvedState(
        background: PutioTheme.Components.Button.ghostBackground,
        foreground: PutioTheme.Colors.textDisabled,
        border: .clear,
        dimsWhenDisabled: false
      )
    }
    #if os(tvOS)
      if isFocused {
        return ResolvedState(
          background: palette.focusBackground,
          foreground: palette.pressedForeground ?? palette.foreground,
          border: palette.focusBorder,
          dimsWhenDisabled: palette.dimsWhenDisabled
        )
      }
    #endif
    if isPressed {
      return ResolvedState(
        background: palette.pressedBackground,
        foreground: palette.pressedForeground ?? palette.foreground,
        border: palette.pressedBorder ?? palette.pressedBackground,
        dimsWhenDisabled: palette.dimsWhenDisabled
      )
    }
    return ResolvedState(
      background: palette.background,
      foreground: palette.foreground,
      border: palette.border ?? palette.background,
      dimsWhenDisabled: palette.dimsWhenDisabled
    )
  }
}

struct PutioButtonPalette {
  let background: Color
  let foreground: Color
  let pressedBackground: Color
  var pressedForeground: Color?
  var border: Color?
  var pressedBorder: Color?
  var dimsWhenDisabled = true

  // The TV focus contract restores a visible box: a solid fill plus a border
  // step, never a scale, lift, or halo.
  var focusBackground = PutioTheme.Colors.surfaceActive
  var focusBorder = PutioTheme.Colors.borderActive
}

extension PutioButtonTier {
  var palette: PutioButtonPalette {
    switch self {
    case .primary:
      PutioButtonPalette(
        background: PutioTheme.Components.Button.primaryBackground,
        foreground: PutioTheme.Components.Button.primaryForeground,
        pressedBackground: PutioTheme.Components.Button.primaryBackgroundPressed,
        focusBackground: PutioTheme.Components.Button.primaryBackgroundPressed,
        focusBorder: PutioTheme.Components.Button.primaryBackgroundPressed
      )
    case .secondary:
      PutioButtonPalette(
        background: PutioTheme.Components.Button.secondaryBackground,
        foreground: PutioTheme.Components.Button.secondaryForeground,
        pressedBackground: PutioTheme.Components.Button.secondaryBackgroundPressed,
        border: PutioTheme.Colors.separator,
        pressedBorder: PutioTheme.Colors.borderActive,
        focusBackground: PutioTheme.Components.Button.secondaryBackgroundPressed
      )
    case .ghost:
      PutioButtonPalette(
        background: PutioTheme.Components.Button.ghostBackground,
        foreground: PutioTheme.Components.Button.ghostForeground,
        pressedBackground: PutioTheme.Components.Button.ghostBackgroundPressed,
        pressedForeground: PutioTheme.Components.Button.ghostForegroundPressed,
        border: .clear,
        pressedBorder: .clear,
        dimsWhenDisabled: false
      )
    case .success:
      PutioButtonPalette(
        background: PutioTheme.Components.Button.successBackground,
        foreground: PutioTheme.Components.Button.successForeground,
        pressedBackground: PutioTheme.Components.Button.successBackgroundPressed,
        focusBackground: PutioTheme.Components.Button.successBackgroundPressed,
        focusBorder: PutioTheme.Components.Button.successBackgroundPressed
      )
    case .danger:
      PutioButtonPalette(
        background: PutioTheme.Components.Button.dangerBackground,
        foreground: PutioTheme.Components.Button.dangerForeground,
        pressedBackground: PutioTheme.Components.Button.dangerBackgroundPressed,
        focusBackground: PutioTheme.Components.Button.dangerBackgroundPressed,
        focusBorder: PutioTheme.Components.Button.dangerBackgroundPressed
      )
    case .info:
      PutioButtonPalette(
        background: PutioTheme.Components.Button.infoBackground,
        foreground: PutioTheme.Components.Button.infoForeground,
        pressedBackground: PutioTheme.Components.Button.infoBackgroundPressed,
        focusBackground: PutioTheme.Components.Button.infoBackgroundPressed,
        focusBorder: PutioTheme.Components.Button.infoBackgroundPressed
      )
    }
  }
}

struct PutioButtonMetrics {
  let height: PutioMetricRole
  let paddingX: PutioMetricRole
  let label: PutioFontRole
  let tracking: CGFloat
}

extension PutioButtonSize {
  #if os(tvOS)
    // The 10-foot contract keeps one box on the TV scale for every size:
    // tiers and sizes never change TV geometry.
    var metrics: PutioButtonMetrics {
      PutioButtonMetrics(
        height: PutioMetricRole(value: PutioTheme.TV.Spacing.large, relativeTo: .caption),
        paddingX: PutioMetricRole(value: PutioTheme.TV.Spacing.medium, relativeTo: .caption),
        label: PutioFontRole(
          fontName: PutioTheme.TV.Typography.label.fontName,
          size: PutioTheme.TV.Typography.caption.size,
          lineHeight: PutioTheme.TV.Typography.label.lineHeight,
          textStyle: .caption
        ),
        tracking: PutioTheme.Components.Button.tracking
      )
    }
  #else
    var metrics: PutioButtonMetrics {
      switch self {
      case .regular:
        PutioButtonMetrics(
          height: PutioTheme.Components.Button.height,
          paddingX: PutioTheme.Components.Button.paddingX,
          label: PutioTheme.Components.Button.label,
          tracking: PutioTheme.Components.Button.tracking
        )
      case .medium:
        PutioButtonMetrics(
          height: PutioTheme.Components.Button.heightMedium,
          paddingX: PutioTheme.Components.Button.paddingX,
          label: PutioTheme.Components.Button.label,
          tracking: PutioTheme.Components.Button.trackingMedium
        )
      case .small:
        PutioButtonMetrics(
          height: PutioTheme.Components.Button.heightSmall,
          paddingX: PutioTheme.Components.Button.paddingX,
          label: PutioTheme.Components.Button.label,
          tracking: PutioTheme.Components.Button.trackingSmall
        )
      case .extraSmall:
        PutioButtonMetrics(
          height: PutioTheme.Components.Button.heightXSmall,
          paddingX: PutioTheme.Components.Button.paddingXXSmall,
          label: PutioTheme.Components.Button.labelXSmall,
          tracking: PutioTheme.Components.Button.trackingXSmall
        )
      }
    }
  #endif
}
