import Intercom
import PutioCore
import UIKit

/// The app's only Intercom entry point; `scripts/test.sh` rejects
/// `import Intercom` anywhere else.
@MainActor
struct IntercomSupportClient: SupportMessengerClient {
  func start(_ configuration: IntercomConfiguration) {
    Intercom.setApiKey(configuration.apiKey, forAppId: configuration.appID)
  }

  func logIn(_ identity: PutioSupportIdentity, completion: @escaping @MainActor (Bool) -> Void) {
    // Intercom keeps its user across launches and asks for one login per
    // user; a relaunch reuses it, and anyone else is logged out first.
    if Intercom.isUserLoggedIn() {
      if Intercom.fetchLoggedInUserAttributes()?.userId == identity.userID {
        Intercom.setUserHash(identity.userHash)
        return completion(true)
      }
      Intercom.logout()
    }
    // Identity verification needs the hash right before the login; a logout
    // clears it.
    Intercom.setUserHash(identity.userHash)
    let attributes = ICMUserAttributes()
    attributes.userId = identity.userID
    Intercom.loginUser(with: attributes) { result in
      let succeeded = (try? result.get()) != nil
      Task { @MainActor in completion(succeeded) }
    }
  }

  func logOut() {
    Intercom.logout()
  }

  func present() {
    Intercom.present()
  }

  func registerForRemoteNotifications() {
    UIApplication.shared.registerForRemoteNotifications()
  }

  func setDeviceToken(_ token: Data) {
    Intercom.setDeviceToken(token, completion: nil)
  }

  func isSupportNotification(_ userInfo: [AnyHashable: Any]) -> Bool {
    Intercom.isIntercomPushNotification(userInfo)
  }

  func openNotification(_ userInfo: [AnyHashable: Any]) {
    Intercom.handlePushNotification(userInfo)
  }
}
