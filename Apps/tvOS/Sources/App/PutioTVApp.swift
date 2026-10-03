import PutioCore
import SwiftUI

@main
struct PutioTVApp: App {
  private let scenario = HarnessLaunch.scenario

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
      .tint(PutioTheme.Colors.accent)
    }
  }
}
