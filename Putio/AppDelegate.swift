import UIKit
import UserNotifications
import Intercom
import RealmSwift
import PutioSDK
import GoogleCast

enum DownloadQueueLifecyclePolicy {
    static func shouldRestoreBackgroundSession(identifier: String, isMockAPIEnabled: Bool) -> Bool {
        BackgroundDownloadSessionEvents.isSupported(identifier) && !isMockAPIEnabled
    }

    static func shouldStartQueue(requested: Bool, isMockAPIEnabled: Bool) -> Bool {
        requested && !isMockAPIEnabled
    }

    static func accountDidChange(previousID: Int?, currentID: Int) -> Bool {
        previousID.map { $0 != currentID } ?? false
    }

    static func cachedLaunchKnowsAccount(tokenOwnerID: Int?, cachedUserID: Int?) -> Bool {
        tokenOwnerID != nil && tokenOwnerID == cachedUserID
    }

    static func clearsDownloadsOnSessionLoad(previousID: Int?, currentID: Int, downloadsHaveNoAccount: Bool) -> Bool {
        downloadsHaveNoAccount || accountDidChange(previousID: previousID, currentID: currentID)
    }
}

/// 2.58.0 leaves background downloads, Sentry 7 envelopes, and cached
/// responses whose URLs carry the OAuth token, none of which this app reads.
/// The first launch after the upgrade drops them.
enum LegacyInstallCleanup {
    static let didRunKey = "LegacyInstallCleanup.didRun"

    static func runOnce(defaults: UserDefaults = .standard, urlCache: URLCache = .shared) {
        guard !defaults.bool(forKey: didRunKey) else { return }
        urlCache.removeAllCachedResponses()
        let cacheDeleted = SentryTelemetry.deleteLegacyCache()
        // Marked done only once the Sentry cache is gone and every session answers, so
        // a background launch that fails or is suspended first retries.
        BackgroundDownloadSessionEvents.cancelShipped258Sessions {
            if cacheDeleted { defaults.set(true, forKey: didRunKey) }
        }
    }
}

enum LoginFailure: Equatable {
    case sessionExpired
    case sessionLoad
}

enum SessionLoadFallback: Equatable {
    case cachedSession
    case login(LoginFailure)

    static func after(_ error: PutioSDKErrorType, keepsSession: Bool) -> SessionLoadFallback {
        if error.isUnauthorized {
            return .login(.sessionExpired)
        }

        return keepsSession ? .cachedSession : .login(.sessionLoad)
    }

    static func keepsSession(cachedUserID: Int?, tokenOwnerID: Int?, signedOutAccountID: Int?, restoresShipped258Session: Bool) -> Bool {
        if restoresShipped258Session {
            return true
        }
        guard let cachedUserID else { return false }
        guard let tokenOwnerID else { return cachedUserID != signedOutAccountID }
        return tokenOwnerID == cachedUserID
    }
}

