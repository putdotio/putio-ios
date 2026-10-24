import Foundation
import os
import PostHog
import RealmSwift
import UIKit

/// The app's only PostHog entry point. `scripts/verify-fast.sh` rejects
/// `import PostHog` anywhere else, so every event leaves through
/// `AnalyticsAllowlist`. It runs only in the App Store app, for a signed-in
/// account whose `product_analytics_enabled` is on.
enum ProductAnalytics {
    /// put.io's forward-only proxy to PostHog Cloud EU.
    static let host = "https://burrow.put.io"

    /// The App Store and TestFlight bundle. A development, verify, or e2e build
    /// would otherwise report into the production project.
    static let appStoreBundleIdentifier = "com.putio.tvOS"

    static let shared = ProductAnalyticsGate(environment: .live)

    /// The cached account's route, nil until its settings load: a fresh
    /// sign-in's cold launch has none yet.
    static let appSession = AppSessionAnalytics(capture: capture, route: {
        PutioRealm.open(context: "ProductAnalytics.route")?.objects(User.self).first?.settings?.routeName
    })

    /// `nil` is signed out; an unset answer is off.
    static func update(accountID: Int?, productAnalyticsEnabled: Bool?) {
        shared.update(accountID: accountID, productAnalyticsEnabled: productAnalyticsEnabled)
    }

    /// put.io saved the switch or the prompt's answer for the signed-in account.
    static func settingDidSave(enabled: Bool) {
        shared.settingDidSave(enabled: enabled)
    }

    /// The foreground refresh is reading the account again.
    static func awaitAnswer() {
        shared.awaitAnswer()
    }

    /// The refresh ended without an answer, so the last one stands.
    static func keepAnswer() {
        shared.keepAnswer()
    }

    static func capture(_ event: AnalyticsEvent) {
        shared.capture(event)
    }

    /// For an event that waited on put.io, from `AccountNoticeStore.shared.session`.
    static func capture(_ event: AnalyticsEvent, startedIn session: Int) {
        shared.capture(event, startedIn: session)
    }

    static func captureInCurrentSession() -> (AnalyticsEvent) -> Void {
        shared.captureInCurrentSession()
    }

    /// PostHog's public project token, which only names the project. Anything
    /// else, including an unexpanded `$(PUTIO_POSTHOG_TOKEN)`, is nil.
    static func projectToken(_ value: String) -> String? {
        value.range(of: "^phc_[A-Za-z0-9]{20,64}$", options: .regularExpression) == nil ? nil : value
    }

    static func isEligible(bundleIdentifier: String?, isMockAPIEnabled: Bool, isRunningUnitTests: Bool) -> Bool {
        bundleIdentifier == appStoreBundleIdentifier && !isMockAPIEnabled && !isRunningUnitTests
    }
}

/// Starts PostHog only once the gate opens, so nothing, not even its device
/// id, exists on the device before then. Never calls `reset()`, which sends a
/// flags request and keeps the device id: stopping closes the SDK and deletes
/// its storage instead.
final class ProductAnalyticsGate {
    struct Environment {
        var token: String?
        var isEligible: Bool
        var storageDirectory: URL
        var urlSessionConfiguration: URLSessionConfiguration?
        var compression: PostHogCompression = .gzip
        var now: () -> Date = Date.init

        static var live: Environment {
            Environment(
                token: POSTHOG_PROJECT_TOKEN,
                isEligible: ProductAnalytics.isEligible(
                    bundleIdentifier: Bundle.main.bundleIdentifier,
                    isMockAPIEnabled: PutioE2EEnvironment.isMockAPIEnabled,
                    isRunningUnitTests: AppDelegate.isRunningUnitTests
                ),
                storageDirectory: URL.applicationSupportDirectory.appending(path: Bundle.main.bundleIdentifier ?? "")
            )
        }
    }

    private struct Running {
        let sdk: PostHogSDK
        let accountID: Int
        let commonProperties: [String: String]
        /// Without an open since the start, a background would time a session
        /// that began before consent.
        var hasSentOpen = false
    }

