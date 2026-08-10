import PutioCore
import SwiftUI

@main
struct PutioWatchApp: App {
  @State private var presentation = SignedOutPresentation.harnessInitialPresentation(
    arguments: ProcessInfo.processInfo.arguments)

  var body: some Scene {
    WindowGroup {
      SignedOutView(presentation: presentation)
        .onAppear {
          if SignedOutPresentation.isHarnessExercise(arguments: ProcessInfo.processInfo.arguments) {
            SignedOutPresentation.signalHarnessExercise()
          }
        }
    }
  }
}

private struct SignedOutView: View {
  @Environment(\.colorScheme) private var colorScheme

  let presentation: SignedOutPresentation

  var body: some View {
    VStack(spacing: PutioTheme.Spacing.space1) {
      Text(presentation.title)
        .font(PutioTheme.Typography.subheading.font)
        .foregroundStyle(PutioTheme.Colors.text.resolve(for: colorScheme))
      Text(presentation.message)
        .font(PutioTheme.Typography.caption.font)
        .foregroundStyle(PutioTheme.Colors.textSecondary.resolve(for: colorScheme))
        .multilineTextAlignment(.center)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(PutioTheme.Colors.appBg.resolve(for: colorScheme))
    .preferredColorScheme(.dark)
  }
}
