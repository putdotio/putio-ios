import Foundation
import os
import Sentry

/// The app's only Sentry entry point. `scripts/verify-fast.sh` rejects
/// `import Sentry` anywhere else, so only the SDK fills the contexts and user
/// that `allowlisted` keeps. It runs only while the account allows diagnostics.
enum SentryTelemetry {
    enum Failure: String {
        case downloadedAssetDeletion = "downloaded_asset_deletion"
        case downloadsObservation = "downloads_observation"
        case pushRegistration = "push_registration"
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

    /// Copies listed fields into a new event, so unlisted ones, including any a
    /// Sentry upgrade adds to the event, stay on the device. Assumes tracing stays
    /// off: a transaction would lose its spans and trace state here.
    static func allowlisted(_ event: Event) -> Event {
        let category = event.tags?["category"]
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
        sent.tags = category.map { ["category": $0] }
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
