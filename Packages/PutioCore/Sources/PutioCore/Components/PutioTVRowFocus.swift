#if os(tvOS)
  import SwiftUI

  public enum PutioTVRowState: Sendable {
    case resting
    case focused
    case open
  }

  extension EnvironmentValues {
    @Entry public var putioTVRowState: PutioTVRowState = .resting
  }

  public enum PutioTVRowFocus {
    public static let fill = Color(.sRGB, red: 0.925, green: 0.925, blue: 0.925)
    public static let foreground = Color(.sRGB, red: 0.078, green: 0.078, blue: 0.078)
    public static let secondaryForeground = Color(.sRGB, red: 0.302, green: 0.302, blue: 0.302)
    public static let openFill = PutioTheme.Colors.surfaceActive
    public static let cornerRadius: CGFloat = 20
  }

  public struct PutioTVRowForeground: ShapeStyle {
    public enum Role: Sendable {
      case primary
      case secondary
      case icon
    }

    let role: Role

    public func resolve(in environment: EnvironmentValues) -> Color {
      let focused = environment.putioTVRowState == .focused
      switch role {
      case .primary:
        return focused ? PutioTVRowFocus.foreground : PutioTheme.TV.Colors.textPrimary
      case .secondary:
        return focused ? PutioTVRowFocus.secondaryForeground : PutioTheme.TV.Colors.textSecondary
      case .icon:
        return focused ? PutioTVRowFocus.foreground : PutioTheme.Components.FileRow.icon
      }
    }
  }

  extension ShapeStyle where Self == PutioTVRowForeground {
    public static var putioRowPrimary: PutioTVRowForeground { .init(role: .primary) }
    public static var putioRowSecondary: PutioTVRowForeground { .init(role: .secondary) }
    public static var putioRowIcon: PutioTVRowForeground { .init(role: .icon) }
  }
#endif
