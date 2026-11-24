import PutioCore
import SwiftUI

@main
struct PutioTVApp: App {
  private let scenario = HarnessLaunch.scenario

  init() {
    PutioDiagnostics.start()
  }

  var body: some Scene {
    WindowGroup {
      Group {
        switch scenario {
        case .gallery:
          PutioComponentGallery(autoAdvanceEvery: 3)
        case .exercised:
          TVHarnessExerciseView()
        case .signedOut, .signedIn, .filesBrowser, .deviceSignIn, .live:
          TVSessionRootView(scenario: scenario)
        }
      }
      .preferredColorScheme(.dark)
      .progressViewStyle(TVAccentProgressStyle())
    }
  }
}

struct TVAccentProgressStyle: ProgressViewStyle {
  func makeBody(configuration: Configuration) -> some View {
    ProgressView(configuration)
      .tint(PutioTheme.Colors.accent)
  }
}
