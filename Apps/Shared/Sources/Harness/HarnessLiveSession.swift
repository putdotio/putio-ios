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
    /// Written only once put.io has revoked or rejected the run's token.
    static let revokedFilename = "putio-harness-live-revoked"

    static func outcome(for state: PutioSessionState, signOutCleanupPending: Bool) -> String? {
      switch state {
      case .signedOut(nil): "no-session"
      case .signedOut(.userSignedOut): signOutCleanupPending ? "sign-out-failed" : "signed-out"
      case .signedOut(.sessionExpired): "expired"
      case .signedOut(.restoreFailed), .signedOut(.authenticationFailed): "restore-failed"
      case .unknown, .authenticating, .signedIn, .signingOut: nil
      }
    }

    static func provesRevocation(_ state: PutioSessionState, signOutCleanupPending: Bool)
      -> Bool
    {
      (state == .signedOut(.userSignedOut) && !signOutCleanupPending)
        || state == .signedOut(.sessionExpired)
    }

    static func write(_ value: String, to filename: String) {
      try? Data(value.utf8).write(
        to: FileManager.default.temporaryDirectory.appending(path: filename), options: .atomic)
    }
  }

  final class HarnessLiveTokenStore: PutioTokenStore, @unchecked Sendable {
    private let active: PutioTokenStore
    private let pending: PutioTokenStore

    init(active: PutioTokenStore, pending: PutioTokenStore) {
      self.active = active
      self.pending = pending
    }

    convenience init(service: String) {
      self.init(
        active: PutioKeychainTokenStore(service: service),
        pending: PutioKeychainTokenStore(service: service + ".pending-revocation"))
    }

    func read() throws -> String? {
      if let token = try active.read(), !token.isEmpty { return token }
      return try pending.read()
    }

    func write(_ token: String) throws { try active.write(token) }

    func clear() throws {
      if let token = try active.read(), !token.isEmpty { try pending.write(token) }
      try active.clear()
    }

    func confirmRevoked() throws { try pending.clear() }
  }

  struct HarnessLiveSessionProbe: ViewModifier {
    let session: PutioSessionStore
    let tokenStore: HarnessLiveTokenStore?
    private let signsOut = HarnessLaunch.arguments.contains(HarnessLiveSession.signOutArgument)

    func body(content: Content) -> some View {
      if let tokenStore {
        content
          .onChange(of: session.deviceCodeSignIn, initial: true) { _, signIn in
            guard !signsOut, case .awaitingApproval(let code) = signIn else { return }
            HarnessLiveSession.write(code, to: HarnessLiveSession.deviceCodeFilename)
          }
          .onChange(of: session.state, initial: true) { _, state in
            // The marker lands before the outcome the harness waits for.
            let cleanupPending = session.isSignOutCleanupPending
            if HarnessLiveSession.provesRevocation(state, signOutCleanupPending: cleanupPending),
              (try? tokenStore.confirmRevoked()) != nil
            {
              HarnessLiveSession.write("revoked", to: HarnessLiveSession.revokedFilename)
            }
            guard signsOut else { return }
            if case .signedIn = state {
              Task { await session.signOut() }
            } else if let outcome = HarnessLiveSession.outcome(
              for: state, signOutCleanupPending: cleanupPending)
            {
              HarnessLiveSession.write(outcome, to: HarnessLiveSession.outcomeFilename)
            }
          }
      } else {
        content
      }
    }
  }
#endif
