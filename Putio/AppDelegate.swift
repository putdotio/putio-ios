import UIKit
import Intercom
import SwiftyJSON
import RealmSwift
import PutioAPI
import SwiftyBeaver
import Sentry
import GoogleCast

let log = SwiftyBeaver.self

@UIApplicationMain
class AppDelegate: UIResponder, UIApplicationDelegate {
    var window: UIWindow?

    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplicationLaunchOptionsKey: Any]?) -> Bool {
        configureLogger()
        configureSDKs()
        configureUI()
        authenticate()
        return true
    }

    func configureLogger() {
        #if DEBUG
        let console = ConsoleDestination()
        log.addDestination(console)
        #endif
    }

    func configureSDKs() {
        PutioRealm.setup()

        SentrySDK.start { options in
            options.dsn = SENTRY_DSN
            options.enableAutoSessionTracking = true
            options.sessionTrackingIntervalMillis = 60000
            options.enableOutOfMemoryTracking = false
        }

        Intercom.setApiKey(INTERCOM_API_KEY, forAppId: INTERCOM_APP_ID)
    }

    func configureUI() {
        Stylize.UIKit(window: window)
        NetworkReachability.sharedInstance.setup()
        Utils.configureAVSession()
    }

    func application(_ application: UIApplication, handleEventsForBackgroundURLSession identifier: String, completionHandler: @escaping () -> Void) {
        completionHandler()
    }

    func application(_ application: UIApplication, open url: URL, sourceApplication: String?, annotation: Any) -> Bool {
        return DeeplinkManager.sharedInstance.handleURL(url: url)
    }

    func application(_ application: UIApplication, continue userActivity: NSUserActivity, restorationHandler: @escaping ([Any]?) -> Void) -> Bool {
        guard userActivity.activityType == NSUserActivityTypeBrowsingWeb, let url = userActivity.webpageURL else {
            return false
        }

        return DeeplinkManager.sharedInstance.handleURL(url: url)
    }

    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        Intercom.setDeviceToken(deviceToken)
    }

    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
        SentrySDK.capture(error: error)
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse, withCompletionHandler completionHandler: @escaping () -> Void) {
        let userInfo = response.notification.request.content.userInfo

        if Intercom.isIntercomPushNotification(userInfo) {
            Intercom.handlePushNotification(userInfo)
            completionHandler()
        }
    }

    func authenticate(token: String? = nil) {
        guard let token = token ?? PutioKeychain.sharedInstance.getToken() else {
            return presentLoginScreen()
        }

        PutioKeychain.sharedInstance.setToken(token)
        api.setToken(token: token)
        fetchUserData()
    }

    func fetchUserData() {
        let accountInfoQuery: [String: Any] = [
            "download_token": 1,
            "features": 1,
            "intercom": 1,
            "platform": "ios"
        ]

        api.getAccountInfo(query: accountInfoQuery) { result in
            switch result {
            case .success(let account):
                return self.fetchUserDataSuccess(account: account)

            case .failure(let error):
                return self.fetchUserDataFailure(error: error)
            }
        }
    }

    func fetchUserDataSuccess(account: PutioAccount) {
        let realm = try! Realm()
        let user = realm.objects(User.self).first

        if let user = user {
            try! realm.write {
                realm.delete(user)
            }
        }

        try! realm.write {
            realm.add(User(account: account)!, update: .all)
        }

        Utils.authorizeNotifications(application: UIApplication.shared)

        let attributes = ICMUserAttributes()
        attributes.userId = String(account.id)
        Intercom.loginUser(with: attributes)
        Intercom.setUserHash(account.hash)

        self.presentMainScreen()
    }

    func fetchUserDataFailure(error: PutioAPIError) {
        let realm = try! Realm()
        let user = realm.objects(User.self).first

        switch error.type {
        case .unknownError, .networkError:
            if user != nil {
                return self.presentMainScreen()
            }

            self.presentLoginScreen()

        case .httpError(let statusCode, let errorType):
            if statusCode == 401 || errorType == "Unauthorized" {
                return self.presentLoginScreen()
            }

            if user != nil {
                return self.presentMainScreen()
            }

            return self.presentLoginScreen()
        }
    }

    func logout() {
        PutioKeychain.sharedInstance.clearToken()
        api.clearToken()
        Intercom.logout()
        presentLoginScreen()
    }

    func presentLoginScreen() {
        let controller = UIStoryboard(name: "Login", bundle: nil).instantiateViewController(withIdentifier: "LoginVC")
        window?.rootViewController = controller
        window?.makeKeyAndVisible()
    }

    func presentMainScreen() {
        ChromecastManager.sharedInstance.setup()

        let controller = UIStoryboard(name: "Main", bundle: nil).instantiateViewController(withIdentifier: "MainTabBarController")
        let castContainerVC = GCKCastContext.sharedInstance().createCastContainerController(for: controller)
        castContainerVC.miniMediaControlsItemEnabled = true
        castContainerVC.view.backgroundColor = UIColor.Putio.black

        window?.rootViewController = castContainerVC
        window?.makeKeyAndVisible()
    }
}
