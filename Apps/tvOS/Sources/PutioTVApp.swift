import PutioCore
import SwiftUI

@main
struct PutioTVApp: App {
  var body: some Scene {
    WindowGroup {
      SignedOutView(presentation: .putio)
    }
  }
}

private struct SignedOutView: View {
  let presentation: SignedOutPresentation

  var body: some View {
    VStack(spacing: 20) {
      Text(presentation.title)
        .font(.largeTitle.bold())
      Text(presentation.message)
        .foregroundStyle(.secondary)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .preferredColorScheme(.dark)
  }
}
