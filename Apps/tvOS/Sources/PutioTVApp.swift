import PutioCore
import SwiftUI

@main
struct PutioTVApp: App {
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
    VStack(spacing: PutioTheme.TV.Spacing.small) {
      Text(presentation.title)
        .font(PutioTheme.TV.Typography.heading.font)
        .lineSpacing(PutioTheme.TV.Typography.heading.lineSpacing)
        .foregroundStyle(PutioTheme.TV.Colors.text1)
      Text(presentation.message)
        .font(PutioTheme.TV.Typography.body.font)
        .lineSpacing(PutioTheme.TV.Typography.body.lineSpacing)
        .foregroundStyle(PutioTheme.TV.Colors.text2)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(PutioTheme.Colors.appBg.resolve(for: colorScheme))
    .preferredColorScheme(.dark)
  }
}
