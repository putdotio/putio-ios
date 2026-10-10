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
  static let shared = PutioSupportMessenger(
    configuration: IntercomConfiguration(), client: IntercomSupportClient())
  static let supportEmail = URL(string: "mailto:support@put.io")!

  private let configuration: IntercomConfiguration?
  private let client: any SupportMessengerClient
  private var isStarted = false
  private(set) var loggedInUserID: String?

  init(configuration: IntercomConfiguration?, client: any SupportMessengerClient) {
    self.configuration = configuration
    self.client = client
  }

  func sessionDidChange(_ state: PutioSessionState, identity: PutioSupportIdentity?) {
    guard let configuration else { return }
    switch state {
    case .unknown:
      return
    case .signedIn:
      // Without put.io's hash identity verification rejects the login.
      guard let identity else { return logOut() }
      guard identity.userID != loggedInUserID else { return }
      logOut()
      if !isStarted {
        client.start(configuration)
        isStarted = true
      }
      loggedInUserID = identity.userID
      client.logIn(identity) { [weak self] succeeded in
        guard !succeeded, self?.loggedInUserID == identity.userID else { return }
        self?.loggedInUserID = nil
      }
    case .signedOut, .authenticating, .signingOut, .signOutFailed:
      logOut()
    }
  }

  /// Opens the messenger for a logged-in account, or email when Intercom is
  /// switched off or the login failed.
  func contactSupport(openURL: (URL) -> Void) {
    if loggedInUserID != nil {
      client.present()
    } else {
      openURL(Self.supportEmail)
    }
  }

  private func logOut() {
    guard loggedInUserID != nil else { return }
    loggedInUserID = nil
    client.logOut()
  }
}
