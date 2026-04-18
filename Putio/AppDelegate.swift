import UIKit
import Intercom
import SwiftyJSON
import RealmSwift
import PutioSDK
import SwiftyBeaver
import Sentry
import GoogleCast

let log = SwiftyBeaver.self

@UIApplicationMain
class AppDelegate: UIResponder, UIApplicationDelegate {
    var window: UIWindow?

    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
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

        if SENTRY_ENABLED {
            SentrySDK.start { options in
                options.dsn = SENTRY_DSN
                options.enableAutoSessionTracking = true
                options.sessionTrackingIntervalMillis = 60000
            }
        }

        if INTERCOM_ENABLED {
            Intercom.setApiKey(INTERCOM_API_KEY, forAppId: INTERCOM_APP_ID)
        }
    }

    func configureUI() {
        applyWindowAppearance()
        Stylize.UIKit(window: window)
        NetworkReachability.sharedInstance.setup()
        Utils.configureAVSession()
    }

    func applyWindowAppearance() {
        window?.backgroundColor = UIColor.Putio.black
        window?.tintColor = UIColor.Putio.yellow
        window?.overrideUserInterfaceStyle = .dark
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
        if INTERCOM_ENABLED {
            Intercom.setDeviceToken(deviceToken, completion: nil)
        }
    }

    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
        if SENTRY_ENABLED {
            SentrySDK.capture(error: error)
        }
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse, withCompletionHandler completionHandler: @escaping () -> Void) {
        let userInfo = response.notification.request.content.userInfo

        if INTERCOM_ENABLED, Intercom.isIntercomPushNotification(userInfo) {
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
        fetchUser()
    }

    func fetchUser() {
        let dispatchGroup = DispatchGroup()
        
        var account: PutioAccount?
        var accountError: PutioSDKError?
        
        var config: JSON?
        var configError: PutioSDKError?
        
        let accountInfoQuery: [String: Any] = [
            "download_token": 1,
            "intercom": 1,
            "platform": "ios"
        ]

        dispatchGroup.enter()
        api.getAccountInfo(query: accountInfoQuery) { result in
            switch result {
            case .success(let accountData):
                account = accountData
            case .failure(let error):
                accountError = error
            }
            dispatchGroup.leave()
        }
        
        dispatchGroup.enter()
        api.get("/config") { result in
            switch result {
            case .success(let json):
                config = json["config"]
            case .failure(let error):
                configError = error
            }
            dispatchGroup.leave()
        }
        
        dispatchGroup.notify(queue: .main) {
            if let accountError = accountError {
                return self.fetchUserFailure(error: accountError)
            }
            
            if let configError = configError {
                return self.fetchUserFailure(error: configError)
            }
            
            if let account = account, let config = config {
                return self.fetchUserSuccess(account: account, config: config)
            }
        }
    }

    func fetchUserSuccess(account: PutioAccount, config: JSON) {
        let realm = try! Realm()
        let user = realm.objects(User.self).first
        let userConfig = realm.objects(UserConfig.self).first

        if let user = user { try! realm.write { realm.delete(user) } }
        if let userConfig = userConfig { try! realm.write { realm.delete(userConfig) } }
    
        try! realm.write {
            realm.add(User(account: account)!, update: .all)
            realm.add(UserConfig(json: config)!)
        }

        Utils.authorizeNotifications(application: UIApplication.shared)

        if INTERCOM_ENABLED {
            let attributes = ICMUserAttributes()
            attributes.userId = String(account.id)
            Intercom.loginUser(with: attributes)
            Intercom.setUserHash(account.hash)
        }

        self.presentMainScreen()
    }

    func fetchUserFailure(error: PutioSDKError) {
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
        applyWindowAppearance()
        window?.rootViewController = UIStoryboard(name: "Login", bundle: nil).instantiateViewController(withIdentifier: "LoginVC")
        window?.makeKeyAndVisible()
    }

    func presentMainScreen() {
        ChromecastManager.sharedInstance.setup()
        applyWindowAppearance()
        window?.rootViewController = RootContainerViewController()
        window?.makeKeyAndVisible()
    }
}
