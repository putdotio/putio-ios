import PutioCore
import SwiftUI

@main
struct PutioApp: App {
  @State private var presentation = SignedOutPresentation.harnessInitialPresentation(
    arguments: ProcessInfo.processInfo.arguments)

  var body: some Scene {
    WindowGroup {
      SignedOutView(presentation: presentation)
        .modifier(
          HarnessDynamicTypeModifier(
            enabled: SignedOutPresentation.isHarnessExercise(
              arguments: ProcessInfo.processInfo.arguments)
          )
        )
        .preferredColorScheme(.dark)
        .onAppear {
          if SignedOutPresentation.isHarnessExercise(arguments: ProcessInfo.processInfo.arguments) {
            SignedOutPresentation.signalHarnessExercise()
          }
        }
    }
  }
}

private struct HarnessDynamicTypeModifier: ViewModifier {
  let enabled: Bool

  @ViewBuilder
  func body(content: Content) -> some View {
    if enabled {
      content.dynamicTypeSize(.accessibility3)
    } else {
      content
    }
  }
}

private struct SignedOutView: View {
  @PutioScaledMetric(PutioTheme.ScaledMetrics.contentGap) private var contentGap

  let presentation: SignedOutPresentation

  var body: some View {
    VStack(spacing: contentGap) {
      if presentation.isHarnessExercise {
        Image(systemName: "externaldrive.fill")
          .putioIcon(PutioTheme.Icons.button)
          .foregroundStyle(PutioTheme.Colors.accent)
      }
      Text(presentation.title)
        .putioFont(PutioTheme.Typography.title)
        .foregroundStyle(PutioTheme.Colors.textPrimary)
      Text(presentation.message)
        .putioFont(PutioTheme.Typography.body)
        .foregroundStyle(PutioTheme.Colors.textSecondary)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(PutioTheme.Colors.background)
  }
}
