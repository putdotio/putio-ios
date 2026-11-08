import Foundation
import os
import PutioSDK
@_spi(Private) import Sentry

/// The app's only Sentry entry point. `scripts/verify-fast.sh` rejects
/// `import Sentry` anywhere else, so only the SDK fills the contexts and user
/// that `allowlisted` keeps. It runs only while the account allows diagnostics.
enum SentryTelemetry {
    enum Failure: String {
        case diagnosticsCheck = "diagnostics_check"
        case downloadedAssetDeletion = "downloaded_asset_deletion"
        case downloadsObservation = "downloads_observation"
        case internalFailure = "internal_failure"
        case pushRegistration = "push_registration"
        case realmOpen = "realm_open"
        case realmWrite = "realm_write"
        case sessionLoad = "session_load"
        case supportLogin = "support_login"
        case unplayableOfflineDownload = "unplayable_offline_download"
        case unplayableOfflineVideo = "unplayable_offline_video"
    }

    enum Reason: String {
        case decoding, network, unknown
        case http4xx = "http_4xx"
        case http5xx = "http_5xx"

        init(_ error: PutioSDKError) {
            switch error.type {
            case .decodingError: self = .decoding
            case .networkError: self = .network
            case .httpError(let status, _) where (400..<500).contains(status): self = .http4xx
            case .httpError(let status, _) where (500..<600).contains(status): self = .http5xx
            case .httpError, .unknownError: self = .unknown
            }
        }
    }

    enum Endpoint: String {
        case accountInfo = "account_info"
        case config
    }

    enum CrashReason: String {
        case realmIncorrectThread = "realm_incorrect_thread"
        case realmObjectInvalidated = "realm_object_invalidated"
        case realmWriteOutsideTransaction = "realm_write_outside_transaction"
        case tableRowOutOfBounds = "table_row_out_of_bounds"
        case other

        private static let exceptionTypes: Set<String> = ["RLMException", "NSRangeException", "NSInternalInconsistencyException"]

        private static let patterns: [([String], CrashReason)] = [
            (["incorrect thread"], .realmIncorrectThread),
            (["outside of a write transaction"], .realmWriteOutsideTransaction),
            (["call beginWriteTransaction"], .realmWriteOutsideTransaction),
            (["deleted or invalidated"], .realmObjectInvalidated),
            (["invalidated or deleted"], .realmObjectInvalidated),
            (["index", "out of bounds"], .tableRowOutOfBounds),
            (["index", "beyond bounds"], .tableRowOutOfBounds),
            (["index", "when max is"], .tableRowOutOfBounds),
            (["which only contains"], .tableRowOutOfBounds),
            (["invalid number of rows"], .tableRowOutOfBounds)
        ]

        init?(_ exception: Exception) {
            guard let type = exception.type, Self.exceptionTypes.contains(type),
                  exception.mechanism?.handled?.boolValue == false
            else { return nil }
            let reason = exception.value ?? ""
            self = Self.patterns.first { needles, _ in
                needles.allSatisfy { reason.range(of: $0, options: .caseInsensitive) != nil }
            }?.1 ?? .other
        }
    }

    enum Interval: String, CaseIterable {
        case fetchUser = "FetchUser"
        case filesFetch = "FilesFetch"
        case playbackStart = "PlaybackStart"

        var operation: String {
            switch self {
            case .fetchUser: return "putio.fetch_user"
            case .filesFetch: return "putio.files_fetch"
            case .playbackStart: return "putio.playback_start"
            }
        }
    }

    enum Outcome {
        case succeeded, failed, cancelled
    }

    enum Action: CaseIterable {
        case tabSelected(MainTabBarController.Tab)

        static var allCases: [Action] { MainTabBarController.Tab.allCases.map(Action.tabSelected) }

        fileprivate var category: String {
            switch self {
            case .tabSelected: return "putio.tab"
            }
        }

        fileprivate var message: String {
            switch self {
            case .tabSelected: return "Selected tab"
            }
        }

