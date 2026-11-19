import PutioCore
import SwiftUI

extension View {
  func putioContentHeightDetents(_ contentHeight: CGFloat, fallback: PresentationDetent)
    -> some View
  {
    presentationDetents(contentHeight > 0 ? [.height(contentHeight)] : [fallback])
      .background {
        if HarnessLaunch.arguments.contains(HarnessScenario.launchArgument) {
          Color.clear
            .accessibilityElement()
            .accessibilityIdentifier("harness.content-height-sheet")
        }
      }
  }
}
