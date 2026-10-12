import Sentry
import XCTest
@testable import Putio

final class SentryTelemetryTests: XCTestCase {
    private let dsn = "https://synthetickey@relay.example.invalid/1"

    func testOnlyAllowlistedFieldsLeaveTheDevice() throws {
        let title = "Synthetic Feature Title"
        let fileName = "Synthetic.Feature.Title.2001.mkv"
        let host = "media.example.invalid"
        let token = "synthetic-token-5f1c9e"
        let leak = "\(title) /Documents/\(fileName) https://\(host)/hls/master.m3u8?oauth_token=\(token)"

        let event = Event(level: .error)
        event.message = SentryMessage(formatted: leak)
        event.logger = leak
        event.serverName = leak
        event.transaction = leak
        event.type = leak
        event.modules = [leak: leak]
        event.extra = [leak: leak]
        event.fingerprint = [leak]
        event.releaseName = "io.put.synthetic@1.0+1"
        event.tags = ["category": "downloads_observation", leak: leak]
        event.context = ["os": ["name": "iOS"], "culture": [leak: leak], "user info": [leak: leak], "response": [leak: leak]]
        event.user = {
            let user = Sentry.User(userId: "synthetic-installation")
            user.email = leak
            user.username = leak
            user.name = leak
            user.ipAddress = leak
            user.data = [leak: leak]
            return user
        }()
        event.request = {
            let request = SentryRequest()
            request.method = leak
            request.url = leak
            request.queryString = leak
            request.fragment = leak
            request.headers = [leak: leak]
            request.cookies = leak
            return request
        }()
        event.exceptions = [{
            let exception = Exception(value: leak, type: "NSURLErrorDomain")
            exception.module = leak
            exception.threadId = 1
            exception.stacktrace = SentryStacktrace(frames: [Frame()], registers: [:])
            exception.mechanism = Mechanism(type: "NSError")
            exception.mechanism?.desc = leak
            exception.mechanism?.data = [leak: leak]
            exception.mechanism?.helpLink = leak
            exception.mechanism?.meta = MechanismContext()
            exception.mechanism?.meta?.error = SentryNSError(domain: "NSURLErrorDomain", code: -1009)
            return exception
        }()]
        event.threads = [SentryThread(threadId: 1)]
        event.debugMeta = [DebugMeta()]
        let breadcrumb = Breadcrumb(level: .info, category: leak)
        breadcrumb.type = leak
        breadcrumb.origin = leak
        breadcrumb.message = leak
        breadcrumb.data = [leak: leak]
        event.breadcrumbs = [breadcrumb]
        // Watchdog terminations carry breadcrumbs read back from disk here.
        event.setValue([breadcrumb.serialize()], forKey: "serializedBreadcrumbs")

        allowCapture()
        let options = SentryTelemetry.options(dsn: dsn)
        let sent = try XCTUnwrap(options.beforeSend?(event))
        let json = String(decoding: try JSONSerialization.data(withJSONObject: sent.serialize()), as: UTF8.self)

        for leaked in [title, fileName, host, token] {
            XCTAssertFalse(json.contains(leaked), "\(leaked) left the device: \(json)")
        }
        XCTAssertEqual(sent.tags, ["category": "downloads_observation"])
        XCTAssertEqual(sent.exceptions?.first?.type, "NSURLErrorDomain")
        XCTAssertEqual(sent.exceptions?.first?.value, "downloads_observation")
        XCTAssertEqual(sent.exceptions?.first?.mechanism?.meta?.error?.code, -1009)
        XCTAssertEqual(sent.exceptions?.first?.threadId, 1)
        XCTAssertEqual(sent.exceptions?.first?.stacktrace?.frames.count, 1)
        XCTAssertEqual(sent.threads?.first?.threadId, 1)
        XCTAssertEqual(sent.debugMeta?.count, 1)
        XCTAssertEqual(sent.context?["os"]?["name"] as? String, "iOS")
        XCTAssertEqual(sent.user?.userId, "synthetic-installation")
        XCTAssertEqual(sent.releaseName, "io.put.synthetic@1.0+1")
    }

