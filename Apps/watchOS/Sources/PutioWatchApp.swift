import PutioCore
import SwiftUI

@main
struct PutioWatchApp: App {
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
  @PutioScaledMetric(PutioTheme.ScaledMetrics.compactContentGap) private var contentGap

  let presentation: SignedOutPresentation

  var body: some View {
    Group {
      if presentation.isHarnessExercise {
        ScrollView { content.padding(PutioTheme.Spacing.space4) }
      } else {
        content
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(PutioTheme.Colors.background)
  }

  private var content: some View {
    VStack(spacing: contentGap) {
      Text(presentation.title)
        .putioFont(PutioTheme.Typography.subheading)
        .foregroundStyle(PutioTheme.Colors.textPrimary)
      Text(presentation.message)
        .putioFont(PutioTheme.Typography.caption)
        .foregroundStyle(PutioTheme.Colors.textSecondary)
        .multilineTextAlignment(.center)
      if presentation.isHarnessExercise {
        ForEach(TypographyHarnessProof.hostileFilenames, id: \.self) { filename in
          Text(filename)
            .putioFont(PutioTheme.Typography.mono)
            .foregroundStyle(PutioTheme.Colors.textPrimary)
        }
        Text(TypographyHarnessProof.numericSample)
          .putioFont(PutioTheme.Typography.numeric)
          .foregroundStyle(PutioTheme.Colors.textSecondary)
      }
    }
  }
}
