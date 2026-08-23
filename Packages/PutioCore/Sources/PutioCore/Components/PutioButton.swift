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

// One Button, native first, on every shell: the tiers map onto the stock
// Liquid Glass button styles with token tints, and the titles carry the brand
// face at the medium control weight — the shipping app's recipe of native box
// plus brand type. tvOS uses the system focus treatment; the TV contract's
// solid-focus rule is deliberately overridden for buttons (see DESIGN.md).
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
      // ControlSize is unavailable on tvOS: every size shares the one TV box.
      nativeButton
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
    .putioFont(size.brandLabel)
  }

  @ViewBuilder private var nativeButton: some View {
    switch tier {
    case .primary:
      prominentButton(role: nil, foreground: PutioTheme.Components.Button.primaryForeground)
        .tint(PutioTheme.Colors.accent)
    case .secondary:
      styledSecondary(
        Button(action: action) {
          label
        }
      )
      .tint(PutioTheme.Colors.textPrimary)
    case .ghost:
      Button(action: action) {
        label
      }
      .buttonStyle(.borderless)
      .tint(PutioTheme.Colors.accent)
    case .success:
      prominentButton(role: nil, foreground: PutioTheme.Components.Button.successForeground)
        .tint(PutioTheme.Colors.success)
    case .danger:
      prominentButton(
        role: .destructive,
        foreground: PutioTheme.Components.Button.dangerForeground
      )
      .tint(PutioTheme.Colors.destructive)
    case .info:
      prominentButton(role: nil, foreground: PutioTheme.Components.Button.infoForeground)
        .tint(PutioTheme.Components.Button.infoBackground)
    }
  }

  private func prominentButton(role: ButtonRole?, foreground: Color) -> some View {
    styledProminent(
      Button(role: role, action: action) {
        label.foregroundStyle(foreground)
      }
    )
  }

  // Liquid Glass cannot be rasterized off-screen, so the snapshot lane
  // asserts the bordered fallbacks; captures review the real glass. The
  // macOS 15 test host predates glass and keeps the bordered styles.
  @ViewBuilder private func styledProminent(_ button: some View) -> some View {
    #if os(macOS)
      button.buttonStyle(.borderedProminent)
    #else
      if HarnessRendering.usesRasterFallback {
        button.buttonStyle(.borderedProminent)
      } else {
        button.buttonStyle(.glassProminent)
      }
    #endif
  }

  @ViewBuilder private func styledSecondary(_ button: some View) -> some View {
    #if os(macOS)
      button.buttonStyle(.bordered)
    #else
      if HarnessRendering.usesRasterFallback {
        button.buttonStyle(.bordered)
      } else {
        button.buttonStyle(.glass)
      }
    #endif
  }
}

extension PutioButtonSize {
  // Native control box, brand face at the medium control weight, sized from
  // the token type scale at the step closest to each native control size.
  var brandLabel: PutioFontRole {
    #if os(tvOS)
      PutioFontRole(
        fontName: PutioTheme.Components.Button.label.fontName,
        size: PutioTheme.TV.Typography.caption.size,
        lineHeight: PutioTheme.TV.Typography.label.lineHeight,
        textStyle: .caption
      )
    #else
      let mediumFace = PutioTheme.Components.Button.label.fontName
      let lineHeight = PutioTheme.Components.Button.label.lineHeight
      return switch self {
      case .regular:
        PutioFontRole(
          fontName: mediumFace,
          size: PutioTheme.Typography.sizeBase,
          lineHeight: lineHeight,
          textStyle: .body
        )
      case .medium, .small:
        PutioFontRole(
          fontName: mediumFace,
          size: PutioTheme.Typography.sizeSm,
          lineHeight: lineHeight,
          textStyle: .subheadline
        )
      case .extraSmall:
        PutioFontRole(
          fontName: mediumFace,
          size: PutioTheme.Typography.sizeXs,
          lineHeight: lineHeight,
          textStyle: .caption
        )
      }
    #endif
  }

  #if !os(tvOS)
    var controlSize: ControlSize {
      switch self {
      case .regular: .large
      case .medium: .regular
      case .small: .small
      case .extraSmall: .mini
      }
    }
  #endif
}
