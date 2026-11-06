import AVFoundation
import GoogleCast
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
        let sent = try startRecordingSentEvents()
        allowCapture()
        let receipts = URL(filePath: "/synthetic/StoreKit", directoryHint: .isDirectory)

        XCTAssertFalse(SentryTelemetry.captureDiagnosticsCheck(receiptURL: receipts.appending(path: "receipt")))
        XCTAssertFalse(SentryTelemetry.captureDiagnosticsCheck(receiptURL: nil))
        XCTAssertTrue(sent().isEmpty, "an App Store install sent the check")

        XCTAssertTrue(SentryTelemetry.captureDiagnosticsCheck(receiptURL: receipts.appending(path: "sandboxReceipt")))
        XCTAssertEqual(sent().count, 1)
        XCTAssertEqual(sent().first?.tags, ["category": "diagnostics_check"])
        XCTAssertEqual(sent().first?.exceptions?.first?.value, "diagnostics_check")

        SentryTelemetry.isCapturing = false
        SentryTelemetry.captureDiagnosticsCheck(receiptURL: receipts.appending(path: "sandboxReceipt"))
        XCTAssertEqual(sent().count, 1, "the check skipped the diagnostics gate")
    }

    func testAPlaybackFailureSendsOneBoundedReportWhileDiagnosticsAreOn() throws {
        let sent = try startRecordingSentEvents()
        allowCapture()
        let title = "Synthetic Feature Title"
        let fileName = "Synthetic.Feature.Title.2001.mkv"
        let host = "media.example.invalid"
        let token = "synthetic-token-5f1c9e"
        let streamFailure = NSError(domain: AVFoundationErrorDomain, code: -11800, userInfo: [
            NSLocalizedDescriptionKey: fileName,
            NSURLErrorFailingURLStringErrorKey: "https://\(host)/hls/master.m3u8?oauth_token=\(token)",
            NSUnderlyingErrorKey: NSError(domain: NSOSStatusErrorDomain, code: -12971, userInfo: [NSLocalizedDescriptionKey: title])
        ])
        let missingDownload = NSError(domain: NSURLErrorDomain, code: NSURLErrorFileDoesNotExist, userInfo: [
            NSURLErrorFailingURLErrorKey: URL(filePath: "/Documents/\(fileName)")
        ])

        let streamed = PlaybackAnalytics(AnalyticsEvent.Playback(media: .video, streamMethod: .hls, player: .avplayer), capture: { _ in })
        streamed.fail(streamFailure)
        streamed.fail(streamFailure)
        PlaybackAnalytics(AnalyticsEvent.Playback(media: .video, streamMethod: .localFile, player: .avplayer), capture: { _ in })
            .fail(missingDownload)
        drainMainQueue()
        SentryTelemetry.isCapturing = false
        PlaybackAnalytics(AnalyticsEvent.Playback(media: .audio, streamMethod: .progressive, player: .avplayer), capture: { _ in })
            .fail(streamFailure)
        drainMainQueue()

        XCTAssertEqual(sent().map(\.tags), [
            [
                "category": "playback", "playback_signal": "item_failed", "player": "avplayer", "stream_method": "hls", "media": "video",
                "error_domain": "AVFoundationErrorDomain", "error_code": "-11800", "underlying_domain": "NSOSStatusErrorDomain", "underlying_code": "-12971"
            ],
            [
                "category": "playback", "playback_signal": "item_failed", "player": "avplayer", "stream_method": "local_file", "media": "video",
                "error_domain": "NSURLErrorDomain", "error_code": "-1100"
            ]
        ])
        XCTAssertEqual(sent().map { $0.exceptions?.first?.type }, ["AVFoundationErrorDomain", "NSURLErrorDomain"])
        let json = String(decoding: try JSONSerialization.data(withJSONObject: sent().map { $0.serialize() }), as: UTF8.self)
        for leaked in [title, fileName, host, token] {
            XCTAssertFalse(json.contains(leaked), "\(leaked) left the device: \(json)")
        }
    }

    func testEachPlaybackFailureSignalIsReportedOncePerAttempt() throws {
        let sent = try startRecordingSentEvents()
        allowCapture()
        let streamed = PlaybackAnalytics(AnalyticsEvent.Playback(media: .video, streamMethod: .hls, player: .avplayer), capture: { _ in })
        streamed.failedToPlayToEnd(URLError(.networkConnectionLost))
        streamed.fail(URLError(.networkConnectionLost))
        drainMainQueue()
        let cast = CastPlaybackTracker(capture: { _, _ in })
        let load = NSObject()
        cast.loadStarted(load, playback: AnalyticsEvent.Playback(media: .video, streamMethod: .mp4, player: .chromecast), session: AccountNoticeStore.shared.session)
        cast.loadFailed(load, error: GCKError(code: .mediaLoadFailed))
        cast.loadFailed(load, error: GCKError(code: .mediaLoadFailed))
        SentryTelemetry.capture(
            .init(signal: .castLoadFailed, playback: AnalyticsEvent.Playback(media: .video, streamMethod: .hls, player: .chromecast)),
            error: NSError(domain: "io.synthetic.unlisted", code: 7),
            startedIn: AccountNoticeStore.shared.session
        )

        XCTAssertEqual(sent().map(\.tags), [
            [
                "category": "playback", "playback_signal": "failed_to_play_to_end", "player": "avplayer", "stream_method": "hls", "media": "video",
                "error_domain": "NSURLErrorDomain", "error_code": "-1005"
            ],
            [
                "category": "playback", "playback_signal": "cast_load_failed", "player": "chromecast", "stream_method": "mp4", "media": "video",
                "error_domain": "com.google.cast.GCKError", "error_code": "30"
            ],
            [
                "category": "playback", "playback_signal": "cast_load_failed", "player": "chromecast", "stream_method": "hls", "media": "video",
                "error_domain": "other", "error_code": "7"
            ]
        ])
        XCTAssertEqual(sent().last?.exceptions?.first?.type, "other")
    }

    func testAPlaybackFailureThatOutlivesItsSessionSendsNothing() throws {
        let sent = try startRecordingSentEvents()
        allowCapture()
        let video = AnalyticsEvent.Playback(media: .video, streamMethod: .hls, player: .avplayer)
        let pictureInPicture = PlaybackAnalytics(video, capture: { _ in })
        let cast = CastPlaybackTracker(capture: { _, _ in })
        let load = NSObject()
        cast.loadStarted(load, playback: AnalyticsEvent.Playback(media: .video, streamMethod: .mp4, player: .chromecast), session: AccountNoticeStore.shared.session)

        AccountNoticeStore.shared.clear()
        pictureInPicture.fail(URLError(.timedOut))
        cast.loadFailed(load, error: GCKError(code: .timeout))
        PlaybackAnalytics(video, capture: { _ in }).fail(URLError(.timedOut))
        drainMainQueue()

        XCTAssertEqual(sent().map { $0.tags?["playback_signal"] }, ["item_failed"])
    }

    func testUnhandledCrashesKeepATokenizedReasonOnly() throws {
        let path = "/var/mobile/Containers/Data/Application/SYNTHETIC/Documents/default.realm"
        let fixtures: [(type: String, reason: String?, token: String?)] = [
            ("RLMException", "Realm accessed from incorrect thread.", "realm_incorrect_thread"),
            ("RLMException", "Object has been deleted or invalidated.", "realm_object_invalidated"),
            ("RLMException", "Accessing object of type Download which has been invalidated or deleted", "realm_object_invalidated"),
            ("RLMException", "Cannot modify managed RLMArray outside of a write transaction.", "realm_write_outside_transaction"),
            ("RLMException", "Cannot modify managed objects outside of a write transaction.", "realm_write_outside_transaction"),
            ("RLMException", "Can only add, remove, or create objects in a Realm in a write transaction - call beginWriteTransaction on an RLMRealm instance first.", "realm_write_outside_transaction"),
            ("RLMException", "Index 2 is out of bounds (must be less than 2).", "table_row_out_of_bounds"),
            ("NSRangeException", "*** -[__NSArrayM objectAtIndexedSubscript:]: index 5 beyond bounds [0 .. 3]", "table_row_out_of_bounds"),
            ("NSInternalInconsistencyException", "attempt to delete row 3 from section 0 which only contains 2 rows before the update", "table_row_out_of_bounds"),
            ("NSInternalInconsistencyException", "Invalid update: invalid number of rows in section 0.", "table_row_out_of_bounds"),
            ("NSRangeException", "-[__NSCFString substringWithRange:]: Range {5, 3} out of bounds; string length 4", "other"),
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
        let sent = try startRecordingSentEvents()
        allowCapture()
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

        XCTAssertEqual(sent().map(\.tags), [
            ["category": "session_load", "reason": "decoding", "endpoint": "config"],
            ["category": "realm_write", "context": "DownloadManager.persistTask.write"],
            ["category": "realm_write"],
        ])
        XCTAssertEqual(sent()[1].exceptions?.first?.mechanism?.meta?.error?.domain, "io.realm")
        XCTAssertEqual(sent()[1].exceptions?.first?.mechanism?.meta?.error?.code, Realm.Error.Code.fail.rawValue)

        let forged = Event(level: .error)
        forged.tags = ["category": "session_load", "reason": leak, "endpoint": "https://media.example.invalid/config"]
        XCTAssertEqual(SentryTelemetry.allowlisted(forged).tags, ["category": "session_load"])

        forged.tags = ["category": leak]
        forged.exceptions = [Exception(value: leak, type: "NSError")]
        let unlisted = SentryTelemetry.allowlisted(forged)
        XCTAssertNil(unlisted.tags)
        XCTAssertNil(unlisted.exceptions?.first?.value)
    }

    func testRealmOpenFailuresReportOncePerContextWhileCapturing() throws {
        let previous = SentryTelemetry.isCapturing
        addTeardownBlock { SentryTelemetry.isCapturing = previous }
        let missing = Realm.Configuration(
            fileURL: FileManager.default.temporaryDirectory.appending(path: "\(UUID().uuidString).realm"),
            readOnly: true
        )
        let context = "SentryTelemetryTests.open.\(UUID().uuidString.replacingOccurrences(of: "-", with: ""))"

        SentryTelemetry.isCapturing = false
        XCTAssertNil(PutioRealm.open(context: context, configuration: missing))
        let sent = try startRecordingSentEvents()
        allowCapture()
        XCTAssertNil(PutioRealm.open(context: context, configuration: missing))
        XCTAssertNil(PutioRealm.open(context: context, configuration: missing))

        XCTAssertEqual(sent().map(\.tags), [["category": "realm_open", "context": context]])
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

    func testMetricKitDropsDiagnosticsFromBeforeAnOptIn() throws {
        let defaults = try isolatedDefaults()
        let cleared = try isolatedDefaults()
        addTeardownBlock { SentryTelemetry.start(dsn: nil, defaults: cleared) }
        let options = SentryTelemetry.options(dsn: dsn)
        func hang(at timestamp: Date) -> Event {
            let event = Event(level: .warning)
            event.timestamp = timestamp
            let exception = Exception(value: nil, type: "MXHangDiagnostic")
            exception.mechanism = Mechanism(type: "mx_hang_diagnostic")
            event.exceptions = [exception]
            return event
        }
        allowCapture()
        let beforeOptIn = Date()

        SentryTelemetry.update(diagnosticsEnabled: true, dsn: nil, defaults: defaults)
        XCTAssertNotNil(options.beforeSend?(hang(at: beforeOptIn)), "never opted out, so nothing predates consent")

        SentryTelemetry.update(diagnosticsEnabled: false, dsn: nil, defaults: defaults)
        SentryTelemetry.update(diagnosticsEnabled: true, dsn: nil, defaults: defaults)
        XCTAssertNil(options.beforeSend?(hang(at: beforeOptIn)), "a payload from the opt-out window left")
        XCTAssertNotNil(options.beforeSend?(hang(at: Date().addingTimeInterval(1))))
        XCTAssertNotNil(options.beforeSend?(crash(type: "RLMException", reason: nil, handled: false)), "only MetricKit payloads predate consent")
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

    func testBreadcrumbsKeepScreensLifecycleAndPutioRequestsOnly() throws {
        let title = "Synthetic Feature Title"
        let fileName = "Synthetic.Feature.Title.2001.mkv"
        let token = "synthetic-token-5f1c9e"
        func crumb(_ category: String, message: String? = nil, data: [String: Any]) -> Breadcrumb {
            let crumb = Breadcrumb(level: .info, category: category)
            crumb.type = "navigation"
            crumb.message = message
            crumb.data = data
            return crumb
        }
        let trail = [
            crumb("ui.lifecycle", data: [
                "screen": "FilesViewController",
                "parentViewController": "MainTabBarController",
                "title": title,
                "window": "<UIWindow: 0x1; \(title)>"
            ]),
            crumb("ui.lifecycle", data: ["screen": title]),
            crumb("app.lifecycle", data: ["state": "background"]),
            crumb("app.lifecycle", data: ["state": title]),
            crumb("http", data: [
                "url": "https://api.put.io/v2/files/\(fileName)",
                "http.query": "oauth_token=\(token)",
                "method": "GET",
                "status_code": NSNumber(value: 404),
                "reason": title
            ]),
            crumb("http", data: ["url": "https://media.example.invalid/\(fileName)", "method": "GET", "status_code": NSNumber(value: 200)]),
            crumb("touch", message: "playTapped:", data: ["title": title]),
            crumb("device.event", data: ["action": "BATTERY_STATE_CHANGE"]),
            crumb("sentry.event", message: title, data: [:]),
            crumb("putio.\(title)", message: title, data: [:])
        ]

        allowCapture()
        let options = SentryTelemetry.options(dsn: dsn)
        XCTAssertEqual(options.maxBreadcrumbs, 30)
        let beforeBreadcrumb = try XCTUnwrap(options.beforeBreadcrumb)
        let kept = trail.compactMap(beforeBreadcrumb)
        func sentTrail(_ breadcrumbs: [Breadcrumb]) throws -> [Breadcrumb] {
            let event = Event(level: .error)
            event.breadcrumbs = breadcrumbs
            return try XCTUnwrap(options.beforeSend?(event)).breadcrumbs ?? []
        }

        for crumbs in try [kept, sentTrail(kept), sentTrail(trail)] {
            let json = String(decoding: try JSONSerialization.data(withJSONObject: crumbs.map { $0.serialize() }), as: UTF8.self)
            for leaked in [title, fileName, token, "/v2/files", "media.example.invalid", "playTapped"] {
                XCTAssertFalse(json.contains(leaked), "\(leaked) left the device: \(json)")
            }
            XCTAssertEqual(crumbs.map(\.category), ["ui.lifecycle", "app.lifecycle", "http"])
            XCTAssertEqual(crumbs.first?.data as? [String: String], ["screen": "FilesViewController", "parentViewController": "MainTabBarController"])
            XCTAssertEqual(crumbs.last?.data?["host"] as? String, "api.put.io")
            XCTAssertEqual(crumbs.last?.data?["method"] as? String, "GET")
            XCTAssertEqual(crumbs.last?.data?["status_code"] as? Int, 404)
        }

        SentryTelemetry.isCapturing = false
        XCTAssertNil(beforeBreadcrumb(trail[0]), "a breadcrumb was kept while diagnostics were off")
    }

    func testSampledTimingsSendOnlyStaticTransactions() throws {
        let fileName = "Synthetic.Feature.Title.2001.mkv"
        let url = "https://api.put.io/v2/files/list?oauth_token=synthetic-token-5f1c9e"
        let options = SentryTelemetry.options(dsn: dsn)
        XCTAssertEqual(options.tracesSampleRate?.doubleValue, 0.1)
        for interval in SentryTelemetry.Interval.allCases {
            XCTAssertEqual("\(interval.signpostName)", interval.rawValue)
        }
        for traced in [options.enableAutoPerformanceTracing, options.enableNetworkTracking, options.enableFileIOTracing, options.enableCoreDataTracing, options.enableUIViewControllerTracing, options.enableUserInteractionTracing] {
            XCTAssertFalse(traced)
        }
        XCTAssertTrue(options.tracePropagationTargets.isEmpty)

        let sent = try startRecordingSentEvents(tracesSampleRate: 1)
        allowCapture()
        SentrySDK.configureScope { scope in
            scope.setTag(value: fileName, key: "file")
            scope.setExtra(value: url, key: "url")
            scope.setContext(value: ["url": url], key: "request")
        }

        SentrySDK.startTransaction(name: url, operation: "http.client").finish()
        let withSpan = SentrySDK.startTransaction(name: SentryTelemetry.Interval.filesFetch.rawValue, operation: SentryTelemetry.Interval.filesFetch.operation)
        withSpan.startChild(operation: "file.read", description: fileName).finish()
        withSpan.finish()
        let withData = SentrySDK.startTransaction(name: SentryTelemetry.Interval.fetchUser.rawValue, operation: SentryTelemetry.Interval.fetchUser.operation)
        withData.setData(value: url, key: "url")
        withData.finish()

        for interval in SentryTelemetry.Interval.allCases {
            PerfSignpost.end(PerfSignpost.begin(interval), outcome: interval == .playbackStart ? .failed : .succeeded)
        }

        let transactions = { sent().filter { $0.type == "transaction" } }
        let arrived = expectation(for: NSPredicate { _, _ in transactions().count >= SentryTelemetry.Interval.allCases.count }, evaluatedWith: nil)
        wait(for: [arrived], timeout: 10)
        drainMainQueue()

        let payloads = transactions().map { $0.serialize() }
        XCTAssertEqual(Set(payloads.compactMap { $0["transaction"] as? String }), Set(SentryTelemetry.Interval.allCases.map(\.rawValue)))
        XCTAssertEqual(payloads.count, SentryTelemetry.Interval.allCases.count, "an unlisted transaction left the device")
        for payload in payloads {
            let json = String(decoding: try JSONSerialization.data(withJSONObject: payload), as: UTF8.self)
            for leaked in [fileName, url, "api.put.io", "oauth_token", "thread.name"] {
                XCTAssertFalse(json.contains(leaked), "\(leaked) left the device: \(json)")
            }
            let interval = try XCTUnwrap((payload["transaction"] as? String).flatMap(SentryTelemetry.Interval.init(rawValue:)))
            let trace = try XCTUnwrap((payload["contexts"] as? [String: Any])?["trace"] as? [String: Any])
            XCTAssertEqual(trace["op"] as? String, interval.operation)
            XCTAssertEqual(trace["status"] as? String, interval == .playbackStart ? "internal_error" : "ok")
            XCTAssertEqual((payload["spans"] as? [Any])?.count ?? 0, 0)
            XCTAssertEqual(Set(((payload["user"] as? [String: Any]) ?? [:]).keys), ["id"])
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

    private func cacheEnvelope() throws {
        let pending = SentryTelemetry.cacheDirectory.appending(path: "envelopes/pending")
        try FileManager.default.createDirectory(at: pending.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("synthetic".utf8).write(to: pending)
    }


    private func startRecordingSentEvents(tracesSampleRate: Double? = nil) throws -> () -> [Event] {
        let defaults = try isolatedDefaults()
        addTeardownBlock { SentryTelemetry.update(diagnosticsEnabled: false, dsn: self.dsn, defaults: defaults) }
        let options = SentryTelemetry.options(dsn: dsn)
        tracesSampleRate.map { options.tracesSampleRate = NSNumber(value: $0) }
        let beforeSend = try XCTUnwrap(options.beforeSend)
        let sent = OSAllocatedUnfairLock(initialState: [Event]())
        options.beforeSend = { event in
            if let kept = beforeSend(event) { sent.withLock { $0.append(kept) } }
            return nil
        }
        SentrySDK.start(options: options)
        return { sent.withLock { $0 } }
    }

    private func isolatedDefaults() throws -> UserDefaults {
        let suite = "SentryTelemetryTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        return defaults
    }

    private func drainMainQueue() {
        let drained = expectation(description: "main queue drained")
        DispatchQueue.main.async { drained.fulfill() }
        wait(for: [drained], timeout: 5)
    }

    private func allowCapture() {
        let previous = SentryTelemetry.isCapturing
        SentryTelemetry.isCapturing = true
        addTeardownBlock { SentryTelemetry.isCapturing = previous }
    }
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
