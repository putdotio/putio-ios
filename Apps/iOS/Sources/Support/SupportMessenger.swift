import Foundation
import PutioCore

/// The vendor calls the support messenger needs, so the lifecycle is testable
/// without the SDK.
@MainActor
protocol SupportMessengerClient {
  func start(_ configuration: IntercomConfiguration)
  func logIn(_ identity: PutioSupportIdentity, completion: @escaping @MainActor (Bool) -> Void)
  func logOut()
  func present()
}

/// Intercom for signed-in users only (#139): it starts after sign-in so replies
/// and notifications reach the account, logs in with put.io's identity hash,
/// and logs out when the session ends. It receives the account id and nothing
/// else.
@MainActor
final class PutioSupportMessenger {
  enum Login: Equatable {
    case idle
    case loggingIn(userID: String)
    case loggedIn(userID: String)
    /// The next Contact us tap retries once.
    case failed(PutioSupportIdentity)
    /// The retry failed too; Contact us opens email until the session changes.
    case retryFailed(userID: String)

    var userID: String? {
      switch self {
      case .idle: nil
      case .loggingIn(let id), .loggedIn(let id), .retryFailed(let id): id
      case .failed(let identity): identity.userID
      }
    }
  }

  static let shared = PutioSupportMessenger(
    configuration: IntercomConfiguration(), client: IntercomSupportClient())
  static let supportEmail = URL(string: "mailto:support@put.io")!
  /// Intercom keeps its user across launches, so a login attempt is remembered
  /// until a logout clears it, even if the session ends while the app is closed.
  static let loginAttemptedKey = "io.put.support.login-attempted"

  private let configuration: IntercomConfiguration?
  private let client: any SupportMessengerClient
  private let defaults: UserDefaults
  private var isStarted = false
  private var attempt: UInt64 = 0
  private(set) var login = Login.idle

  init(
    configuration: IntercomConfiguration?, client: any SupportMessengerClient,
    defaults: UserDefaults = .standard
  ) {
    self.configuration = configuration
    self.client = client
    self.defaults = defaults
  }

  func sessionDidChange(_ state: PutioSessionState, identity: PutioSupportIdentity?) {
    guard configuration != nil else { return }
    switch state {
    case .unknown:
      return
    case .signedIn:
      // Without put.io's hash identity verification rejects the login.
      guard let identity else { return endSession() }
      guard identity.userID != login.userID else { return }
      endSession()
      logIn(identity, retrying: false)
    case .signedOut, .authenticating, .signingOut, .signOutFailed:
      endSession()
    }
  }

  /// Opens the messenger for a logged-in account. Otherwise it opens email: when
  /// Intercom is switched off, still logging in, or failed twice; a first
  /// failure retries the login once and then picks.
  func contactSupport(openURL: @escaping @MainActor (URL) -> Void) {
    switch login {
    case .loggedIn:
      client.present()
    case .failed(let identity):
      logIn(identity, retrying: true) { [client] succeeded in
        succeeded ? client.present() : openURL(Self.supportEmail)
      }
    case .idle, .loggingIn, .retryFailed:
      openURL(Self.supportEmail)
    }
  }

  private func logIn(
    _ identity: PutioSupportIdentity, retrying: Bool,
    finished: (@MainActor (Bool) -> Void)? = nil
  ) {
    guard let configuration else { return }
    if !isStarted {
      client.start(configuration)
      isStarted = true
    }
    attempt &+= 1
    let current = attempt
    login = .loggingIn(userID: identity.userID)
    defaults.set(true, forKey: Self.loginAttemptedKey)
    client.logIn(identity) { [weak self] succeeded in
      guard let self else { return }
      guard current == attempt else {
        // The session moved on while this login was in flight.
        if succeeded, login == .idle {
          defaults.set(true, forKey: Self.loginAttemptedKey)
          logOutAttemptedUser()
        }
        return
      }
      if succeeded {
        login = .loggedIn(userID: identity.userID)
      } else {
        logOutAttemptedUser()
        login = retrying ? .retryFailed(userID: identity.userID) : .failed(identity)
      }
      finished?(succeeded)
    }
  }

  private func endSession() {
    attempt &+= 1
    login = .idle
    logOutAttemptedUser()
  }

  /// Logs out whoever a login may have left in Intercom, including a user from
  /// an earlier launch whose session ended while the app was closed.
  private func logOutAttemptedUser() {
    guard let configuration, defaults.bool(forKey: Self.loginAttemptedKey) else { return }
    if !isStarted {
      client.start(configuration)
      isStarted = true
    }
    client.logOut()
    defaults.removeObject(forKey: Self.loginAttemptedKey)
  }
}
