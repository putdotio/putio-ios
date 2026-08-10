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
  let presentation: SignedOutPresentation

  var body: some View {
    VStack(spacing: 6) {
      Text(presentation.title)
        .font(.headline)
      Text(presentation.message)
        .font(.footnote)
        .foregroundStyle(.secondary)
        .multilineTextAlignment(.center)
    }
  }
}
