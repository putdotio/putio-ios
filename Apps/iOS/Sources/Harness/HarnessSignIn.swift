import PutioCore
import SwiftUI

#if DEBUG
  @MainActor
  enum HarnessSignIn {
    static let cancelsOnceArgument = "--putio-harness-sign-in-cancels-once"
    static let failsOnceArgument = "--putio-harness-sign-in-fails-once"
    static let checkSecondsArgument = "--putio-harness-sign-in-check-seconds"
    static let welcomeFrameArgument = "--putio-harness-welcome-frame"

    private static var cancelPending = HarnessLaunch.arguments.contains(cancelsOnceArgument)
    private static var failurePending = HarnessLaunch.arguments.contains(failsOnceArgument)

    static var pinnedWelcomeFrame: Int? { value(after: welcomeFrameArgument).flatMap(Int.init) }

    static var exposesWelcomeStage: Bool {
      HarnessLaunch.arguments.contains(HarnessScenario.launchArgument)
    }

    private static var checkDuration: Duration? {
      value(after: checkSecondsArgument).flatMap(Double.init).map { .seconds($0) }
    }

    static func complete(_ request: PutioSignInRequest, session: PutioSessionStore) async {
      if cancelPending {
        cancelPending = false
        session.cancelSignIn()
        return
      }
      let callbackURL: URL
      do {
        callbackURL = try PutioRuntimeFactory.runtimeProofCallback(for: request)
      } catch {
        session.failSignIn(error)
        return
      }
      if let checkDuration {
        try? await Task.sleep(for: checkDuration)
      }
      if failurePending {
        failurePending = false
        await session.completeSignIn(callbackURL: staleCallback(callbackURL))
        return
      }
      await session.completeSignIn(callbackURL: callbackURL)
    }

    private static func staleCallback(_ callbackURL: URL) -> URL {
      var components = URLComponents(url: callbackURL, resolvingAgainstBaseURL: false)
      components?.fragment = "access_token=\(HarnessSeededAPI.token)&state=harness-stale-state"
      return components?.url ?? callbackURL
    }

    private static func value(after argument: String) -> String? {
      let arguments = HarnessLaunch.arguments
      guard let index = arguments.firstIndex(of: argument), arguments.indices.contains(index + 1)
      else { return nil }
      return arguments[index + 1]
    }
  }

  struct HarnessWelcomeStageProbe: View {
    let frame: Int
    let rolls: Bool
    let showsDots: Bool

    var body: some View {
      Color.clear
        .frame(width: 1, height: 1)
        .accessibilityElement()
        .accessibilityLabel("Welcome stage")
        .accessibilityValue("frame=\(frame);rolling=\(rolls);dots=\(showsDots)")
        .accessibilityIdentifier("welcome.stage")
        .allowsHitTesting(false)
    }
  }
#endif
