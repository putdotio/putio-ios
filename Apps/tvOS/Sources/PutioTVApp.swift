import PutioCore
import SwiftUI

@main
struct PutioTVApp: App {
  @State private var presentation = SignedOutPresentation.harnessInitialPresentation(
    arguments: ProcessInfo.processInfo.arguments)

  var body: some Scene {
    WindowGroup {
      Group {
        if HarnessScenario.parse(arguments: ProcessInfo.processInfo.arguments) == .gallery {
          PutioComponentGallery(autoAdvanceEvery: 3)
        } else {
          SignedOutView(presentation: presentation)
        }
      }
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
      if presentation.isHarnessExercise {
        ForEach(TypographyHarnessProof.hostileFilenames, id: \.self) { filename in
          Text(filename)
            .putioFont(PutioTheme.TV.Typography.label)
            .foregroundStyle(PutioTheme.TV.Colors.textPrimary)
        }
        Text(TypographyHarnessProof.numericSample)
          .putioFont(PutioTheme.TV.Typography.numeric)
          .foregroundStyle(PutioTheme.TV.Colors.textSecondary)
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(PutioTheme.Colors.background)
  }
}