    /// Events from before the first answer of this launch, such as the cold
    /// launch's `app_opened`, or of a foreground. Dropped if that answer is off.
    private static let heldLimit = 16

    private let environment: Environment
    private let lock = NSLock()
    private var accountID: Int?
    private var enabled: Bool?
    private var hasAnswer = false
    private var held: [(event: AnalyticsEvent, at: Date)] = []
    private var running: Running?

    /// Read by `beforeSend` on any SDK thread, so it has its own lock.
    private let capturing = OSAllocatedUnfairLock(initialState: false)

    init(environment: Environment) {
        self.environment = environment
    }

    var isCapturing: Bool {
        capturing.withLock { $0 }
    }

    var runningSDK: PostHogSDK? {
        lock.withLock { running?.sdk }
    }

    func update(accountID: Int?, productAnalyticsEnabled: Bool?) {
        lock.withLock {
            self.accountID = accountID
            enabled = productAnalyticsEnabled
            hasAnswer = true
            apply()
        }
    }

    func settingDidSave(enabled: Bool) {
        lock.withLock {
            self.enabled = enabled
            hasAnswer = true
            apply()
        }
    }

    /// Held until the refresh answers, so an opt-out made on another device
    /// while the app was away applies before the foreground's first event.
    func awaitAnswer() {
        lock.withLock { hasAnswer = false }
    }

    func keepAnswer() {
        lock.withLock {
            hasAnswer = true
            sendHeld()
        }
    }

    func capture(_ event: AnalyticsEvent) {
        lock.withLock {
            guard environment.token != nil, environment.isEligible else { return }
            let at = environment.now()
            if hasAnswer, running != nil {
                send(event, at: at)
            } else if !hasAnswer {
                held.append((event, at))
                if held.count > Self.heldLimit { held.removeFirst() }
            }
        }
    }

    /// Signing out moves the session on, so a save that lands after it was
    /// the earlier account's and sends nothing.
    func capture(_ event: AnalyticsEvent, startedIn session: Int) {
        guard session == AccountNoticeStore.shared.session else { return }
        capture(event)
    }

    /// Bound to the session it is made in, on the main thread. Its events can
    /// come from any thread, so each moves to the main thread, where the
    /// session is read, keeping the order they came in.
    func captureInCurrentSession() -> (AnalyticsEvent) -> Void {
        let session = AccountNoticeStore.shared.session
        return { [self] event in
            DispatchQueue.main.async { self.capture(event, startedIn: session) }
        }
    }

    /// Storage the SDK keeps under its project token.
    func storageDirectory(token: String) -> URL {
        environment.storageDirectory.appending(path: token)
    }

    private func apply() {
        guard let token = environment.token, environment.isEligible else { return }
        let target = enabled == true ? accountID : nil
        if running == nil || running?.accountID != target {
            // A survivor could hand the next start the earlier identity or queue.
            guard stop(token: token), let target else {
                held.removeAll()
                return
            }
            start(token: token, accountID: target)
        }
        sendHeld()
    }

    private func sendHeld() {
        let pending = held
        held.removeAll()
        pending.forEach { send($0.event, at: $0.at) }
    }

    /// `apply()` stops first, so every start is a fresh install, even after a
    /// killed launch: the bootstrap seeds the account id, and the SDK never
    /// reconciles an older identity through `identify()`.
    private func start(token: String, accountID: Int) {
        capturing.withLock { $0 = true }
        let config = Self.config(
            token: token,
            accountID: accountID,
            urlSessionConfiguration: environment.urlSessionConfiguration,
            compression: environment.compression,
            beforeSend: { [capturing] event in
                guard capturing.withLock({ $0 }),
                      let kept = AnalyticsAllowlist.allowedProperties(event: event.event, properties: event.properties)
                else { return nil }
                event.properties = kept
                return event
            }
        )
        running = Running(sdk: PostHogSDK.with(config), accountID: accountID, commonProperties: Self.commonProperties())
    }

