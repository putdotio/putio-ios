import PutioCore
import SwiftUI

@main
struct PutioWatchApp: App {
  var body: some Scene {
    WindowGroup {
      SignedOutView(presentation: .putio)
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
