#if DEBUG
  import Foundation
  import PutioCore
  import SwiftUI

  /// The app half of the live harness contract (`LiveSessionContract` in
  /// Tools/PutioHarness). The app reports the activation code it displays so
  /// the harness can approve it with the putio CLI; the token never leaves the
  /// app. The sign-out launch restores whatever session a run left behind and
  /// signs it out, which revokes the run's grant.
  enum HarnessLiveSession {
    static let signOutArgument = "--putio-harness-live-sign-out"
    static let deviceCodeFilename = "putio-harness-device-code"
    static let outcomeFilename = "putio-harness-live-session"

    static func outcome(for state: PutioSessionState) -> String? {
      switch state {
      case .signedOut(nil): "no-session"
      case .signedOut(.userSignedOut): "signed-out"
      case .signedOut(.sessionExpired): "expired"
      case .signedOut(.restoreFailed), .signedOut(.authenticationFailed): "restore-failed"
      case .signOutFailed: "sign-out-failed"
      case .unknown, .authenticating, .signedIn, .signingOut: nil
      }
    }

    static func write(_ value: String, to filename: String) {
      try? Data(value.utf8).write(
        to: FileManager.default.temporaryDirectory.appending(path: filename), options: .atomic)
    }
  }

  struct HarnessLiveSessionProbe: ViewModifier {
    let session: PutioSessionStore
    let enabled: Bool
    private let signsOut = HarnessLaunch.arguments.contains(HarnessLiveSession.signOutArgument)

    func body(content: Content) -> some View {
      if enabled {
        content
          .onChange(of: session.deviceCodeSignIn, initial: true) { _, signIn in
            guard !signsOut, case .awaitingApproval(let code) = signIn else { return }
            HarnessLiveSession.write(code, to: HarnessLiveSession.deviceCodeFilename)
          }
          .onChange(of: session.state, initial: true) { _, state in
            guard signsOut else { return }
            if case .signedIn = state {
              Task { await session.signOut() }
            } else if let outcome = HarnessLiveSession.outcome(for: state) {
              HarnessLiveSession.write(outcome, to: HarnessLiveSession.outcomeFilename)
            }
          }
      } else {
        content
      }
    }
  }
#endif
