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
        case pushRegistration = "push_registration"
        case realmOpen = "realm_open"
        case realmWrite = "realm_write"
        case sessionLoad = "session_load"
        case supportLogin = "support_login"
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
                InternalFailurePresenter.log("SentryTelemetry: legacy cache not deleted: \(error.localizedDescription)")
            }
        }
        return deleted
    }

    /// The SDK holds its session delegate weakly.
    private static let transportGate = SentryTransportGate()

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
            if !SentrySDK.isEnabled { SentrySDK.start(options: options(dsn: dsn)) }
        } else {
            if SentrySDK.isEnabled { SentrySDK.close() }
            do {
                try FileManager.default.removeItem(at: cacheDirectory)
            } catch let error as CocoaError where error.code == .fileNoSuchFile {
                // Deleted by an earlier switch-off; every launch while off lands here.
            } catch {
                InternalFailurePresenter.log("SentryTelemetry: cache not deleted: \(error.localizedDescription)")
            }
        }
    }

    static func options(dsn: String) -> Options {
        let options = Options()
        options.dsn = dsn
        options.enableAutoSessionTracking = true
        options.sessionTrackingIntervalMillis = 60000
        options.cacheDirectoryPath = cacheDirectory.path
        options.urlSessionDelegate = transportGate
        options.maxBreadcrumbs = 0
        options.enableCaptureFailedRequests = false
        options.enableMetricKit = true
        options.enableMetricKitRawPayload = false
        options.beforeSend = { isCapturing && !predatesConsent($0) ? allowlisted($0) : nil }
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
    /// Sentry upgrade adds to the event, stay on the device. Assumes tracing stays
    /// off: a transaction would lose its spans and trace state here.
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
        sent.context = event.context?.filter { ["app", "device", "os", "runtime"].contains($0.key) }
        sent.tags = sentTags.isEmpty ? nil : sentTags
        sent.user = event.user?.userId.map(Sentry.User.init(userId:))
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
}

final class SentryTransportGate: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, didCreateTask task: URLSessionTask) {
        if !SentryTelemetry.isCapturing { task.cancel() }
    }
}