        fileprivate var data: [String: String] {
            switch self {
            case .tabSelected(.files): return ["tab": "files"]
            case .tabSelected(.history): return ["tab": "history"]
            case .tabSelected(.downloads): return ["tab": "downloads"]
            case .tabSelected(.account): return ["tab": "settings"]
            }
        }

        fileprivate func breadcrumb(at timestamp: Date?) -> Breadcrumb {
            let sent = Breadcrumb(level: .info, category: category)
            sent.type = "user"
            sent.message = message
            sent.timestamp = timestamp
            for (key, value) in data { sent.setData(value: value, key: key) }
            return sent
        }
    }

    struct Timing {
        fileprivate let span: Sentry.Span?
    }

    private static let tracesSampleRate = 0.1

    private static func isContext(_ value: String) -> Bool {
        (1...80).contains(value.count) && value.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "." || $0 == "_") }
    }

    struct PlaybackFailure {
        static let category = "playback"

        enum Signal: String, CaseIterable {
            case itemFailed = "item_failed"
            case failedToPlayToEnd = "failed_to_play_to_end"
            case castLoadFailed = "cast_load_failed"
        }

        enum Tag: String {
            case signal = "playback_signal"
            case player
            case streamMethod = "stream_method"
            case media
            case errorDomain = "error_domain"
            case errorCode = "error_code"
            case underlyingDomain = "underlying_domain"
            case underlyingCode = "underlying_code"

            func allows(_ value: String) -> Bool {
                switch self {
                case .signal: return Signal(rawValue: value) != nil
                case .player: return AnalyticsEvent.Player(rawValue: value) != nil
                case .streamMethod: return AnalyticsEvent.StreamMethod(rawValue: value) != nil
                case .media: return AnalyticsEvent.Media(rawValue: value) != nil
                case .errorDomain, .underlyingDomain: return ErrorDomain(rawValue: value) != nil
                case .errorCode, .underlyingCode: return Int(value).map(String.init) == value
                }
            }
        }

        let signal: Signal
        let playback: AnalyticsEvent.Playback
    }

    enum ErrorDomain: String, CaseIterable {
        case url = "NSURLErrorDomain"
        case avFoundation = "AVFoundationErrorDomain"
        case coreMedia = "CoreMediaErrorDomain"
        case osStatus = "NSOSStatusErrorDomain"
        case posix = "NSPOSIXErrorDomain"
        case cocoa = "NSCocoaErrorDomain"
        case googleCast = "com.google.cast.GCKError"
        case missing = "none"
        case other

        init(_ error: NSError?) {
            guard let error else {
                self = .missing
                return
            }
            self = Self(rawValue: error.domain) ?? .other
        }
    }

    /// put.io's tunnel to Sentry ingest. Some networks reset connections to
    /// Sentry's own host, and the tunnel forwards only allowlisted project ids.
    private static let relayHost = "relay.put.io"

    private static let capturing = OSAllocatedUnfairLock(initialState: false)

    /// Also read by the SDK's callbacks, so a report racing a switch-off is dropped.
    static var isCapturing: Bool {
        get { capturing.withLock { $0 } }
        set { capturing.withLock { $0 = newValue } }
    }

    static let cacheDirectory = URL.cachesDirectory.appending(path: "io.put.diagnostics")

    /// Deletes where 2.58.0's Sentry 7.9.0 kept envelopes and crash reports,
    /// unredacted, and its installation id. Sentry 9 keeps its own id under
    /// `cacheDirectory`. False when any of them is still there.
    @discardableResult
    static func deleteLegacyCache(in cachesDirectory: URL = .cachesDirectory) -> Bool {
        var deleted = true
        for name in ["io.sentry", "SentryCrash", "INSTALLATION"] {
            do {
                try FileManager.default.removeItem(at: cachesDirectory.appending(path: name))
            } catch let error as CocoaError where error.code == .fileNoSuchFile {
                // Nothing to delete on an install that never ran 2.58.0.
            } catch {
                deleted = false
                InternalFailurePresenter.logLocally("SentryTelemetry: legacy cache not deleted: \(error.localizedDescription)")
            }
        }
        return deleted
    }

    static func transportConfiguration() -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [SentryTransportGate.self] + (configuration.protocolClasses ?? [])
        return configuration
    }

    private static let transportSession = URLSession(configuration: transportConfiguration())

    /// The account's last known `diagnostics_enabled`, kept so a cold launch
    /// honours an opt-out before the account loads. Missing, as when signed out,
    /// is on.
    private static let consentKey = "io.put.diagnostics-enabled"

    private static let consentedSinceKey = "io.put.diagnostics-enabled-since"

    private static let consentedSince = OSAllocatedUnfairLock<Date?>(initialState: nil)

    static func lastKnownDiagnosticsEnabled(defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: consentKey) as? Bool ?? true
    }

    static func start(dsn: String? = SENTRY_DSN, defaults: UserDefaults = .standard) {
        apply(dsn: dsn, defaults: defaults)
    }

    /// Keeps the account's answer, even in a build without a DSN, and applies it.
    /// `nil` is signed out.
    static func update(diagnosticsEnabled enabled: Bool?, dsn: String? = SENTRY_DSN, defaults: UserDefaults = .standard) {
        let wasEnabled = lastKnownDiagnosticsEnabled(defaults: defaults)
        defaults.set(enabled, forKey: consentKey)
        if !wasEnabled, lastKnownDiagnosticsEnabled(defaults: defaults) {
            defaults.set(Date(), forKey: consentedSinceKey)
        }
        apply(dsn: dsn, defaults: defaults)
    }

    /// `SentrySDK.close()` uploads cached envelopes and a final session without
    /// `beforeSend`. The transport gate cancels those uploads and the cache is
    /// deleted, so nothing recorded before a switch-off leaves later either.
    private static func apply(dsn: String?, defaults: UserDefaults) {
        let since = defaults.object(forKey: consentedSinceKey) as? Date
        consentedSince.withLock { $0 = since }
        guard let dsn else { return }
        let enabled = lastKnownDiagnosticsEnabled(defaults: defaults)
        isCapturing = enabled
        if enabled {
            if !SentrySDK.isEnabled {
                SentrySDK.start(options: options(dsn: dsn))
                currentAction.withLock { $0.action }.map(record)
            }
        } else {
            if SentrySDK.isEnabled { SentrySDK.close() }
            do {
                try FileManager.default.removeItem(at: cacheDirectory)
            } catch let error as CocoaError where error.code == .fileNoSuchFile {
                // Deleted by an earlier switch-off; every launch while off lands here.
            } catch {
                InternalFailurePresenter.logLocally("SentryTelemetry: cache not deleted: \(error.localizedDescription)")
            }
        }
    }

    static func options(dsn: String) -> Options {
        let options = Options()
        options.dsn = dsn
        options.enableAutoSessionTracking = true
        options.sessionTrackingIntervalMillis = 60000
        options.cacheDirectoryPath = cacheDirectory.path
        options.urlSession = transportSession
        options.maxBreadcrumbs = maxBreadcrumbs
        options.beforeBreadcrumb = trailed
        options.enableCaptureFailedRequests = false
        options.tracesSampleRate = NSNumber(value: tracesSampleRate)
        options.enableAutoPerformanceTracing = false
        options.enableUIViewControllerTracing = false
        options.enableUserInteractionTracing = false
        options.enableNetworkTracking = false
        options.enableFileIOTracing = false
        options.enableCoreDataTracing = false
        options.tracePropagationTargets = []
        options.enableMetricKit = true
        options.enableMetricKitRawPayload = false
        options.beforeSend = { event in
            guard isCapturing, !predatesConsent(event) else { return nil }
            return event.type == transactionType ? allowlistedTransaction(event) : allowlisted(event)
        }
        return options
    }

    /// Rewrites `https://<key>@<host>/<projectId>` to post through the relay.
    /// Anything else, including an unexpanded `$(PUTIO_SENTRY_DSN)`, is nil.
    static func relayDSN(_ dsn: String) -> String? {
        guard let components = URLComponents(string: dsn),
              components.scheme == "https",
              let key = components.user, !key.isEmpty,
              components.host?.isEmpty == false,
              let projectID = components.path.split(separator: "/").last,
              projectID.allSatisfy({ $0.isASCII && $0.isNumber })
        else { return nil }
        return "https://\(key)@\(relayHost)/\(projectID)"
    }

    static func capture(_ failure: Failure, error: Error? = nil, reason: Reason? = nil, endpoint: Endpoint? = nil, context: String? = nil) {
        SentrySDK.capture(error: error ?? NSError(domain: "io.put.telemetry", code: 0)) { scope in
            scope.setTag(value: failure.rawValue, key: "category")
            reason.map { scope.setTag(value: $0.rawValue, key: "reason") }
            endpoint.map { scope.setTag(value: $0.rawValue, key: "endpoint") }
            context.map { scope.setTag(value: $0, key: "context") }
        }
    }

    static func capture(_ failure: PlaybackFailure, error: Error?, startedIn session: Int) {
        guard session == AccountNoticeStore.shared.session else { return }
        let error = error as NSError?
        let underlying = error?.userInfo[NSUnderlyingErrorKey] as? NSError
        let domain = ErrorDomain(error)
        let code = error?.code ?? 0
        var tags: [PlaybackFailure.Tag: String] = [
            .signal: failure.signal.rawValue,
            .player: failure.playback.player.rawValue,
            .streamMethod: failure.playback.streamMethod.rawValue,
            .media: failure.playback.media.rawValue,
            .errorDomain: domain.rawValue,
            .errorCode: String(code)
        ]
        if let underlying {
            tags[.underlyingDomain] = ErrorDomain(underlying).rawValue
            tags[.underlyingCode] = String(underlying.code)
        }
        SentrySDK.capture(error: NSError(domain: domain.rawValue, code: code)) { scope in
            scope.setTag(value: PlaybackFailure.category, key: "category")
            for (tag, value) in tags { scope.setTag(value: value, key: tag.rawValue) }
        }
    }

    static func captureInCurrentSession() -> (PlaybackFailure, Error?) -> Void {
        let session = AccountNoticeStore.shared.session
        return { failure, error in
            DispatchQueue.main.async { capture(failure, error: error, startedIn: session) }
        }
    }

    private static let maxBreadcrumbs: UInt = 30

    private static let currentAction = OSAllocatedUnfairLock<(action: Action?, crumbsSince: UInt)>(initialState: (nil, 0))

    static func record(_ action: Action) {
        currentAction.withLock { $0 = (action, 0) }
        SentrySDK.addBreadcrumb(action.breadcrumb(at: Date()))
    }

    private static func trailed(_ breadcrumb: Breadcrumb) -> Breadcrumb? {
        guard isCapturing, let kept = allowlisted(breadcrumb) else { return nil }
        let evicted = currentAction.withLock { state -> Action? in
            if Action.allCases.contains(where: { $0.category == kept.category }) {
                state.crumbsSince = 0
                return nil
            }
            state.crumbsSince += 1
            guard state.crumbsSince >= maxBreadcrumbs, let action = state.action else { return nil }
            state.crumbsSince = 1
            return action
        }
        evicted.map { action in SentrySDK.configureScope { $0.addBreadcrumb(action.breadcrumb(at: Date())) } }
        return kept
    }

    static func begin(_ interval: Interval) -> Timing {
        guard isCapturing, SentrySDK.isEnabled else { return Timing(span: nil) }
        let span = SentrySDK.startTransaction(name: interval.rawValue, operation: interval.operation)
        for key in span.data.keys { span.removeData(key: key) }
        return Timing(span: span)
    }

    static func end(_ timing: Timing, outcome: Outcome) {
        switch outcome {
        case .succeeded: timing.span?.finish(status: .ok)
        case .failed: timing.span?.finish(status: .internalError)
        case .cancelled: timing.span?.finish(status: .cancelled)
        }
    }

    /// Lets a tester prove a TestFlight install's Sentry path on demand, beta or
    /// release lane. TestFlight names the receipt `sandboxReceipt`, the test
    /// Sentry uses for build type `test`; the App Store and the simulator name it
    /// `receipt`, whether or not it exists.
    @discardableResult
    static func captureDiagnosticsCheck(receiptURL: URL? = Bundle.main.appStoreReceiptURL) -> Bool {
        guard receiptURL?.lastPathComponent == "sandboxReceipt" else { return false }
        capture(.diagnosticsCheck)
        return true
    }

    private static func predatesConsent(_ event: Event) -> Bool {
        guard event.isMetricKitEvent(),
              let since = consentedSince.withLock({ $0 })
        else { return false }
        return (event.timestamp ?? .distantPast) < since
    }

    /// Copies listed fields into a new event, so unlisted ones, including any a
    /// Sentry upgrade adds to the event, stay on the device.
    static func allowlisted(_ event: Event) -> Event {
        let tags = event.tags ?? [:]
        let category = tags["category"].flatMap { Failure(rawValue: $0)?.rawValue ?? ($0 == PlaybackFailure.category ? $0 : nil) }
        var sentTags = tags.filter { key, value in PlaybackFailure.Tag(rawValue: key)?.allows(value) == true }
        sentTags["category"] = category
        sentTags["reason"] = tags["reason"].flatMap(Reason.init(rawValue:))?.rawValue
        sentTags["endpoint"] = tags["endpoint"].flatMap(Endpoint.init(rawValue:))?.rawValue
        sentTags["context"] = tags["context"].flatMap { isContext($0) ? $0 : nil }
        let sent = Event(level: event.level)
        sent.eventId = event.eventId
        sent.timestamp = event.timestamp
        sent.releaseName = event.releaseName
        sent.dist = event.dist
        sent.environment = event.environment
        sent.sdk = event.sdk
        sent.threads = event.threads
        sent.debugMeta = event.debugMeta
        sent.context = sentContext(event.context)
        sent.tags = sentTags.isEmpty ? nil : sentTags
        sent.user = event.user?.userId.map(Sentry.User.init(userId:))
        let breadcrumbs = event.breadcrumbs?.compactMap(allowlisted)
        sent.breadcrumbs = breadcrumbs?.isEmpty == false ? breadcrumbs : nil
        sent.exceptions = event.exceptions?.map { exception in
            let kept = Exception(value: category ?? CrashReason(exception)?.rawValue, type: exception.type)
            kept.threadId = exception.threadId
            kept.stacktrace = exception.stacktrace
            kept.mechanism = exception.mechanism.map { mechanism in
                let kept = Mechanism(type: mechanism.type)
                kept.handled = mechanism.handled
                kept.synthetic = mechanism.synthetic
                kept.meta = mechanism.meta
                return kept
            }
            return kept
        }
        return sent
    }

    private static let transactionType = "transaction"

    private static let sentContextKeys: Set<String> = ["app", "device", "os", "runtime"]

    private static let sentDeviceKeys: Set<String> = [
        "arch", "battery_level", "charging", "family", "free_memory", "ios_app_on_macos", "ios_app_on_visionos",
        "locale", "low_power_mode", "mac_catalyst_app", "memory_size", "model", "model_id", "orientation",
        "processor_count", "screen_height_pixels", "screen_width_pixels", "simulator", "thermal_state", "usable_memory"
    ]

    private static func sentContext(_ context: [String: [String: Any]]?) -> [String: [String: Any]]? {
        guard var sent = context?.filter({ sentContextKeys.contains($0.key) }) else { return nil }
        sent["device"] = sent["device"]?.filter { sentDeviceKeys.contains($0.key) }
        return sent
    }

    private static let screenKeys = ["screen", "parentViewController", "presentingViewController"]

    private static let appStates: Set<String> = ["foreground", "background", "active", "inactive"]

    private static let httpMethods: Set<String> = ["GET", "HEAD", "POST", "PUT", "PATCH", "DELETE"]

    static func allowlisted(_ breadcrumb: Breadcrumb) -> Breadcrumb? {
        let data = breadcrumb.data ?? [:]
        var kept: [String: Any] = [:]
        switch breadcrumb.category {
        case "ui.lifecycle":
            for key in screenKeys {
                if let name = data[key] as? String, isContext(name) { kept[key] = name }
            }
            guard kept["screen"] != nil else { return nil }
        case "app.lifecycle":
            guard let state = data["state"] as? String, appStates.contains(state) else { return nil }
            kept["state"] = state
        case "http":
            let host = ((data["url"] as? String).flatMap { URLComponents(string: $0)?.host } ?? data["host"] as? String)?.lowercased()
            guard let host, host == "put.io" || host.hasSuffix(".put.io")
            else { return nil }
            kept["host"] = host
            if let method = data["method"] as? String, httpMethods.contains(method) { kept["method"] = method }
            if let status = data["status_code"] as? NSNumber, (100..<600).contains(status.intValue) {
                kept["status_code"] = status.intValue
            }
        default:
            let action = Action.allCases.first {
                $0.category == breadcrumb.category && $0.message == breadcrumb.message && $0.data == breadcrumb.data as? [String: String]
            }
            return action?.breadcrumb(at: breadcrumb.timestamp)
        }
        let sent = Breadcrumb(level: breadcrumb.level, category: breadcrumb.category)
        sent.type = breadcrumb.category == "http" ? "http" : "navigation"
        sent.timestamp = breadcrumb.timestamp
        for (key, value) in kept { sent.setData(value: value, key: key) }
        return sent
    }

    private static let transactionKeys: Set<String> = [
        "contexts", "dist", "environment", "event_id", "extra", "level", "measurements", "platform",
        "release", "sdk", "spans", "start_timestamp", "tags", "timestamp", "transaction", "transaction_info", "type"
    ]

    private static let traceKeys: Set<String> = [
        "type", "span_id", "trace_id", "parent_span_id", "op", "origin", "sampled", "status", "timestamp", "start_timestamp", "data", "tags"
    ]

    private static let measurementKeys: Set<String> = ["frames_total", "frames_slow", "frames_frozen"]

    private static let timingDataKeys: Set<String> = ["frames.delay"]

    static func allowlistedTransaction(_ event: Event) -> Event? {
        event.tags = nil
        event.extra = nil
        event.breadcrumbs = nil
        event.request = nil
        event.message = nil
        event.logger = nil
        event.serverName = nil
        event.modules = nil
        event.fingerprint = nil
        event.exceptions = nil
        event.threads = nil
        event.stacktrace = nil
        event.debugMeta = nil
        event.context = sentContext(event.context)
        event.user = nil
        return isStaticTiming(event.serialize()) ? event : nil
    }

    private static func isStaticTiming(_ payload: [String: Any]) -> Bool {
        func isEmptyOrMissing(_ value: Any?) -> Bool {
            switch value {
            case nil: return true
            case let value as [String: Any]: return value.isEmpty
            case let value as [Any]: return value.isEmpty
            default: return false
            }
        }
        func keys(_ value: Any?, within allowed: Set<String>) -> Bool {
            guard let value else { return true }
            guard let dictionary = value as? [String: Any] else { return false }
            return Set(dictionary.keys).isSubset(of: allowed)
        }
        guard keys(payload, within: transactionKeys),
              let interval = (payload["transaction"] as? String).flatMap(Interval.init(rawValue:)),
              (payload["transaction_info"] as? [String: String]) == ["source": "custom"],
              isEmptyOrMissing(payload["spans"]),
              isEmptyOrMissing(payload["tags"]),
              keys(payload["extra"], within: timingDataKeys),
              keys(payload["measurements"], within: measurementKeys),
              let contexts = payload["contexts"] as? [String: Any],
              keys(contexts, within: sentContextKeys.union(["trace", "profile"])),
              isEmptyOrMissing(contexts["profile"]),
              let trace = contexts["trace"] as? [String: Any],
              keys(trace, within: traceKeys),
              trace["op"] as? String == interval.operation,
              isEmptyOrMissing(trace["tags"]),
              keys(trace["data"], within: timingDataKeys)
        else { return false }
        return true
    }
}

final class SentryTransportGate: URLProtocol {
    override static func canInit(with request: URLRequest) -> Bool { !SentryTelemetry.isCapturing }

    override static func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        client?.urlProtocol(self, didFailWithError: URLError(.cancelled))
    }

    override func stopLoading() {}
}
