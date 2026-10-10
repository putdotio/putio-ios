import ObjectiveC
import Sentry
import XCTest
@testable import Putio

final class SentryTelemetryTests: XCTestCase {
    /// Every property of the Sentry models the boundary rewrites, as reviewed in
    /// `SentryTelemetry.redact`. A Sentry upgrade that adds a field fails here
    /// until `redact` handles it and the field is added to this list.
    private let reviewedProperties: [String: Set<String>] = [
        "SentryEvent": [
            "attachAllThreadsOverride", "breadcrumbs", "context", "debugMeta", "dist", "endSystemTime",
            "environment", "error", "eventId", "exceptions", "extra", "fingerprint", "isAppHangEvent",
            "isFatalEvent", "level", "logger", "message", "modules", "platform", "releaseName", "request",
            "sdk", "serializedBreadcrumbs", "serverName", "stacktrace", "startSystemTime", "startTimestamp",
            "tags", "threads", "timestamp", "transaction", "type", "user",
        ],
        "SentryBreadcrumb": ["category", "data", "level", "message", "origin", "timestamp", "type"],
        "SentryException": ["mechanism", "module", "stacktrace", "threadId", "type", "value"],
        "SentryMechanism": ["data", "desc", "handled", "helpLink", "meta", "synthetic", "type"],
        "SentryMechanismContext": ["error", "machException", "signal"],
        "SentryMessage": ["formatted", "message", "params"],
        "SentryRequest": ["bodySize", "cookies", "fragment", "headers", "method", "queryString", "url"],
        "SentryUser": ["data", "email", "geo", "ipAddress", "name", "unknown", "userId", "username"],
    ]

    func testEveryReviewedSentryModelPropertyIsHandledByTheBoundary() {
        let classes: [AnyClass] = [
            Event.self, Breadcrumb.self, Exception.self, Mechanism.self,
            MechanismContext.self, SentryMessage.self, SentryRequest.self, Sentry.User.self,
        ]
        for type in classes {
            let name = NSStringFromClass(type)
            XCTAssertEqual(
                propertyNames(of: type),
                reviewedProperties[name],
                "\(name) changed shape; handle the new field in SentryTelemetry.redact, then update this list"
            )
        }
    }

    func testRedactedEventLeaksNoSyntheticSecretInAnySerializedField() throws {
        let event = SentryTelemetry.redact(event: makeLeakyEvent())
        let serialized = event.serialize()
        let strings = allStrings(in: serialized)

        for leak in SyntheticTelemetry.leaks {
            let hits = strings.filter { $0.contains(leak) }
            XCTAssertTrue(hits.isEmpty, "\(leak) survived redaction in \(hits)")
        }

        XCTAssertEqual(event.tags, ["category": "playback", "player": "avplayer", "error_domain": "AVFoundationErrorDomain"])
        XCTAssertEqual(event.fingerprint?.first, "playback")
        XCTAssertEqual(event.exceptions?.first?.type, "AVFoundationErrorDomain")
        XCTAssertEqual(event.exceptions?.first?.mechanism?.meta?.error?.code, -11800)
        XCTAssertEqual(event.context?["os"]?["name"] as? String, "iOS")
        XCTAssertEqual(Set(event.context.map { Array($0.keys) } ?? []), ["app", "os"])
        XCTAssertEqual(event.user?.userId, "synthetic-installation")
        XCTAssertEqual(event.releaseName, "io.put.synthetic@1.0")
        XCTAssertNil(event.request)
        XCTAssertNil(event.extra)
        XCTAssertEqual(event.breadcrumbs?.first?.data?["url"] as? String, "[url:media.example.invalid]")
    }

    func testConfiguredCallbacksRouteEventsAndBreadcrumbsThroughTheBoundary() throws {
        let options = Options()
        SentryTelemetry.configure(options)

        let breadcrumb = try XCTUnwrap(options.beforeBreadcrumb?(makeLeakyBreadcrumb()))
        let event = try XCTUnwrap(options.beforeSend?(makeLeakyEvent()))

        XCTAssertFalse(options.sendDefaultPii)
        for leak in SyntheticTelemetry.leaks {
            XCTAssertFalse(allStrings(in: breadcrumb.serialize()).contains { $0.contains(leak) }, leak)
            XCTAssertFalse(allStrings(in: event.serialize()).contains { $0.contains(leak) }, leak)
        }
    }

