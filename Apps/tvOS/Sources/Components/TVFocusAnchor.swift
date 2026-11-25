import SwiftUI

extension View {
  /// Gives a screen state with no focusable control a focus target, so Menu
  /// pops the screen instead of reaching the hidden tab bar.
  func tvFocusAnchor(_ isActive: Bool = true) -> some View {
    focusable(isActive).focusEffectDisabled()
  }
}
