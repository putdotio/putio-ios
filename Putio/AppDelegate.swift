import UIKit
import Intercom
import RealmSwift
import PutioSDK
import SwiftyBeaver
import Sentry
import GoogleCast

let log = SwiftyBeaver.self

@UIApplicationMain
class AppDelegate: UIResponder, UIApplicationDelegate {
    var window: UIWindow?
    private var isRunningUnitTests: Bool {
        let environment = ProcessInfo.processInfo.environment
        return [
            "XCTestConfigurationFilePath",
            "XCTestBundlePath",
            "XCTestSessionIdentifier"
        ].contains { key in
            guard let value = environment[key] else {
                return false
            }

            return value.isEmpty == false
        }
    }

    private var e2eAccessToken: String? {
        #if DEBUG
        return ProcessInfo.processInfo.environment["PUTIO_E2E_ACCESS_TOKEN"]
        #else
        return nil
        #endif
    }

    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        configureLogger()

        if isRunningUnitTests {
            prepareForUnitTests(application: application)
            return true
        }

        configureSDKs()
        prepareForE2ETestsIfNeeded()
        configureUI()
        authenticate(token: e2eAccessToken)
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

    func prepareForUnitTests(application: UIApplication) {
        guard let windowScene = application.connectedScenes.compactMap({ $0 as? UIWindowScene }).first else {
            window = nil
            return
        }

        let testWindow = UIWindow(windowScene: windowScene)
        testWindow.rootViewController = UIViewController()
        window = testWindow
        applyWindowAppearance()
        testWindow.makeKeyAndVisible()
    }

    func prepareForE2ETestsIfNeeded() {
        #if DEBUG
        guard ProcessInfo.processInfo.environment["PUTIO_E2E_RESET_STATE"] == "1" else { return }

        PutioKeychain.sharedInstance.clearToken()
        if let realm = PutioRealm.open(context: "prepareForE2ETests") {
            _ = PutioRealm.write(realm, context: "prepareForE2ETests.clearRealm") {
                realm.deleteAll()
            }
        }
        #endif
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

    func application(_ application: UIApplication, continue userActivity: NSUserActivity, restorationHandler: @escaping ([any UIUserActivityRestoring]?) -> Void) -> Bool {
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
        }

        completionHandler()
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
        
        var config: PutioConfig?
        var configError: PutioSDKError?
        
        let accountInfoQuery = PutioAccountInfoQuery(
            downloadToken: true,
            intercom: true,
            platform: "ios"
        )

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
        api.getConfig { result in
            switch result {
            case .success(let value):
                config = value
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

    func fetchUserSuccess(account: PutioAccount, config: PutioConfig) {
        guard let realm = PutioRealm.open(context: "fetchUserSuccess") else {
            InternalFailurePresenter.log("Unable to open Realm during fetchUserSuccess")
            return presentLoginScreen()
        }

        guard let persistedUser = User(account: account), let persistedConfig = UserConfig(config: config) else {
            InternalFailurePresenter.log("Unable to construct persisted user/config models")
            return presentLoginScreen()
        }

        let didPersist = PutioRealm.replaceUserSession(
            realm,
            user: persistedUser,
            config: persistedConfig,
            context: "fetchUserSuccess.persist"
        )

        guard didPersist else {
            return presentLoginScreen()
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

    func fetchUserFailure(error: any PutioErrorLocalizableInput) {
        guard let realm = PutioRealm.open(context: "fetchUserFailure") else {
            return presentLoginScreen()
        }
        let user = realm.objects(User.self).first

        switch error.localizerType {
        case .decodingError, .unknownError, .networkError:
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
        let storyboard = UIStoryboard(name: "Login", bundle: nil)
        guard let loginViewController = storyboard.instantiateViewController(withIdentifier: "LoginVC", as: UIViewController.self) else {
            InternalFailurePresenter.log("Unable to instantiate LoginVC")
            return
        }
        window?.rootViewController = loginViewController
        window?.makeKeyAndVisible()
    }

    func presentMainScreen() {
        ChromecastManager.sharedInstance.setup()
        applyWindowAppearance()
        window?.rootViewController = RootContainerViewController()
        window?.makeKeyAndVisible()
    }
}