    /// `close()` sends what is queued, so the queue goes first; close may
    /// write again, so the folder goes after it too. False while the folder
    /// survives; the next update tries again.
    private func stop(token: String) -> Bool {
        capturing.withLock { $0 = false }
        deleteStorage(token: token)
        running?.sdk.close()
        running = nil
        // The last-seen app version the SDK writes when it starts.
        UserDefaults.standard.removeObject(forKey: "PHGVersionKey")
        UserDefaults.standard.removeObject(forKey: "PHGBuildKeyV2")
        return deleteStorage(token: token)
    }

    @discardableResult
    private func deleteStorage(token: String) -> Bool {
        do {
            try FileManager.default.removeItem(at: storageDirectory(token: token))
        } catch let error as CocoaError where error.code == .fileNoSuchFile {
            // Already gone; every update while off lands here.
        } catch {
            InternalFailurePresenter.log("ProductAnalytics: storage not deleted: \(error.localizedDescription)")
            return false
        }
        return true
    }

    /// A held event keeps the time it happened, not the time the answer came.
    private func send(_ event: AnalyticsEvent, at timestamp: Date) {
        guard var running else { return }
        switch event {
        case .appOpened: running.hasSentOpen = true
        case .appBackgrounded where !running.hasSentOpen: return
        default: break
        }
        self.running = running
        running.sdk.capture(event.name, properties: running.commonProperties.merging(event.properties) { $1 }, timestamp: timestamp)
    }

    static func config(
        token: String,
        accountID: Int,
        urlSessionConfiguration: URLSessionConfiguration? = nil,
        compression: PostHogCompression = .gzip,
        beforeSend: @escaping BeforeSendBlock
    ) -> PostHogConfig {
        let config = PostHogConfig(projectToken: token, host: ProductAnalytics.host)
        // Identified before the first event, with no $identify and no flags request.
        config.bootstrap = PostHogBootstrapConfig(distinctId: String(accountID), isIdentifiedId: true)
        config.personProfiles = .identifiedOnly
        config.setDefaultPersonProperties = false
        config.disableGeoIp = true
        config.preloadFeatureFlags = false
        config.sendFeatureFlagEvent = false
        config.captureApplicationLifecycleEvents = false
        config.captureScreenViews = false
        config.captureElementInteractions = false
        config.captureSwiftUIElementInteractions = false
        config.rageClickConfig.enabled = false
        config.capturePushNotificationSubscriptions = false
        config.capturePushNotificationOpened = false
        config.sessionReplay = false
        config.surveys = false
        config.errorTrackingConfig.autoCapture = false
        // Also keeps every swizzle-based integration from installing.
        config.enableSwizzling = false
        // A session has few events; each goes when captured instead of waiting for 20.
        config.flushAt = 1
        config.urlSessionConfiguration = urlSessionConfiguration
        config.compression = compression
        config.setBeforeSend(beforeSend)
        #if DEBUG
        config.debug = true
        #endif
        return config
    }

    /// Read once per start, on the main thread like every gate input.
    static func commonProperties(bundle: Bundle = .main, device: UIDevice = .current, processInfo: ProcessInfo = .processInfo) -> [String: String] {
        let deviceClass: String
        if processInfo.isiOSAppOnMac {
            deviceClass = "desktop"
        } else {
            switch device.userInterfaceIdiom {
            case .phone: deviceClass = "phone"
            case .pad: deviceClass = "tablet"
            default: deviceClass = "unknown"
            }
        }
        return [
            "app": "ios",
            "app_version": "\(bundle.versionNumber)+\(bundle.buildNumber)",
            "runtime": "ios",
            "runtime_version": device.systemVersion,
            "device_class": deviceClass,
            "auth_state": "signed_in",
            // Only the App Store build sends, and it talks to production put.io.
            "environment": "production",
            // TestFlight names its receipt `sandboxReceipt`; the App Store `receipt`.
            "release_channel": bundle.appStoreReceiptURL?.lastPathComponent == "sandboxReceipt" ? "beta" : "stable"
        ]
    }
}
