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
      .background { ContentSizeCap().frame(width: 0, height: 0) }
    }
  }
}

/// Text stops growing at XX Large, past which titles, rows, sheets and the
/// tab bar accessory crowd out their own content. SwiftUI's `dynamicTypeSize`
/// misses UIKit-presented menus and alerts; a window override reaches them.
private struct ContentSizeCap: UIViewRepresentable {
  static let maximum = UIContentSizeCategory.extraExtraLarge

  func makeUIView(context: Context) -> CapView { CapView() }
  func updateUIView(_ view: CapView, context: Context) {}

  final class CapView: UIView {
    private weak var observedScene: UIWindowScene?

    override func didMoveToWindow() {
      super.didMoveToWindow()
      guard let window, let scene = window.windowScene else { return }
      if observedScene !== scene {
        observedScene = scene
        scene.registerForTraitChanges([UITraitPreferredContentSizeCategory.self]) {
          [weak self] (_: UIWindowScene, _) in self?.apply()
        }
      }
      apply()
    }

    // The scene's category is the user's, or a harness override of it.
    private func apply() {
      guard let window, let scene = window.windowScene else { return }
      let category = scene.traitCollection.preferredContentSizeCategory
      if category == .unspecified {
        window.traitOverrides.remove(UITraitPreferredContentSizeCategory.self)
      } else {
        window.traitOverrides.preferredContentSizeCategory = min(category, ContentSizeCap.maximum)
      }
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
