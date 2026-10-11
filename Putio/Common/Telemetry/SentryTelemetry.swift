import Foundation
import Sentry

/// The app's only Sentry entry point. `scripts/verify-fast.sh` rejects
/// `import Sentry` anywhere else, so only the SDK fills the contexts and user
/// that `allowlisted` keeps.
enum SentryTelemetry {
    enum Failure: String {
        case downloadedAssetDeletion = "downloaded_asset_deletion"
        case downloadsObservation = "downloads_observation"
        case pushRegistration = "push_registration"
    }

    static func start(dsn: String) {
        SentrySDK.start(options: options(dsn: dsn))
    }

    static func options(dsn: String) -> Options {
        let options = Options()
        options.dsn = dsn
        options.enableAutoSessionTracking = true
        options.sessionTrackingIntervalMillis = 60000
        options.maxBreadcrumbs = 0
        options.beforeSend = allowlisted
        return options
    }

    static func capture(_ failure: Failure, error: Error? = nil) {
        SentrySDK.capture(error: error ?? NSError(domain: "io.put.telemetry", code: 0)) { scope in
            scope.setTag(value: failure.rawValue, key: "category")
        }
    }

    /// Copies listed fields into a new event, so anything else, including
    /// fields a Sentry upgrade adds, stays on the device.
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
