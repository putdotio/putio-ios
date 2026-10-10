import Foundation
import Sentry

/// The app's only Sentry entry point. `scripts/verify-fast.sh` rejects
/// `import Sentry` anywhere else in the app, so every capture goes through
/// `capture(_:)` and every event and breadcrumb, including Sentry's automatic
/// crash, hang, network, and UI ones, goes through `redact`.
///
/// It reads no app state, so the app on `next` can adopt it with
/// `TelemetryRedaction.swift` when it adds Sentry (#139).
enum SentryTelemetry {
    /// Contexts Sentry fills with device and runtime facts. Anything else,
    /// such as NSError "user info" or HTTP "response", is dropped.
    static let allowedContexts: Set<String> = ["app", "culture", "device", "os", "runtime", "trace"]

    static func start(dsn: String) {
        SentrySDK.start { options in
            options.dsn = dsn
            options.enableAutoSessionTracking = true
            options.sessionTrackingIntervalMillis = 60000
            configure(options)
        }
    }

    static func configure(_ options: Options) {
        options.sendDefaultPii = false
        options.beforeBreadcrumb = { redact(breadcrumb: $0) }
        options.beforeSend = { redact(event: $0) }
    }

    /// Sends only the failure's category, domain, code, and allowlisted
    /// context. The original error, its message, and its user info stay local.
    static func capture(_ failure: TelemetryFailure) {
        let error = NSError(domain: failure.domain, code: failure.code)
        SentrySDK.capture(error: error) { scope in
            for (key, value) in failure.tags {
                scope.setTag(value: value, key: key)
            }
            scope.setFingerprint(failure.fingerprint)
        }
    }

    /// Fields not rewritten here pass through on purpose: Sentry-maintained
    /// metadata (`eventId`, `timestamp`, `startTimestamp`, `level`, `platform`,
    /// `releaseName`, `dist`, `environment`, `type`, `sdk`, `modules`), code
    /// addresses and symbols (`threads`, `stacktrace`, `debugMeta`), and
    /// properties Sentry never serializes.
    static func redact(event: Event) -> Event {
        event.message = event.message.map(redact(message:))
        event.logger = event.logger.map(TelemetryRedaction.scrub)
        event.serverName = nil
        event.transaction = event.transaction.map(TelemetryRedaction.scrub)
        event.tags = event.tags?
            .filter { TelemetryFailure.tagKeys.contains($0.key) }
            .mapValues(TelemetryRedaction.scrub)
        event.extra = nil
        event.context = event.context?
            .filter { allowedContexts.contains($0.key) }
            .mapValues(TelemetryRedaction.scrub)
        event.fingerprint = event.fingerprint?.map(TelemetryRedaction.scrub)
        event.user = event.user.map(redact(user:))
        event.request = nil
        event.exceptions?.forEach(redact(exception:))
        event.breadcrumbs = event.breadcrumbs?.compactMap(redact(breadcrumb:))
        redactSerializedBreadcrumbs(of: event)
        return event
    }

    static func redact(breadcrumb: Breadcrumb) -> Breadcrumb? {
        breadcrumb.message = breadcrumb.message.map(TelemetryRedaction.scrub)
        breadcrumb.data = breadcrumb.data.map(TelemetryRedaction.scrub)
        return breadcrumb
    }

    /// Watchdog-termination events carry breadcrumbs read back from disk in a
    /// private, already-serialized property that `breadcrumbs` doesn't expose.
    private static func redactSerializedBreadcrumbs(of event: Event) {
        let key = "serializedBreadcrumbs"
        guard event.responds(to: NSSelectorFromString(key)),
              let breadcrumbs = event.value(forKey: key) as? [Any] else { return }
        event.setValue(breadcrumbs.compactMap { ($0 as? [String: Any]).map(TelemetryRedaction.scrub) }, forKey: key)
    }

    private static func redact(message: SentryMessage) -> SentryMessage {
        let redacted = SentryMessage(formatted: TelemetryRedaction.scrub(message.formatted))
        redacted.message = message.message.map(TelemetryRedaction.scrub)
        redacted.params = message.params?.map(TelemetryRedaction.scrub)
        return redacted
    }

    private static func redact(user: Sentry.User) -> Sentry.User {
        let redacted = Sentry.User()
        redacted.userId = user.userId
        return redacted
    }

    private static func redact(exception: Exception) {
        exception.value = exception.value.map(TelemetryRedaction.scrub)
        exception.type = exception.type.map(TelemetryRedaction.scrub)
        exception.module = exception.module.map(TelemetryRedaction.scrub)
        guard let mechanism = exception.mechanism else { return }
        mechanism.desc = mechanism.desc.map(TelemetryRedaction.scrub)
        mechanism.data = mechanism.data.map(TelemetryRedaction.scrub)
        mechanism.helpLink = nil
        if let meta = mechanism.meta {
            meta.signal = meta.signal.map(TelemetryRedaction.scrub)
            meta.machException = meta.machException.map(TelemetryRedaction.scrub)
            meta.error = meta.error.map { SentryNSError(domain: TelemetryRedaction.scrub($0.domain), code: $0.code) }
        }
    }
}
