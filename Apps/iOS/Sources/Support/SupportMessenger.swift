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
  /// Intercom keeps its user across launches, so the id of the last login
  /// attempt is kept until a logout clears it, even if the session ends while
  /// the app is closed.
  static let attemptedUserKey = "io.put.support.attempted-user-id"

  /// The login the session wants, numbered so a completion can tell whether it
  /// still answers the current request.
  private struct Request {
    let identity: PutioSupportIdentity
    let number: UInt64
    let retrying: Bool
    let finished: (@MainActor (Bool) -> Void)?
  }

  private let configuration: IntercomConfiguration?
  private let client: any SupportMessengerClient
  private let defaults: UserDefaults
  private var isStarted = false
  private var requests: UInt64 = 0
  private var wanted: Request?
  /// Intercom runs one login at a time; a newer request waits for it.
  private var inFlight: UInt64?
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
      if login != .idle { endSession() }
      request(identity, retrying: false)
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
      request(identity, retrying: true) { [client] succeeded in
        succeeded ? client.present() : openURL(Self.supportEmail)
      }
    case .idle, .loggingIn, .retryFailed:
      openURL(Self.supportEmail)
    }
  }

  private func request(
    _ identity: PutioSupportIdentity, retrying: Bool,
    finished: (@MainActor (Bool) -> Void)? = nil
  ) {
    requests &+= 1
    wanted = Request(identity: identity, number: requests, retrying: retrying, finished: finished)
    login = .loggingIn(userID: identity.userID)
    startNextLogin()
  }

  private func startNextLogin() {
    guard inFlight == nil, let wanted, let configuration else { return }
    startIfNeeded(configuration)
    if let held = attemptedUserID, held != wanted.identity.userID { logOutAttemptedUser() }
    inFlight = wanted.number
    defaults.set(wanted.identity.userID, forKey: Self.attemptedUserKey)
    client.logIn(wanted.identity) { [weak self] succeeded in
      self?.loginFinished(wanted, succeeded: succeeded)
    }
  }

  private func loginFinished(_ attempt: Request, succeeded: Bool) {
    inFlight = nil
    guard let wanted, wanted.identity.userID == attempt.identity.userID,
      succeeded || wanted.number == attempt.number
    else {
      // Intercom may now hold a user the session no longer wants.
      logOutAttemptedUser()
      return startNextLogin()
    }
    self.wanted = nil
    if succeeded {
      login = .loggedIn(userID: wanted.identity.userID)
    } else {
      logOutAttemptedUser()
      login =
        wanted.retrying ? .retryFailed(userID: wanted.identity.userID) : .failed(wanted.identity)
    }
    wanted.finished?(succeeded)
  }

  private func endSession() {
    wanted = nil
    login = .idle
    // A login in flight is logged out when it lands.
    if inFlight == nil { logOutAttemptedUser() }
  }

  private var attemptedUserID: String? {
    defaults.string(forKey: Self.attemptedUserKey)
  }

  private func startIfNeeded(_ configuration: IntercomConfiguration) {
    guard !isStarted else { return }
    client.start(configuration)
    isStarted = true
  }

  /// Logs out whoever a login may have left in Intercom, including a user from
  /// an earlier launch whose session ended while the app was closed.
  private func logOutAttemptedUser() {
    guard let configuration, attemptedUserID != nil else { return }
    startIfNeeded(configuration)
    client.logOut()
    defaults.removeObject(forKey: Self.attemptedUserKey)
  }
}