@UIApplicationMain
class AppDelegate: UIResponder, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    var window: UIWindow?
    var supportMessenger: SupportMessenger? = IntercomMessenger.ifEnabled
    var keychain = PutioKeychain.sharedInstance
    private var pendingURLs: [URL] = []
    // A session restored at launch, not a fresh sign-in, which may be another
    // account than the one that left 2.58.0's downloads.
    private var isRestoredSession = false
    static var isRunningUnitTests: Bool {
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
        PerfSignpost.beginLaunchToFiles()

        if Self.isRunningUnitTests {
            return true
        }

        configureSDKs()
        // Before launch returns, so a tap that cold-launches the app reaches didReceive.
        UNUserNotificationCenter.current().delegate = self
        prepareForE2ETestsIfNeeded()
        if !PutioE2EEnvironment.isMockAPIEnabled {
            LegacyInstallCleanup.runOnce()
            DownloadQueueController.sharedInstance.restoreBackgroundSessions()
        }
        configureUI()
        return true
    }

    func configureSDKs() {
        let realmFailure = PutioRealm.setup(isProtectedDataAvailable: UIApplication.shared.isProtectedDataAvailable)

        SentryTelemetry.start()
        // Not from setup(): Sentry drops events until start() has applied the
        // stored diagnostics answer.
        if let realmFailure {
            SentryTelemetry.capture(.realmOpen, error: realmFailure)
        }

        if INTERCOM_ENABLED {
            Intercom.setApiKey(INTERCOM_API_KEY, forAppId: INTERCOM_APP_ID)
        }
    }

    func configureUI() {
        BrandFont.registerIfAvailable()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(capContentSizeCategory),
            name: UIContentSizeCategory.didChangeNotification,
            object: nil
        )
        applyWindowAppearance()
        Stylize.UIKit(window: window)
        NetworkReachability.sharedInstance.setup()
        OfflineVideoPlaybackPositionSynchronizer.shared.startObservingReconnects()
        Utils.configureAVSession()
    }

    func connect(window: UIWindow) {
        self.window = window
        if PutioE2EEnvironment.isAnimationDisabled {
            UIView.setAnimationsEnabled(false)
            window.layer.speed = PutioE2EEnvironment.animationSpeed
        }
        if Self.isRunningUnitTests {
            window.rootViewController = UIViewController()
        }
        applyWindowAppearance()
        window.makeKeyAndVisible()
        if !Self.isRunningUnitTests {
            // A scene needs an unlocked device, so a setup the lock stopped
            // runs now, before the session is restored.
            if let realmFailure = PutioRealm.setupIfLocked(isProtectedDataAvailable: UIApplication.shared.isProtectedDataAvailable) {
                SentryTelemetry.capture(.realmOpen, error: realmFailure)
            }
            authenticate(token: e2eAccessToken, isRestoredSession: true)
        }
    }

    func prepareForE2ETestsIfNeeded() {
        #if DEBUG
        guard ProcessInfo.processInfo.environment["PUTIO_E2E_RESET_STATE"] == "1" else { return }

        keychain.clearToken()
        if let bundleIdentifier = Bundle.main.bundleIdentifier {
            UserDefaults.standard.removePersistentDomain(forName: bundleIdentifier)
        }
        if let realm = PutioRealm.open(context: "prepareForE2ETests") {
            let clearCommitted = PutioRealm.write(realm, context: "prepareForE2ETests.clearRealm") {
                realm.deleteAll()
            }
            // Only seed on a committed clear. Seeding over surviving rows gives
            // a list that is neither the fixture set nor the old state, and the
            // walk would capture it as though it were intended.
            if clearCommitted {
                PutioE2EDownloadFixtures.install(into: realm)
            }
        }
        // The reset leaves a token and no Realm user, as the first launch after
        // the update from 2.58.0 does once it has replaced that Realm.
        if ProcessInfo.processInfo.environment["PUTIO_E2E_UPGRADING_FROM_258"] == "1" {
            PutioRealm.setUpgradingFromShipped258(true)
        }
        #endif
    }

    func applyWindowAppearance() {
        window?.backgroundColor = UIColor.Putio.Surface.appBg
        window?.tintColor = UIColor.Putio.Yellow.textSecondary
        capContentSizeCategory()
    }

    /// Text stops growing two steps above the default; past that, rows, sheets
    /// and bars crowd out their own content. A window override, unlike
    /// `maximumContentSizeCategory`, reaches every view controller under it.
    @objc func capContentSizeCategory() {
        guard let window else { return }
        let capped = min(UIApplication.shared.preferredContentSizeCategory, Self.maximumContentSizeCategory)
        let previous = window.traitOverrides.contains(UITraitPreferredContentSizeCategory.self)
            ? window.traitOverrides.preferredContentSizeCategory
            : nil
        window.traitOverrides.preferredContentSizeCategory = capped
        if let previous, previous != capped {
            Stylize.refreshForTextSize(in: window)
        }
    }

    static let maximumContentSizeCategory = UIContentSizeCategory.extraExtraLarge

    func application(_ application: UIApplication, handleEventsForBackgroundURLSession identifier: String, completionHandler: @escaping () -> Void) {
        guard DownloadQueueLifecyclePolicy.shouldRestoreBackgroundSession(
            identifier: identifier,
            isMockAPIEnabled: PutioE2EEnvironment.isMockAPIEnabled
        ) else {
            completionHandler()
            return
        }
        BackgroundDownloadSessionEvents.register(identifier: identifier, completionHandler: completionHandler)
        DownloadQueueController.sharedInstance.restoreBackgroundSessions()
    }

    func openIncomingURL(_ url: URL) {
        ProductAnalytics.appSession.didOpenLink()
        // A cold-launch link arrives before asynchronous account loading finishes.
        guard window?.rootViewController is RootContainerViewController else {
            pendingURLs.append(url)
            return
        }
        _ = DeeplinkManager.sharedInstance.handleURL(url: url)
    }

    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        if INTERCOM_ENABLED {
            Intercom.setDeviceToken(deviceToken, completion: nil)
        }
    }

    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
        SentryTelemetry.capture(.pushRegistration, error: error)
    }

    // A delegate without this method hides every notification in the foreground.
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification, withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        guard notification.request.identifier == DOWNLOAD_LOCAL_NOTIFICATION_IDENTIFIER else {
            return completionHandler([])
        }
        completionHandler([.banner, .list, .sound])
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse, withCompletionHandler completionHandler: @escaping () -> Void) {
        let userInfo = response.notification.request.content.userInfo

        if INTERCOM_ENABLED, Intercom.isIntercomPushNotification(userInfo) {
            Intercom.handlePushNotification(userInfo)
        }

        completionHandler()
    }

    func authenticate(token: String? = nil, isRestoredSession: Bool = false) {
        self.isRestoredSession = isRestoredSession
        if !isRestoredSession {
            PutioRealm.endShipped258Session(realm: PutioRealm.open(context: "authenticate.endShipped258Session"))
        }
        guard let token = token ?? keychain.getToken(adoptsShipped258Token: PutioRealm.isUpgradingFromShipped258()) else {
            return presentLoginScreen()
        }

        if isRestoredSession {
            keychain.setToken(token)
        } else {
            keychain.signIn(token: token, cachedUserID: cachedUserID(context: "authenticate"))
        }
        api.setToken(token: token)
        fetchUser(token: token)
    }

    func fetchUser(token: String) {
        let signpost = PerfSignpost.begin(.fetchUser)
        let dispatchGroup = DispatchGroup()
        
        var account: PutioAccount?
        var accountError: PutioSDKError?
        
        var config: AppConfig?
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
                // Not behind /config: an opt-out applies as soon as the account
                // answers, and a /config failure still opens the cached main screen.
                SentryTelemetry.update(diagnosticsEnabled: accountData.settings.diagnosticsEnabled)
                ProductAnalytics.update(accountID: accountData.id, productAnalyticsEnabled: accountData.settings.productAnalyticsEnabled)
                AccountNoticeStore.shared.update(with: accountData)
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
            guard api.mediaToken == token else {
                PerfSignpost.end(signpost, outcome: .cancelled)
                return
            }
            PerfSignpost.end(signpost, outcome: (accountError ?? configError) == nil ? .succeeded : .failed)

            if let error = accountError ?? configError {
                let failures: [(PutioSDKError?, SentryTelemetry.Endpoint)] = [(accountError, .accountInfo), (configError, .config)]
                for case let (failure?, endpoint) in failures {
                    switch failure.type {
                    case .decodingError, .unknownError:
                        SentryTelemetry.capture(.sessionLoad, error: failure, reason: .init(failure), endpoint: endpoint)
                    default:
                        break
                    }
                }
                if let account {
                    self.confirmTokenOwner(accountID: account.id, token: token)
                }
                return self.fetchUserFailure(error: error)
            }
            
            if let account = account, let config = config {
                return self.fetchUserSuccess(account: account, config: config, token: token)
            }
        }
    }

    func fetchUserSuccess(account: PutioAccount, config: AppConfig, token: String) {
        guard let realm = PutioRealm.open(context: "fetchUserSuccess") else {
            InternalFailurePresenter.log("Unable to open Realm during fetchUserSuccess", context: "AppDelegate.fetchUserSuccess.realm")
            return presentLoginScreen(after: .sessionLoad, reason: "Realm unavailable in fetchUserSuccess")
        }

        guard let persistedUser = User(account: account), let persistedConfig = UserConfig(config: config) else {
            InternalFailurePresenter.log("Unable to construct persisted user/config models", context: "AppDelegate.fetchUserSuccess.models")
            return presentLoginScreen(after: .sessionLoad, reason: "user/config models could not be constructed")
        }

        let previousAccountID = realm.objects(User.self).first?.id

        let didPersist = PutioRealm.replaceUserSession(
            realm,
            user: persistedUser,
            config: persistedConfig,
            context: "fetchUserSuccess.persist"
        )

        guard didPersist else {
            return presentLoginScreen(after: .sessionLoad, reason: "user session could not be persisted")
        }

        if DownloadQueueLifecyclePolicy.clearsDownloadsOnSessionLoad(
            previousID: previousAccountID,
            currentID: account.id,
            downloadsHaveNoAccount: PutioRealm.downloadsHaveNoAccount()
        ) {
            DownloadQueueController.sharedInstance.clearDownloadsForAccountChange {
                PutioRealm.setDownloadsHaveNoAccount(false)
            }
        }

        Utils.authorizeNotifications(application: UIApplication.shared)

        SupportIdentity.signIn(accountID: account.id, userHash: account.hash, messenger: supportMessenger)
        keychain.setTokenOwner(accountID: account.id, for: token)
        keychain.clearSignedOutAccount()

        self.presentMainScreen(asksProductAnalytics: ProductAnalyticsChoice.shouldAsk(
            productAnalyticsEnabled: account.settings.productAnalyticsEnabled,
            promptAnswered: config.productAnalyticsPromptAnswered,
            opensLaunchLinks: !pendingURLs.isEmpty
        ))
    }

    func fetchUserFailure(error: any PutioErrorLocalizableInput) {
        guard let realm = PutioRealm.open(context: "fetchUserFailure") else {
            return presentLoginScreen(after: .sessionLoad, reason: "Realm unavailable in fetchUserFailure")
        }
        // The upgrade from 2.58.0 deletes its Realm user, so until the next
        // sign-in the session restored at launch stands in for it.
        let cachedUserID = realm.objects(User.self).first?.id
        let tokenOwnerID = keychain.tokenOwnerID
        let keepsSession = SessionLoadFallback.keepsSession(
            cachedUserID: cachedUserID,
            tokenOwnerID: tokenOwnerID,
            signedOutAccountID: keychain.signedOutAccountID,
            restoresShipped258Session: isRestoredSession && PutioRealm.isUpgradingFromShipped258()
        )
        let startsDownloadQueue = DownloadQueueLifecyclePolicy.cachedLaunchKnowsAccount(
            tokenOwnerID: tokenOwnerID,
            cachedUserID: cachedUserID
        )

        switch SessionLoadFallback.after(error.localizerType, keepsSession: keepsSession) {
        case .cachedSession:
            return presentMainScreen(startDownloadQueue: startsDownloadQueue)
        case .login(let failure):
            if failure == .sessionExpired {
                endSession()
            }
            return presentLoginScreen(after: failure, reason: "account fetch failed: \(error.localizerType)")
        }
    }

    // Signed-in only: a cold launch reaches the foreground before fetchUser
    // answers, and that answer already carries the status. Every sign-in
    // builds a new root, so an answer that lands after sign-out, or after
    // signing in to another account, is dropped. Failures other than a
    // rejected token keep the last notice, so going offline does not hide it.
    func refreshAccountStatus() {
        guard let signedInRoot = window?.rootViewController as? RootContainerViewController else { return }
        let savesBeforeRead = SettingsViewModel.confirmedSaves
        SettingsViewModel.accountRefreshes += 1
        let refresh = SettingsViewModel.accountRefreshes
        ProductAnalytics.awaitAnswer()

        api.getAccountInfo { [weak signedInRoot] result in
            guard let signedInRoot, self.window?.rootViewController === signedInRoot, refresh == SettingsViewModel.accountRefreshes else { return }

            switch result {
            case .success(let account):
                // An answer changed on another device lands here.
                if savesBeforeRead == SettingsViewModel.confirmedSaves {
                    SentryTelemetry.update(diagnosticsEnabled: account.settings.diagnosticsEnabled)
                    ProductAnalytics.update(accountID: account.id, productAnalyticsEnabled: account.settings.productAnalyticsEnabled)
                } else {
                    ProductAnalytics.keepAnswer()
                }
                AccountNoticeStore.shared.update(with: account)
            case .failure(let error):
                if error.type.isUnauthorized {
                    AccountNoticeStore.shared.clear()
                    ProductAnalytics.update(accountID: nil, productAnalyticsEnabled: nil)
                } else {
                    ProductAnalytics.keepAnswer()
                }
            }
        }
    }

    func logout() {
        endSession()
        presentLoginScreen()
    }

    private func endSession() {
        DownloadQueueController.sharedInstance.pause()
        OfflineVideoPlaybackPositionStore.shared.clearAllUpdates()
        keychain.signOut(cachedUserID: cachedUserID(context: "endSession"))
        api.clearToken()
        VideoPlaybackPositionStore.shared.clearAllPositions()
        SentryTelemetry.update(diagnosticsEnabled: nil)
    }

    private func confirmTokenOwner(accountID: Int, token: String) {
        guard let realm = PutioRealm.open(context: "confirmTokenOwner") else { return }
        if DownloadQueueLifecyclePolicy.accountDidChange(previousID: realm.objects(User.self).first?.id, currentID: accountID) {
            PutioRealm.write(realm, context: "confirmTokenOwner.dropCachedAccount") {
                realm.delete(realm.objects(User.self))
                realm.delete(realm.objects(UserConfig.self))
            }
            DownloadQueueController.sharedInstance.clearDownloadsForAccountChange()
        }
        keychain.setTokenOwner(accountID: accountID, for: token)
    }

    private func cachedUserID(context: PutioRealm.Context) -> Int? {
        PutioRealm.open(context: context)?.objects(User.self).first?.id
    }

    // Falling back to login is normal for a signed-out launch, but when the e2e
    // suite injected a token it means the mocked sign-in path broke. Say so
    // instead of leaving a bare login screen for the test to interpret.
    private func presentLoginScreen(after failure: LoginFailure, reason: String) {
        if e2eAccessToken != nil {
            InternalFailurePresenter.logLocally("E2E sign-in bootstrap fell back to the login screen: \(reason)")
        }

        presentLoginScreen(failure: failure)
    }

    func retrySessionLoad() {
        authenticate(isRestoredSession: isRestoredSession)
    }

    /// Every way out of the signed-in app ends here: logout, a rejected token,
    /// a launch with no session, or a failed bootstrap.
    func presentLoginScreen(failure: LoginFailure? = nil) {
        DownloadQueueController.sharedInstance.pause()
        AccountNoticeStore.shared.clear()
        ProductAnalytics.signOut(after: failure)
        SupportIdentity.signOut(after: failure, messenger: supportMessenger)
        applyWindowAppearance()
        let storyboard = UIStoryboard(name: "Login", bundle: nil)
        guard let loginViewController = storyboard.instantiateViewController(withIdentifier: "LoginVC", as: LoginViewController.self) else {
            InternalFailurePresenter.log("Unable to instantiate LoginVC", context: "AppDelegate.presentLoginScreen.loginVC")
            return
        }
        loginViewController.failure = failure
        window?.rootViewController = loginViewController
        window?.makeKeyAndVisible()
    }

    /// Only a fresh account and config can ask about product analytics; the
    /// cached shell after a failed load never does.
    func presentMainScreen(startDownloadQueue: Bool = true, asksProductAnalytics: Bool = false) {
        if DownloadQueueLifecyclePolicy.shouldStartQueue(
            requested: startDownloadQueue,
            isMockAPIEnabled: PutioE2EEnvironment.isMockAPIEnabled
        ) {
            DownloadQueueController.sharedInstance.start()
        }

        OfflineVideoPlaybackPositionSynchronizer.shared.syncPendingUpdates()
        ChromecastManager.sharedInstance.setup()
        applyWindowAppearance()
        let rootViewController = RootContainerViewController()
        rootViewController.asksProductAnalytics = asksProductAnalytics
        window?.rootViewController = rootViewController
        window?.makeKeyAndVisible()
        #if DEBUG
        PutioE2EPerfProbe.installIfEnabled(in: window)
        #endif
        // Until the next sign-in, the session restored at launch is the one
        // 2.58.0's downloads belong to. After one, recovering stays a Restore tap.
        if isRestoredSession, PutioRealm.isUpgradingFromShipped258() {
            PutioRealm.recoverDownloadsIfNeeded()
        }
        let urls = pendingURLs
        pendingURLs.removeAll()
        urls.forEach(openIncomingURL)
    }

}
