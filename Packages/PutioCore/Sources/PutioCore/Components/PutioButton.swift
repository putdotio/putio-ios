import SwiftUI

public enum PutioButtonTier: CaseIterable, Sendable {
  case primary
  case secondary
  case success
  case danger
  case info
}

/// Where the button sits. Content actions on opaque surfaces use the stock
/// bordered styles. A button floating over media with no parent surface of
/// its own is the one place the Apple contract wants a glass layer.
public enum PutioButtonPresentation: Sendable {
  case content
  case floating
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
  private let presentation: PutioButtonPresentation
  private let action: () -> Void

  @PutioScaledMetric private var contentGap: CGFloat
  @PutioScaledMetric private var iconSize: CGFloat

  public init(
    _ title: String,
    icon: PutioIcon? = nil,
    tier: PutioButtonTier = .secondary,
    size: PutioButtonSize = .regular,
    presentation: PutioButtonPresentation = .content,
    action: @escaping () -> Void
  ) {
    self.title = title
    self.icon = icon
    self.tier = tier
    self.size = size
    self.presentation = presentation
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
      #if os(tvOS)
        // A tinted bordered button on tvOS paints the focus fill and the
        // label in the same accent; the system default fill keeps the label
        // legible, which is the TV contract's native focus.
        plainButton.tint(nil)
      #else
        plainButton
          .tint(PutioTheme.Colors.accent)
      #endif
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

  @ViewBuilder private var plainButton: some View {
    let button = Button(action: action) { label }
    switch presentation {
    case .content: button.buttonStyle(.bordered)
    case .floating: styledFloating(button, prominent: false)
    }
  }

  @ViewBuilder private func prominentButton(role: ButtonRole?, foreground: Color) -> some View {
    let button = Button(role: role, action: action) { label.foregroundStyle(foreground) }
    switch presentation {
    case .content: button.buttonStyle(.borderedProminent)
    case .floating: styledFloating(button, prominent: true)
    }
  }

  // Liquid Glass cannot be rasterized off-screen, so the snapshot lane and the
  // macOS test host assert the bordered fallbacks; captures review real glass.
  @ViewBuilder private func styledFloating(_ button: some View, prominent: Bool) -> some View {
    #if os(macOS)
      if prominent { button.buttonStyle(.borderedProminent) } else { button.buttonStyle(.bordered) }
    #else
      if HarnessRendering.usesRasterFallback {
        if prominent {
          button.buttonStyle(.borderedProminent)
        } else {
          button.buttonStyle(.bordered)
        }
      } else {
        if prominent { button.buttonStyle(.glassProminent) } else { button.buttonStyle(.glass) }
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
