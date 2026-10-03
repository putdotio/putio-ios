import PutioCore
import SwiftUI

extension View {
  /// Keeps content inside the token overscan ratios. The system safe area
  /// already reserves an inset on Apple TV; this only tops it up so the
  /// total clears the ratio without doubling the margin.
  func tvOverscanPadding() -> some View {
    modifier(TVOverscanPadding())
  }
}

private struct TVOverscanPadding: ViewModifier {
  func body(content: Content) -> some View {
    GeometryReader { proxy in
      let insets = proxy.safeAreaInsets
      let horizontal =
        (proxy.size.width + insets.leading + insets.trailing)
        * PutioTheme.TV.Overscan.horizontal
      let vertical =
        (proxy.size.height + insets.top + insets.bottom) * PutioTheme.TV.Overscan.vertical
      content
        .padding(.leading, max(0, horizontal - insets.leading))
        .padding(.trailing, max(0, horizontal - insets.trailing))
        .padding(.top, max(0, vertical - insets.top))
        .padding(.bottom, max(0, vertical - insets.bottom))
        .frame(width: proxy.size.width, height: proxy.size.height)
    }
  }
}
