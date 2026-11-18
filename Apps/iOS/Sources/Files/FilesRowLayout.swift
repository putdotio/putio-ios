import PutioCore
import SwiftUI

extension View {
  func putioFilesRowLabel() -> some View {
    modifier(PutioFilesRowLabel())
  }

  func putioFilesRowPitch() -> some View {
    modifier(PutioFilesRowPitch())
  }
}

private struct PutioFilesRowLabel: ViewModifier {
  @Environment(\.horizontalSizeClass) private var horizontalSizeClass
  @PutioScaledMetric(PutioMetricRole(value: 60, relativeTo: .body)) private var minHeight

  func body(content: Content) -> some View {
    content.frame(minHeight: horizontalSizeClass == .regular ? minHeight : nil)
  }
}

private struct PutioFilesRowPitch: ViewModifier {
  @Environment(\.horizontalSizeClass) private var horizontalSizeClass

  func body(content: Content) -> some View {
    if horizontalSizeClass == .regular {
      content
        .listRowInsets(.vertical, PutioTheme.Spacing.space0)
        .alignmentGuide(.listRowSeparatorLeading) { -$0.width }
    } else {
      content
    }
  }
}
