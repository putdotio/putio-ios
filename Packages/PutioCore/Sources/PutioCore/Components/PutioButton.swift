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

// One Button, native first: on iOS and watchOS the tiers map onto the stock
// button styles with token tints, so the controls stay platform chrome with
// brand color on top. tvOS keeps the TV contract's painted solid-fill
// treatment because the system focus style lifts and scales.
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
    #if os(tvOS)
      Button(action: action) {
        label
      }
      .buttonStyle(PutioTVButtonStyle(tier: tier))
    #else
      nativeButton
        .controlSize(size.controlSize)
    #endif
  }

  private var label: some View {
    HStack(spacing: contentGap) {
      if let icon {
        Image(putioIcon: icon)
          .resizable()
          .scaledToFit()
          .frame(width: iconSize, height: iconSize)
      }
      Text(title)
    }
  }

  #if !os(tvOS)
    @ViewBuilder private var nativeButton: some View {
      switch tier {
      case .primary:
        Button(action: action) {
          label.foregroundStyle(PutioTheme.Components.Button.primaryForeground)
        }
        .buttonStyle(.borderedProminent)
        .tint(PutioTheme.Colors.accent)
      case .secondary:
        Button(action: action) {
          label
        }
        .buttonStyle(.bordered)
        .tint(PutioTheme.Colors.textPrimary)
      case .ghost:
        Button(action: action) {
          label
        }
        .buttonStyle(.borderless)
        .tint(PutioTheme.Colors.accent)
      case .success:
        Button(action: action) {
          label.foregroundStyle(PutioTheme.Components.Button.successForeground)
        }
        .buttonStyle(.borderedProminent)
        .tint(PutioTheme.Colors.success)
      case .danger:
        Button(role: .destructive, action: action) {
          label.foregroundStyle(PutioTheme.Components.Button.dangerForeground)
        }
        .buttonStyle(.borderedProminent)
        .tint(PutioTheme.Colors.destructive)
      case .info:
        Button(action: action) {
          label.foregroundStyle(PutioTheme.Components.Button.infoForeground)
        }
        .buttonStyle(.borderedProminent)
        .tint(PutioTheme.Components.Button.infoBackground)
      }
    }
  #endif
}

#if !os(tvOS)
  extension PutioButtonSize {
    var controlSize: ControlSize {
      switch self {
      case .regular: .large
      case .medium: .regular
      case .small: .small
      case .extraSmall: .mini
      }
    }
  }
#endif

#if os(tvOS)
  // TV keeps the contract's painted treatment: solid token fills, the single
  // TV radius, and focus expressed as a solid fill plus a border step —
  // never the system scale/lift.
  struct PutioTVButtonStyle: ButtonStyle {
    let tier: PutioButtonTier

    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.isFocused) private var isFocused

    func makeBody(configuration: Configuration) -> some View {
      let state = resolvedState(isPressed: configuration.isPressed)
      return configuration.label
        .putioFont(PutioTVButtonStyle.label)
        .lineLimit(1)
        .foregroundStyle(state.foreground)
        .padding(.horizontal, PutioTheme.TV.Spacing.medium)
        .frame(minHeight: PutioTheme.TV.Spacing.large)
        .background(state.background, in: shape)
        .overlay(shape.strokeBorder(state.border, lineWidth: PutioTheme.Border.width))
        .opacity(isEnabled || !tier.palette.dimsWhenDisabled ? 1 : Self.disabledOpacity)
        .animation(
          PutioTheme.Motion.easingOut.animation(duration: PutioTheme.Motion.durationFast),
          value: configuration.isPressed
        )
    }

    // The web contract fades disabled filled buttons (`button:disabled`); the
    // ratio is not in the token graph.
    static let disabledOpacity = 0.3

    static let label = PutioFontRole(
      fontName: PutioTheme.TV.Typography.label.fontName,
      size: PutioTheme.TV.Typography.caption.size,
      lineHeight: PutioTheme.TV.Typography.label.lineHeight,
      textStyle: .caption
    )

    private var shape: RoundedRectangle {
      RoundedRectangle(cornerRadius: PutioTheme.TV.radius)
    }

    private struct ResolvedState {
      let background: Color
      let foreground: Color
      let border: Color
    }

    private func resolvedState(isPressed: Bool) -> ResolvedState {
      let palette = tier.palette
      if !isEnabled && !palette.dimsWhenDisabled {
        return ResolvedState(
          background: PutioTheme.Components.Button.ghostBackground,
          foreground: PutioTheme.Colors.textDisabled,
          border: .clear
        )
      }
      if isFocused {
        return ResolvedState(
          background: palette.focusBackground,
          foreground: palette.pressedForeground ?? palette.foreground,
          border: palette.focusBorder
        )
      }
      if isPressed {
        return ResolvedState(
          background: palette.pressedBackground,
          foreground: palette.pressedForeground ?? palette.foreground,
          border: palette.pressedBorder ?? palette.pressedBackground
        )
      }
      return ResolvedState(
        background: palette.background,
        foreground: palette.foreground,
        border: palette.border ?? palette.background
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

    // The TV focus contract restores a visible box: a solid fill plus a
    // border step, never a scale, lift, or halo.
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
#endif
