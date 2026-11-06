import Foundation
import os
import Sentry

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
        case sessionLoad = "session_load"
        case supportLogin = "support_login"
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

    static func lastKnownDiagnosticsEnabled(defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: consentKey) as? Bool ?? true
    }

    static func start(dsn: String? = SENTRY_DSN, defaults: UserDefaults = .standard) {
        apply(dsn: dsn, defaults: defaults)
    }

    /// Keeps the account's answer, even in a build without a DSN, and applies it.
    /// `nil` is signed out.
    static func update(diagnosticsEnabled enabled: Bool?, dsn: String? = SENTRY_DSN, defaults: UserDefaults = .standard) {
        defaults.set(enabled, forKey: consentKey)
        apply(dsn: dsn, defaults: defaults)
    }

    /// `SentrySDK.close()` uploads cached envelopes and a final session without
    /// `beforeSend`. The transport gate cancels those uploads and the cache is
    /// deleted, so nothing recorded before a switch-off leaves later either.
    private static func apply(dsn: String?, defaults: UserDefaults) {
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
        options.beforeSend = { isCapturing ? allowlisted($0) : nil }
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

    static func capture(_ failure: Failure, error: Error? = nil) {
        SentrySDK.capture(error: error ?? NSError(domain: "io.put.telemetry", code: 0)) { scope in
            scope.setTag(value: failure.rawValue, key: "category")
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

    /// Copies listed fields into a new event, so unlisted ones, including any a
    /// Sentry upgrade adds to the event, stay on the device. Assumes tracing stays
    /// off: a transaction would lose its spans and trace state here.
    static func allowlisted(_ event: Event) -> Event {
        let category = event.tags?["category"]
        let tags = event.tags?.filter { key, value in
            key == "category" || PlaybackFailure.Tag(rawValue: key)?.allows(value) == true
        }
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
        sent.tags = tags?.isEmpty == false ? tags : nil
        sent.user = event.user?.userId.map(Sentry.User.init(userId:))
        sent.exceptions = event.exceptions?.map { exception in
            let kept = Exception(value: category, type: exception.type)
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
