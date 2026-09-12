import PutioCore
import SwiftUI

@main
struct PutioTVApp: App {
  private let scenario = HarnessScenario.parse(arguments: ProcessInfo.processInfo.arguments)

  var body: some Scene {
    WindowGroup {
      Group {
        switch scenario {
        case .gallery:
          PutioComponentGallery(autoAdvanceEvery: 3)
        case .exercised:
          TVHarnessExerciseView()
        case .signedOut, .signedIn, .filesBrowser, .deviceSignIn:
          TVSessionRootView(scenario: scenario)
        }
      }
      .preferredColorScheme(.dark)
      .tint(PutioTheme.Colors.accent)
    }
  }
}

// The fixed harness exercise contract: write the semantic marker and render
// the typography proof content.
private struct TVHarnessExerciseView: View {
  private let presentation = SignedOutPresentation.harnessInitialPresentation(
    arguments: ProcessInfo.processInfo.arguments)

  var body: some View {
    VStack(spacing: PutioTheme.TV.Spacing.small) {
      Text(presentation.title)
        .putioFont(PutioTheme.TV.Typography.heading)
        .foregroundStyle(PutioTheme.TV.Colors.textPrimary)
      Text(presentation.message)
        .putioFont(PutioTheme.TV.Typography.body)
        .foregroundStyle(PutioTheme.TV.Colors.textSecondary)
      ForEach(TypographyHarnessProof.hostileFilenames, id: \.self) { filename in
        Text(filename)
          .putioFont(PutioTheme.TV.Typography.label)
          .foregroundStyle(PutioTheme.TV.Colors.textPrimary)
      }
      Text(TypographyHarnessProof.numericSample)
        .putioFont(PutioTheme.TV.Typography.numeric)
        .foregroundStyle(PutioTheme.TV.Colors.textSecondary)
    }
    .tvOverscanPadding()
    .background(PutioTheme.Colors.background.ignoresSafeArea())
    .onAppear {
      SignedOutPresentation.signalHarnessExercise()
    }
  }
}
