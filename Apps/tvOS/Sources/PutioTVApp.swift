import PutioCore
import SwiftUI

@main
struct PutioTVApp: App {
  @State private var presentation = SignedOutPresentation.harnessInitialPresentation(
    arguments: ProcessInfo.processInfo.arguments)

  var body: some Scene {
    WindowGroup {
      SignedOutView(presentation: presentation)
        .preferredColorScheme(.dark)
        .onAppear {
          if SignedOutPresentation.isHarnessExercise(arguments: ProcessInfo.processInfo.arguments) {
            SignedOutPresentation.signalHarnessExercise()
          }
        }
    }
  }
}

private struct SignedOutView: View {
  let presentation: SignedOutPresentation

  var body: some View {
    VStack(spacing: PutioTheme.TV.Spacing.small) {
      Text(presentation.title)
        .putioFont(PutioTheme.TV.Typography.heading)
        .foregroundStyle(PutioTheme.TV.Colors.textPrimary)
      Text(presentation.message)
        .putioFont(PutioTheme.TV.Typography.body)
        .foregroundStyle(PutioTheme.TV.Colors.textSecondary)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(PutioTheme.Colors.background)
  }
}
