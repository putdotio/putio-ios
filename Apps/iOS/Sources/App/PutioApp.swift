import PutioCore
import SwiftUI

@main
struct PutioApp: App {
  @UIApplicationDelegateAdaptor(PutioAppDelegate.self) private var appDelegate
  private let scenario = HarnessLaunch.scenario

  init() {
    PutioDiagnostics.start()
    // The Cast context is process-global and set once; the seeded scenario
    // drives a stub receiver instead and never touches the SDK.
    if PutioCastControllerFactory.usesGoogleCast(scenario: scenario) {
      PutioGoogleCastController.configureSharedContext(
        receiverAppID: PutioCastReceiver.appID())
    }
  }

  var body: some Scene {
    WindowGroup {
      Group {
        switch scenario {
        case .gallery:
          PutioComponentGallery(autoAdvanceEvery: 3)
        case .exercised:
          HarnessExerciseView()
        case .signedOut, .signedIn, .filesBrowser, .deviceSignIn, .live:
          SessionRootView(scenario: scenario)
        }
      }
      #if DEBUG
        .modifier(
          HarnessAccessibilityConfiguration(
            enabled: scenario == .filesBrowser
              && ProcessInfo.processInfo.arguments.contains("--putio-harness-accessibility"))
        )
        .modifier(
          HarnessRatingLinkCapture(
            enabled: scenario == .filesBrowser
              && ProcessInfo.processInfo.arguments.contains("--putio-harness-rating-link")))
      #endif
      .preferredColorScheme(.dark)
      .tint(PutioTheme.Colors.accent)
    }
  }
}

/// iOS relaunches the app for background download events and expects the
/// completion handler back once the session has delivered them.
final class PutioAppDelegate: NSObject, UIApplicationDelegate {
  func application(
    _ application: UIApplication,
    handleEventsForBackgroundURLSession identifier: String,
    completionHandler: @escaping () -> Void
  ) {
    guard identifier == PutioSystemOfflineDownloadEngine.sessionIdentifier else {
      completionHandler()
      return
    }
    PutioSystemOfflineDownloadEngine.backgroundCompletion = completionHandler
    // A relaunch for download events may never reach the signed-in shell
    // that builds an engine; the session itself must exist to drain them.
    PutioSystemOfflineDownloadEngine.activateBackgroundSession()
  }
}