    func testSwitchingOffDropsEventsCancelsUploadsAndDeletesTheCache() throws {
        let defaults = try isolatedDefaults()
        let options = SentryTelemetry.options(dsn: dsn)
        XCTAssertEqual(options.cacheDirectoryPath, SentryTelemetry.cacheDirectory.path)
        try cacheEnvelope()
        let gate = try XCTUnwrap(options.urlSessionDelegate as? URLSessionTaskDelegate)
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let envelope = try XCTUnwrap(URL(string: "https://relay.example.invalid/api/1/envelope/"))
        func upload() -> URLSessionTask {
            let task = session.dataTask(with: envelope)
            gate.urlSession?(session, didCreateTask: task)
            return task
        }

        SentryTelemetry.update(diagnosticsEnabled: true, dsn: dsn, defaults: defaults)
        XCTAssertNotNil(options.beforeSend?(Event(level: .error)))
        XCTAssertEqual(upload().state, .suspended)

        SentryTelemetry.update(diagnosticsEnabled: false, dsn: dsn, defaults: defaults)

        XCTAssertNil(options.beforeSend?(Event(level: .error)))
        XCTAssertNotEqual(upload().state, .suspended, "an upload left while diagnostics were off")
        XCTAssertFalse(FileManager.default.fileExists(atPath: SentryTelemetry.cacheDirectory.path))
    }

    func testColdLaunchHonoursAStoredOptOut() throws {
        let defaults = try isolatedDefaults()
        SentryTelemetry.update(diagnosticsEnabled: false, dsn: nil, defaults: defaults)
        try cacheEnvelope()
        allowCapture()

        SentryTelemetry.start(dsn: dsn, defaults: defaults)

        XCTAssertFalse(SentryTelemetry.isCapturing)
        XCTAssertFalse(SentrySDK.isEnabled)
        XCTAssertFalse(FileManager.default.fileExists(atPath: SentryTelemetry.cacheDirectory.path))
    }

    func testReportsWhenTheAnswerIsOnMissingOrSignedOut() throws {
        let defaults = try isolatedDefaults()
        addTeardownBlock { SentryTelemetry.update(diagnosticsEnabled: false, dsn: self.dsn, defaults: defaults) }
        func assertReports(_ moment: String) {
            XCTAssertTrue(SentryTelemetry.isCapturing, moment)
            XCTAssertTrue(SentrySDK.isEnabled, moment)
        }

        SentryTelemetry.start(dsn: dsn, defaults: defaults)
        assertReports("before any account loads")

        SentryTelemetry.update(diagnosticsEnabled: false, dsn: dsn, defaults: defaults)
        SentryTelemetry.update(diagnosticsEnabled: nil, dsn: dsn, defaults: defaults)
        assertReports("after signing out")

        SentryTelemetry.update(diagnosticsEnabled: true, dsn: dsn, defaults: defaults)
        assertReports("while diagnostics are on")
    }

    func testReportsThroughTheRelay() {
        XCTAssertEqual(
            SentryTelemetry.relayDSN("https://synthetickey@o0.ingest.example.invalid/5282170"),
            "https://synthetickey@relay.put.io/5282170"
        )
        for unusable in ["", "$(PUTIO_SENTRY_DSN)", "https://sentry.example.invalid/12", "https://k@host/not-a-project"] {
            XCTAssertNil(SentryTelemetry.relayDSN(unusable), unusable)
        }
    }

    private func cacheEnvelope() throws {
        let pending = SentryTelemetry.cacheDirectory.appending(path: "envelopes/pending")
        try FileManager.default.createDirectory(at: pending.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("synthetic".utf8).write(to: pending)
    }

    private func isolatedDefaults() throws -> UserDefaults {
        let suite = "SentryTelemetryTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        return defaults
    }

    private func allowCapture() {
        let previous = SentryTelemetry.isCapturing
        SentryTelemetry.isCapturing = true
        addTeardownBlock { SentryTelemetry.isCapturing = previous }
    }
}