    // MARK: - Fixtures

    private func makeLeakyEvent() -> Event {
        let leaks = SyntheticTelemetry.self
        let event = Event(level: .error)
        event.message = {
            let message = SentryMessage(formatted: "Playback failed for \(leaks.signedURL)")
            message.message = "Opening \(leaks.filePath)"
            message.params = [leaks.signedURL, "Bearer \(leaks.token)"]
            return message
        }()
        event.error = NSError(domain: "AVFoundationErrorDomain", code: -11800, userInfo: [NSURLErrorFailingURLErrorKey: URL(string: leaks.signedURL) as Any])
        event.logger = "player \(leaks.signedURL)"
        event.serverName = "host-\(leaks.token)"
        event.releaseName = "io.put.synthetic@1.0"
        event.transaction = "FileViewController \(leaks.fileName)"
        event.tags = [
            "category": "playback",
            "player": "avplayer",
            "error_domain": "AVFoundationErrorDomain",
            "media_title": leaks.title,
            "url": leaks.signedURL,
        ]
        event.extra = ["nested": ["title": leaks.title, "urls": [leaks.signedURL]]]
        event.context = [
            "os": ["name": "iOS", "version": "26.0"],
            "app": ["view_names": ["FileViewController"], "title": leaks.title, "note": leaks.signedURL],
            "user info": [NSLocalizedDescriptionKey: "Could not open \(leaks.title)"],
            "response": ["headers": ["Authorization": "Bearer \(leaks.token)"]],
        ]
        event.fingerprint = ["playback", leaks.signedURL]
        event.user = {
            let user = Sentry.User(userId: "synthetic-installation")
            user.email = "synthetic@example.invalid"
            user.username = leaks.title
            user.name = leaks.title
            user.ipAddress = "192.0.2.1"
            user.data = ["token": leaks.token]
            return user
        }()
        event.request = {
            let request = SentryRequest()
            request.url = leaks.signedURL
            request.queryString = "oauth_token=\(leaks.token)"
            request.fragment = leaks.token
            request.headers = ["Authorization": "Bearer \(leaks.token)"]
            request.cookies = "session=\(leaks.token)"
            return request
        }()
        event.exceptions = [{
            let exception = Exception(value: "Cannot open \(leaks.filePath) at \(leaks.signedURL)", type: "AVFoundationErrorDomain")
            exception.module = "Putio \(leaks.fileName)"
            let mechanism = Mechanism(type: "generic")
            mechanism.desc = "token=\(leaks.token)"
            mechanism.data = ["url": leaks.signedURL, "title": leaks.title]
            mechanism.helpLink = leaks.signedURL
            let meta = MechanismContext()
            meta.error = SentryNSError(domain: "AVFoundationErrorDomain", code: -11800)
            meta.signal = ["name": "SIGABRT", "detail": leaks.filePath]
            mechanism.meta = meta
            exception.mechanism = mechanism
            return exception
        }()]
        event.breadcrumbs = [makeLeakyBreadcrumb()]
        event.setValue([makeLeakyBreadcrumb().serialize()], forKey: "serializedBreadcrumbs")
        return event
    }

    private func makeLeakyBreadcrumb() -> Breadcrumb {
        let leaks = SyntheticTelemetry.self
        let breadcrumb = Breadcrumb(level: .info, category: "http")
        breadcrumb.message = "GET \(leaks.signedURL)"
        breadcrumb.data = [
            "url": leaks.signedURL,
            "http.query": "oauth_token=\(leaks.token)",
            "title": leaks.title,
            "nested": ["file_name": leaks.fileName, "paths": [leaks.filePath]],
        ]
        return breadcrumb
    }

    private func propertyNames(of type: AnyClass) -> Set<String> {
        var count: UInt32 = 0
        guard let properties = class_copyPropertyList(type, &count) else { return [] }
        defer { free(properties) }
        let inherited: Set<String> = ["debugDescription", "description", "hash", "superclass"]
        return Set((0..<Int(count)).map { String(cString: property_getName(properties[$0])) }).subtracting(inherited)
    }

    private func allStrings(in value: Any) -> [String] {
        switch value {
        case let string as String:
            return [string]
        case let dictionary as [String: Any]:
            return dictionary.flatMap { [$0.key] + allStrings(in: $0.value) }
        case let array as [Any]:
            return array.flatMap { allStrings(in: $0) }
        default:
            return []
        }
    }
}
