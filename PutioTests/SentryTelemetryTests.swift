import os
import RealmSwift
import Sentry
import XCTest
@testable import Putio
@testable import PutioSDK

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
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RecordingURLProtocol.self]
        // Built the way Sentry's transport builds its session.
        let session = URLSession(configuration: configuration, delegate: options.urlSessionDelegate, delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        func uploadReachesTheNetwork() throws -> Bool {
            let envelope = try XCTUnwrap(URL(string: "https://relay.example.invalid/api/1/envelope/?\(UUID().uuidString)"))
            let finished = expectation(description: "upload finished")
            session.dataTask(with: URLRequest(url: envelope)) { _, _, _ in finished.fulfill() }.resume()
            wait(for: [finished], timeout: 5)
            return RecordingURLProtocol.loaded(envelope)
        }

        SentryTelemetry.update(diagnosticsEnabled: true, dsn: dsn, defaults: defaults)
        XCTAssertNotNil(options.beforeSend?(Event(level: .error)))
        XCTAssertTrue(try uploadReachesTheNetwork(), "the gate held an upload while diagnostics were on")

        SentryTelemetry.update(diagnosticsEnabled: false, dsn: dsn, defaults: defaults)

        XCTAssertNil(options.beforeSend?(Event(level: .error)))
        XCTAssertFalse(try uploadReachesTheNetwork(), "an upload left while diagnostics were off")
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

    func testDiagnosticsCheckSendsOneAllowlistedEventOnlyFromASandboxReceipt() throws {
        let defaults = try isolatedDefaults()
        addTeardownBlock { SentryTelemetry.update(diagnosticsEnabled: false, dsn: self.dsn, defaults: defaults) }
        let options = SentryTelemetry.options(dsn: dsn)
        let beforeSend = try XCTUnwrap(options.beforeSend)
        var sent: [Event] = []
        options.beforeSend = { event in
            beforeSend(event).map { sent.append($0) }
            return nil
        }
        SentrySDK.start(options: options)
        allowCapture()
        let receipts = URL(filePath: "/synthetic/StoreKit", directoryHint: .isDirectory)

        XCTAssertFalse(SentryTelemetry.captureDiagnosticsCheck(receiptURL: receipts.appending(path: "receipt")))
        XCTAssertFalse(SentryTelemetry.captureDiagnosticsCheck(receiptURL: nil))
        XCTAssertTrue(sent.isEmpty, "an App Store install sent the check")

        XCTAssertTrue(SentryTelemetry.captureDiagnosticsCheck(receiptURL: receipts.appending(path: "sandboxReceipt")))
        XCTAssertEqual(sent.count, 1)
        XCTAssertEqual(sent.first?.tags, ["category": "diagnostics_check"])
        XCTAssertEqual(sent.first?.exceptions?.first?.value, "diagnostics_check")

        SentryTelemetry.isCapturing = false
        SentryTelemetry.captureDiagnosticsCheck(receiptURL: receipts.appending(path: "sandboxReceipt"))
        XCTAssertEqual(sent.count, 1, "the check skipped the diagnostics gate")
    }

    func testUnhandledCrashesKeepATokenizedReasonOnly() throws {
        let path = "/var/mobile/Containers/Data/Application/SYNTHETIC/Documents/default.realm"
        let fixtures: [(type: String, reason: String?, token: String?)] = [
            ("RLMException", "Realm accessed from incorrect thread.", "realm_incorrect_thread"),
            ("RLMException", "Object has been deleted or invalidated.", "realm_object_invalidated"),
            ("RLMException", "Accessing object of type Download which has been invalidated or deleted", "realm_object_invalidated"),
            ("RLMException", "Cannot modify managed RLMArray outside of a write transaction.", "realm_write_outside_transaction"),
            ("RLMException", "Cannot modify managed objects outside of a write transaction.", "realm_write_outside_transaction"),
            ("RLMException", "Index 2 is out of bounds (must be less than 2).", "table_row_out_of_bounds"),
            ("NSRangeException", "*** -[__NSArrayM objectAtIndexedSubscript:]: index 5 beyond bounds [0 .. 3]", "table_row_out_of_bounds"),
            ("NSInternalInconsistencyException", "attempt to delete row 3 from section 0 which only contains 2 rows before the update", "table_row_out_of_bounds"),
            ("RLMException", "Unable to open a realm at path '\(path)': Permission denied.", "other"),
            ("RLMException", nil, "other"),
            ("NSInvalidArgumentException", "Synthetic reason at \(path)", nil),
        ]
        allowCapture()
        let options = SentryTelemetry.options(dsn: dsn)

        for fixture in fixtures {
            let sent = try XCTUnwrap(options.beforeSend?(crash(type: fixture.type, reason: fixture.reason, handled: false)))
            let json = String(decoding: try JSONSerialization.data(withJSONObject: sent.serialize()), as: UTF8.self)
            XCTAssertEqual(sent.exceptions?.first?.value, fixture.token, fixture.reason ?? fixture.type)
            XCTAssertEqual(sent.exceptions?.first?.type, fixture.type)
            XCTAssertFalse(json.contains("/var/mobile"), json)
        }

        let handled = try XCTUnwrap(options.beforeSend?(crash(type: "RLMException", reason: "Realm accessed from incorrect thread.", handled: true)))
        XCTAssertNil(handled.exceptions?.first?.value, "a handled exception is not a crash")
    }

    func testFailureTagsKeepOnlyTheirFixedVocabulary() throws {
        let sent = try recordSentEvents()
        let config = PutioSDKRequestConfig(apiConfig: PutioSDKConfig(clientID: "3001"), url: "/config", method: .get)
        let decoding = PutioSDKError(
            request: PutioSDKErrorRequestInformation(config: config),
            decodingError: URLError(.cannotParseResponse),
            responseBody: "{}"
        )
        let leak = "Synthetic Feature Title /Documents/Synthetic.mkv"

        SentryTelemetry.capture(.sessionLoad, error: decoding, reason: .init(decoding), endpoint: .config)
        SentryTelemetry.capture(.realmWrite, error: Realm.Error(.fail), context: "DownloadManager.persistTask.write")
        SentryTelemetry.capture(.realmWrite, context: leak)

        XCTAssertEqual(sent.events.map(\.tags), [
            ["category": "session_load", "reason": "decoding", "endpoint": "config"],
            ["category": "realm_write", "context": "DownloadManager.persistTask.write"],
            ["category": "realm_write"],
        ])
        XCTAssertEqual(sent.events[1].exceptions?.first?.mechanism?.meta?.error?.domain, "io.realm")
        XCTAssertEqual(sent.events[1].exceptions?.first?.mechanism?.meta?.error?.code, Realm.Error.Code.fail.rawValue)

        let forged = Event(level: .error)
        forged.tags = ["category": "session_load", "reason": leak, "endpoint": "https://media.example.invalid/config"]
        XCTAssertEqual(SentryTelemetry.allowlisted(forged).tags, ["category": "session_load"])
    }

    func testSDKFailureReasons() {
        let config = PutioSDKRequestConfig(apiConfig: PutioSDKConfig(clientID: "3001"), url: "/account/info", method: .get)
        let request = PutioSDKErrorRequestInformation(config: config)
        let cases: [(PutioSDKError, SentryTelemetry.Reason)] = [
            (PutioSDKError(request: request, decodingError: URLError(.cannotParseResponse), responseBody: ""), .decoding),
            (PutioSDKError(request: request, error: URLError(.notConnectedToInternet)), .network),
            (PutioSDKError(request: request, unknownError: URLError(.badServerResponse)), .unknown),
            (PutioSDKError(request: request, statusCode: 404, errorType: nil, message: "", underlyingError: URLError(.badServerResponse)), .http4xx),
            (PutioSDKError(request: request, statusCode: 503, errorType: nil, message: "", underlyingError: URLError(.badServerResponse)), .http5xx),
            (PutioSDKError(request: request, statusCode: 0, errorType: nil, message: "", underlyingError: URLError(.badServerResponse)), .unknown),
        ]
        for (error, reason) in cases {
            XCTAssertEqual(SentryTelemetry.Reason(error), reason, "\(error.type)")
        }
    }

    func testMetricKitHangsLeaveWithTheirMechanism() throws {
        let options = SentryTelemetry.options(dsn: dsn)
        XCTAssertTrue(options.enableMetricKit)
        XCTAssertFalse(options.enableMetricKitRawPayload)

        let hang = Event(level: .warning)
        let exception = Exception(value: "MXHangDiagnostic hangDuration:3 sec", type: "MXHangDiagnostic")
        exception.mechanism = Mechanism(type: "mx_hang_diagnostic")
        exception.mechanism?.handled = NSNumber(value: true)
        exception.mechanism?.synthetic = NSNumber(value: true)
        exception.stacktrace = SentryStacktrace(frames: [Frame()], registers: [:])
        hang.exceptions = [exception]
        hang.threads = [SentryThread(threadId: 0)]
        allowCapture()

        let sent = try XCTUnwrap(options.beforeSend?(hang))
        let kept = try XCTUnwrap(sent.exceptions?.first)
        XCTAssertEqual(kept.type, "MXHangDiagnostic")
        XCTAssertEqual(kept.mechanism?.type, "mx_hang_diagnostic")
        XCTAssertEqual(kept.mechanism?.handled?.boolValue, true)
        XCTAssertEqual(kept.mechanism?.synthetic?.boolValue, true)
        XCTAssertEqual(kept.stacktrace?.frames.count, 1)
        XCTAssertEqual(sent.threads?.count, 1)
    }

    func testDeletesTheLegacySentryCacheOnly() throws {
        let caches = FileManager.default.temporaryDirectory.appending(path: "SentryTelemetryTests-\(UUID().uuidString)")
        addTeardownBlock { try? FileManager.default.removeItem(at: caches) }
        // Paths from Sentry 7.9.0's SentryFileManager, SentryCrash and SentryInstallation, as 2.58.0 ran them.
        let legacy = ["io.sentry/0123abcd/envelopes/pending", "SentryCrash/put.io/Reports/report.json", "INSTALLATION"]
        let kept = ["io.put.diagnostics/envelopes/pending", "io.put.diagnostics/INSTALLATION"]
        for path in legacy + kept {
            let file = caches.appending(path: path)
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("synthetic".utf8).write(to: file)
        }

        XCTAssertTrue(SentryTelemetry.deleteLegacyCache(in: caches))

        for path in ["io.sentry", "SentryCrash", "INSTALLATION"] {
            XCTAssertFalse(FileManager.default.fileExists(atPath: caches.appending(path: path).path), path)
        }
        for path in kept {
            XCTAssertTrue(FileManager.default.fileExists(atPath: caches.appending(path: path).path), path)
        }
        XCTAssertTrue(SentryTelemetry.deleteLegacyCache(in: caches), "nothing left to delete is done")
    }

    func testReportsThroughTheRelay() {
        XCTAssertEqual(
            SentryTelemetry.relayDSN("https://synthetickey@o0.ingest.example.invalid/5282170"),
            "https://synthetickey@relay.put.io/5282170"
        )
        for unusable in ["", "$(PUTIO_SENTRY_DSN)", "http://k@host/1", "https://sentry.example.invalid/12", "https://k@host/not-a-project"] {
            XCTAssertNil(SentryTelemetry.relayDSN(unusable), unusable)
        }
    }

    private func crash(type: String, reason: String?, handled: Bool) -> Event {
        let event = Event(level: .fatal)
        let exception = Exception(value: reason, type: type)
        exception.mechanism = Mechanism(type: "nsexception")
        exception.mechanism?.handled = NSNumber(value: handled)
        event.exceptions = [exception]
        return event
    }

    private func recordSentEvents() throws -> SentEvents {
        let defaults = try isolatedDefaults()
        addTeardownBlock { SentryTelemetry.update(diagnosticsEnabled: false, dsn: self.dsn, defaults: defaults) }
        let options = SentryTelemetry.options(dsn: dsn)
        let beforeSend = try XCTUnwrap(options.beforeSend)
        let sent = SentEvents()
        options.beforeSend = { event in
            beforeSend(event).map { sent.events.append($0) }
            return nil
        }
        SentrySDK.start(options: options)
        allowCapture()
        return sent
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

private final class SentEvents {
    var events: [Event] = []
}

/// Stands in for the network: records every request that starts loading.
private final class RecordingURLProtocol: URLProtocol {
    private static let loadedURLs = OSAllocatedUnfairLock(initialState: Set<URL>())

    static func loaded(_ url: URL) -> Bool {
        loadedURLs.withLock { $0.contains(url) }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url,
              let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)
        else { return }
        Self.loadedURLs.withLock { _ = $0.insert(url) }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
