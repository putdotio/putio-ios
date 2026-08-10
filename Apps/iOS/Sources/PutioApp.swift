import PutioCore
import SwiftUI

@main
struct PutioApp: App {
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
  @Environment(\.colorScheme) private var colorScheme

  let presentation: SignedOutPresentation

  var body: some View {
    VStack(spacing: PutioTheme.Spacing.space3) {
      Text(presentation.title)
        .font(PutioTheme.Typography.title.font)
        .lineSpacing(PutioTheme.Typography.title.lineSpacing)
        .foregroundStyle(PutioTheme.Colors.text.resolve(for: colorScheme))
      Text(presentation.message)
        .font(PutioTheme.Typography.body.font)
        .lineSpacing(PutioTheme.Typography.body.lineSpacing)
        .foregroundStyle(PutioTheme.Colors.textSecondary.resolve(for: colorScheme))
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(PutioTheme.Colors.appBg.resolve(for: colorScheme))
  }
}
