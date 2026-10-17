import AVFoundation
import os
import PostHog
import PutioSDK
import XCTest
@testable import Putio

final class ProductAnalyticsTests: XCTestCase {
    private let title = "Synthetic Feature Title"
    private let fileName = "Synthetic.Feature.Title.2001.mkv"
    private let host = "media.example.invalid"
    private let token = "synthetic-token-5f1c9e"
    private let email = "someone@example.invalid"
    private let address = "203.0.113.7"
    private var leaks: [String] { [title, fileName, host, token, email, address] }
    private var leak: String { "\(title) /Documents/\(fileName) https://\(host)/hls/master.m3u8?oauth_token=\(token) \(email) \(address)" }

    /// What the SDK adds to an event before `beforeSend`, from PostHogContext
    /// and PostHogSDK.buildProperties in 3.92.0.
    private let sdkKeys = [
        "$app_name", "$app_version", "$app_build", "$app_namespace", "$is_testflight", "$is_sideloaded",
        "$device_manufacturer", "$device_model", "$device_type", "$device_name", "$is_emulator",
        "$is_ios_running_on_mac", "$is_mac_catalyst_app", "$os_name", "$os_version", "$screen_width",
        "$screen_height", "$hinge_status", "$locale", "$timezone", "$network_wifi", "$network_cellular",
        "$lib", "$lib_version", "$session_id", "$is_identified", "$process_person_profile", "$geoip_disable",
        "$recording_status", "$feature/synthetic", "$active_feature_flags", "$groups", "$screen_name",
        "$set", "$set_once", "$ip", "$anon_distinct_id", "$device_id", "$current_url"
    ]

    override func setUp() {
        super.setUp()
        RecordingURLProtocol.reset()
    }

    // MARK: - Allowlist

    func testOnlyContractFieldsSurviveTheAllowlist() throws {
        var properties: [String: Any] = [leak: leak]
        for key in sdkKeys + ["file_name", "title", "url", "search", "magnet", "oauth_token", "error", "email"] {
            properties[key] = leak
        }
        properties.merge(validSDKProperties) { $1 }
        properties.merge(ProductAnalyticsGate.commonProperties()) { $1 }
        properties["screen"] = "files"

        let kept = try XCTUnwrap(AnalyticsAllowlist.allowedProperties(event: "screen_viewed", properties: properties))
        let json = String(decoding: try JSONSerialization.data(withJSONObject: kept), as: UTF8.self)

        for leaked in leaks {
            XCTAssertFalse(json.contains(leaked), "\(leaked) survived: \(json)")
        }
        XCTAssertEqual(Set(kept.keys), contractKeys(for: "screen_viewed"))
    }

    func testEventsOutsideTheContractAreDropped() {
        for name in [
            "$screen", "$identify", "$set", "$exception", "$feature_flag_called", "$pageview", "$autocapture",
            "$rageclick", "Application Opened", "Application Installed", "$push_notification_opened",
            "$snapshot", "survey shown", "page_viewed", "transfer_added", "registration_completed"
        ] {
            XCTAssertNil(AnalyticsAllowlist.allowedProperties(event: name, properties: validSDKProperties), name)
        }
    }

    func testOffListValuesAreDropped() throws {
        let cases: [(event: String, key: String, value: Any)] = [
            ("screen_viewed", "screen", "https://put.io/files/1"),
            ("screen_viewed", "screen", email),
            ("screen_viewed", "app", "magnet:?xt=urn:btih:synthetic"),
            ("screen_viewed", "app_version", "https://put.io/"),
            ("screen_viewed", "runtime_version", "26.4 (\(title))"),
            ("screen_viewed", "auth_state", "anonymous"),
            ("screen_viewed", "screen", true),
            ("settings_changed", "setting", "product_analytics_enabled"),
            ("settings_changed", "setting", "diagnostics_enabled"),
            ("settings_changed", "value_class", "true"),
            ("playback_failed", "error_class", "The operation couldn't be completed. (\(host))"),
            ("screen_viewed", "$lib", leak),
            ("screen_viewed", "$lib_version", leak),
            ("screen_viewed", "$session_id", leak),
            ("screen_viewed", "$is_identified", leak),
            ("screen_viewed", "$geoip_disable", false)
        ]
        for (event, key, value) in cases {
            let kept = try XCTUnwrap(AnalyticsAllowlist.allowedProperties(event: event, properties: [key: value]))
            XCTAssertNil(kept[key], "\(event).\(key) kept \(value)")
        }
    }

    func testEveryTypedEventSurvivesTheAllowlistUnchanged() throws {
        for event in allEvents {
            let properties = ProductAnalyticsGate.commonProperties().merging(event.properties) { $1 }
            let kept = try XCTUnwrap(AnalyticsAllowlist.allowedProperties(event: event.name, properties: properties), event.name)
            XCTAssertEqual(kept as? [String: String], properties, "\(event) is not on the allowlist")
        }
    }

    // MARK: - The SDK

    func testBeforeSendStripsWhatTheSDKAndCallersAddOnTheWire() throws {
        let (gate, token) = makeGate()
        gate.update(accountID: 1001, productAnalyticsEnabled: true)
        var leaky: [String: Any] = [leak: leak, "screen": "files", "title": title, "url": leak, "$set": ["email": email]]
        for key in sdkKeys where !validSDKProperties.keys.contains(key) {
            leaky[key] = leak
        }

        try XCTUnwrap(gate.runningSDK).capture("screen_viewed", properties: leaky)
        let events = try waitForEvents(token: token, count: 1)

        let event = try XCTUnwrap(events.first)
        let body = String(decoding: try JSONSerialization.data(withJSONObject: event), as: UTF8.self)
        for leaked in leaks {
            XCTAssertFalse(body.contains(leaked), "\(leaked) left the device: \(body)")
        }
        XCTAssertEqual(event["event"] as? String, "screen_viewed")
        XCTAssertEqual(event["distinct_id"] as? String, "1001")
        let properties = try XCTUnwrap(event["properties"] as? [String: Any])
        XCTAssertEqual(properties["screen"] as? String, "files")
        XCTAssertTrue(Set(properties.keys).isSubset(of: contractKeys(for: "screen_viewed")), "\(properties.keys)")
    }

    // MARK: - The gate

    func testNoRequestBeforeSignInWithTheAnswerUnsetOrOff() throws {
        let (gate, token) = makeGate()
        gate.capture(.appOpened(.direct))

        for (accountID, enabled) in [(nil, nil), (1001, nil), (1001, false)] as [(Int?, Bool?)] {
            gate.update(accountID: accountID, productAnalyticsEnabled: enabled)
            allEvents.forEach(gate.capture)
            gate.settingDidSave(enabled: false)
        }
        spinRunLoop(seconds: 1)

        XCTAssertEqual(requests(token: token).map(\.url), [])
        XCTAssertNil(gate.runningSDK)
        XCTAssertFalse(FileManager.default.fileExists(atPath: gate.storageDirectory(token: token).path))

        gate.update(accountID: 1001, productAnalyticsEnabled: true)
        gate.capture(.supportStarted)
        let events = try waitForEvents(token: token, count: 1)
        XCTAssertEqual(events.map { $0["event"] as? String }, ["support_started"], "an event from before the answer was sent")
    }

    func testOptInIdentifiesWithTheAccountIDWithoutIdentifyOrFlags() throws {
        let (gate, token) = makeGate()
        gate.capture(.appOpened(.direct))

        gate.update(accountID: 1001, productAnalyticsEnabled: true)
        _ = try waitForEvents(token: token, count: 1)
        gate.capture(.screenViewed(.files))
        let events = try waitForEvents(token: token, count: 2)

        XCTAssertEqual(events.map { $0["event"] as? String }, ["app_opened", "screen_viewed"])
        XCTAssertEqual(Set(events.map { $0["distinct_id"] as? String }), ["1001"])
        let paths = requests(token: token).compactMap(\.url?.path)
        XCTAssertTrue(paths.contains("/array/\(token)/config"), "\(paths)")
        XCTAssertTrue(paths.contains("/batch"), "\(paths)")
        XCTAssertFalse(paths.contains { $0.hasPrefix("/flags") || $0.contains("push_subscriptions") }, "\(paths)")
        XCTAssertTrue(requests(token: token).allSatisfy { $0.url?.host == "burrow.put.io" })
        let properties = try XCTUnwrap(events.last?["properties"] as? [String: Any])
        XCTAssertEqual(properties["app"] as? String, "ios")
        XCTAssertEqual(properties["auth_state"] as? String, "signed_in")
        XCTAssertEqual(properties["$geoip_disable"] as? Bool, true)
    }

    func testOptOutStopsCaptureAndDeletesEverythingTheSDKStored() throws {
        let (gate, token) = makeGate()
        gate.update(accountID: 1001, productAnalyticsEnabled: true)
        gate.capture(.screenViewed(.files))
        _ = try waitForEvents(token: token, count: 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: gate.storageDirectory(token: token).path))

        gate.settingDidSave(enabled: false)
        let sent = requests(token: token).count
        allEvents.forEach(gate.capture)
        spinRunLoop(seconds: 1)

        XCTAssertEqual(requests(token: token).count, sent, "a request left after the opt-out")
        XCTAssertFalse(gate.isCapturing)
        XCTAssertNil(gate.runningSDK)
        XCTAssertFalse(FileManager.default.fileExists(atPath: gate.storageDirectory(token: token).path))
        XCTAssertNil(UserDefaults.standard.object(forKey: "PHGVersionKey"))
        XCTAssertNil(UserDefaults.standard.object(forKey: "PHGBuildKeyV2"))
    }

    func testSwitchingAccountsStartsAFreshIdentity() throws {
        let (gate, token) = makeGate()
        gate.update(accountID: 1001, productAnalyticsEnabled: true)
        let first = try XCTUnwrap(gate.runningSDK)
        let (firstDevice, firstAnonymous) = (first.getDeviceId(), first.getAnonymousId())
        gate.capture(.screenViewed(.files))
        _ = try waitForEvents(token: token, count: 1)

        gate.update(accountID: 1002, productAnalyticsEnabled: true)
        let second = try XCTUnwrap(gate.runningSDK)
        gate.capture(.screenViewed(.account))
        let events = try waitForEvents(token: token, count: 2)

        XCTAssertFalse(first === second)
        XCTAssertEqual(second.getDistinctId(), "1002")
        XCTAssertNotEqual(second.getDeviceId(), firstDevice)
        XCTAssertNotEqual(second.getAnonymousId(), firstAnonymous)
        XCTAssertEqual(events.map { $0["distinct_id"] as? String }, ["1001", "1002"])
        XCTAssertFalse(events.contains { $0["event"] as? String == "$identify" })
    }

    func testAForegroundHoldsEventsUntilTheRefreshAnswers() throws {
        let (gate, token) = makeGate()
        gate.update(accountID: 1001, productAnalyticsEnabled: true)
        gate.capture(.screenViewed(.files))
        _ = try waitForEvents(token: token, count: 1)

        gate.awaitAnswer()
        gate.capture(.appOpened(.resume))
        spinRunLoop(seconds: 1)
        XCTAssertEqual(sentEvents(token: token).count, 1, "an open left before the refresh answered")
        gate.keepAnswer()
        _ = try waitForEvents(token: token, count: 2)

        // Turned off on another device while the app was away.
        gate.awaitAnswer()
        gate.capture(.appOpened(.resume))
        gate.update(accountID: 1001, productAnalyticsEnabled: false)
        spinRunLoop(seconds: 1)

        XCTAssertEqual(sentEvents(token: token).map { $0["event"] as? String }, ["screen_viewed", "app_opened"])
    }

    func testAHeldEventKeepsTheTimeItHappened() throws {
        let opened = Date(timeIntervalSince1970: floor(Date().timeIntervalSince1970) - 600)
        var clock = opened
        let (gate, token) = makeGate(now: { clock })

        // The cold launch's open, then ten minutes offline before the account answers.
        gate.capture(.appOpened(.direct))
        clock += 600
        gate.update(accountID: 1001, productAnalyticsEnabled: true)
        _ = try waitForEvents(token: token, count: 1)
        gate.capture(.screenViewed(.files))
        let events = try waitForEvents(token: token, count: 2)

        XCTAssertEqual(events.map { ($0["timestamp"] as? String).flatMap(toISO8601Date) }, [opened, clock])
    }

    func testABackgroundWithoutAnOpenSinceTheStartIsDropped() throws {
        let (gate, token) = makeGate()
        gate.update(accountID: 1001, productAnalyticsEnabled: true)

        // The foreground began before the opt-in, so its length isn't the account's to send.
        gate.capture(.appBackgrounded(.over60m))
        gate.capture(.appOpened(.resume))
        _ = try waitForEvents(token: token, count: 1)
        gate.capture(.appBackgrounded(.under1m))
        let events = try waitForEvents(token: token, count: 2)

        XCTAssertEqual(events.map { $0["event"] as? String }, ["app_opened", "app_backgrounded"])
        XCTAssertEqual((events.last?["properties"] as? [String: Any])?["session_duration"] as? String, "lt_1m")
    }

    func testStorageThatCannotBeDeletedKeepsTheGateClosed() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "ProductAnalyticsTests-\(UUID().uuidString)")
        let token = "phc_\(UUID().uuidString.replacingOccurrences(of: "-", with: ""))"
        try FileManager.default.createDirectory(at: root.appending(path: token), withIntermediateDirectories: true)
        // A read-only parent keeps its token folder from being removed.
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: root.path)
        addTeardownBlock {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: root.path)
            try? FileManager.default.removeItem(at: root)
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RecordingURLProtocol.self]
        let gate = ProductAnalyticsGate(environment: .init(
            token: token, isEligible: true, storageDirectory: root, urlSessionConfiguration: configuration, compression: .none
        ))
        addTeardownBlock { gate.update(accountID: nil, productAnalyticsEnabled: nil) }

        gate.update(accountID: 1001, productAnalyticsEnabled: true)
        gate.capture(.screenViewed(.files))
        spinRunLoop(seconds: 1)

        XCTAssertNil(gate.runningSDK)
        XCTAssertEqual(requests(token: token).map(\.url), [])
    }

    func testASaveThatOutlivesItsSessionSendsNothing() throws {
        let (gate, token) = makeGate()
        gate.update(accountID: 1001, productAnalyticsEnabled: true)
        let session = AccountNoticeStore.shared.session

        // What signing out, then signing in again, does to the session.
        AccountNoticeStore.shared.clear()
        gate.capture(.settingsChanged(.sortBy, .option), startedIn: session)
        gate.capture(.screenViewed(.files), startedIn: AccountNoticeStore.shared.session)
        let events = try waitForEvents(token: token, count: 1)

        XCTAssertEqual(events.map { $0["event"] as? String }, ["screen_viewed"])
    }

    func testAStartAfterAKilledLaunchDropsItsIdentity() throws {
        let (killed, token) = makeGate()
        killed.update(accountID: 1001, productAnalyticsEnabled: true)
        // As if the process died while capturing: the SDK's storage stays behind.
        try XCTUnwrap(killed.runningSDK).close()

        let (relaunched, _) = makeGate(token: token)
        relaunched.update(accountID: 1002, productAnalyticsEnabled: true)
        relaunched.capture(.screenViewed(.files))
        let events = try waitForEvents(token: token, count: 1)

        XCTAssertEqual(events.map { $0["distinct_id"] as? String }, ["1002"])
    }

    func testOnlyAPublicProjectTokenInTheAppStoreAppStartsTheSDK() throws {
        XCTAssertEqual(ProductAnalytics.projectToken("phc_SyntheticToken0123456789"), "phc_SyntheticToken0123456789")
        for unusable in ["", "$(PUTIO_POSTHOG_TOKEN)", "phc_", "phc_short", "phx_SyntheticToken0123456789", "phc_Synthetic Token 0123456789"] {
            XCTAssertNil(ProductAnalytics.projectToken(unusable), unusable)
        }
        XCTAssertNil(POSTHOG_PROJECT_TOKEN, "a Debug build carries a project token")

        XCTAssertTrue(ProductAnalytics.isEligible(bundleIdentifier: "com.putio.tvOS", isMockAPIEnabled: false, isRunningUnitTests: false))
        XCTAssertFalse(ProductAnalytics.isEligible(bundleIdentifier: "io.put.dev", isMockAPIEnabled: false, isRunningUnitTests: false))
        XCTAssertFalse(ProductAnalytics.isEligible(bundleIdentifier: "com.putio.tvOS", isMockAPIEnabled: true, isRunningUnitTests: false))
        XCTAssertFalse(ProductAnalytics.isEligible(bundleIdentifier: "com.putio.tvOS", isMockAPIEnabled: false, isRunningUnitTests: true))
        XCTAssertFalse(ProductAnalyticsGate.Environment.live.isEligible)

        for (gate, token) in [makeGate(token: nil), makeGate(eligible: false)] {
            gate.update(accountID: 1001, productAnalyticsEnabled: true)
            allEvents.forEach(gate.capture)
            XCTAssertNil(gate.runningSDK)
            spinRunLoop(seconds: 0.5)
            XCTAssertEqual(requests(token: token).map(\.url), [])
        }
    }

    // MARK: - Event sources

    func testScenesOpenOnceAndTimeTheSession() {
        var events: [AnalyticsEvent] = []
        var clock = Date(timeIntervalSince1970: 0)
        let session = AppSessionAnalytics(capture: { events.append($0) }, now: { clock })

        session.didOpenLink()
        session.willEnterForeground()
        session.didBecomeActive()
        session.didBecomeActive()
        clock += 400
        session.didEnterBackground()
        session.willEnterForeground()
        session.didBecomeActive()
        // A cold-launch link replays once the account loads, after the open it marked.
        session.didOpenLink()
        clock += 30
        session.didEnterBackground()
        session.willEnterForeground()
        session.didBecomeActive()

        XCTAssertEqual(events, [
            .appOpened(.deeplink), .appBackgrounded(.from5mTo15m), .appOpened(.resume), .appBackgrounded(.under1m), .appOpened(.resume)
        ])
    }

    func testPlaybackStartsOnceAndEndsOrFailsOnce() {
        var events: [AnalyticsEvent] = []
        var clock = Date(timeIntervalSince1970: 0)
        let video = AnalyticsEvent.Playback(media: .video, streamMethod: .hls, player: .native)
        let closedEarly = PlaybackAnalytics(video, capture: { events.append($0) }, now: { clock })
        closedEarly.end()
        closedEarly.start()

        let playback = PlaybackAnalytics(video, capture: { events.append($0) }, now: { clock })
        playback.start()
        playback.start()
        clock += 2000
        playback.didReachEnd()
        // The finished player stays open for an hour before it closes.
        clock += 3600
        playback.end()
        playback.fail(URLError(.timedOut))

        let closed = PlaybackAnalytics(video, capture: { events.append($0) }, now: { clock })
        closed.start()
        closed.end()

        let failing = PlaybackAnalytics(video, capture: { events.append($0) }, now: { clock })
        failing.fail(NSError(domain: AVFoundationErrorDomain, code: -11800, userInfo: [NSLocalizedDescriptionKey: fileName]))
        failing.start()
        failing.end()

        XCTAssertEqual(events, [
            .playbackStarted(video), .playbackEnded(video, .completed, .from30mTo90m),
            .playbackStarted(video), .playbackEnded(video, .partial, .under5m),
            .playbackFailed(video, .media)
        ])
        XCTAssertEqual(AnalyticsEvent.PlaybackError(PutioSDKError.offline("/files/1")), .network)
        XCTAssertEqual(AnalyticsEvent.PlaybackError(URLError(.timedOut)), .network)
        XCTAssertEqual(AnalyticsEvent.PlaybackError(NSError(domain: "Missing Metadata", code: 0)), .unknown)
    }

    // MARK: - Helpers

    private var validSDKProperties: [String: Any] {
        [
            "$lib": "posthog-ios", "$lib_version": "3.92.0", "$session_id": UUID().uuidString,
            "$is_identified": true, "$process_person_profile": true, "$geoip_disable": true
        ]
    }

    private func contractKeys(for event: String) -> Set<String> {
        Set(AnalyticsAllowlist.sdkProperties.keys)
            .union(AnalyticsAllowlist.commonProperties.keys)
            .union(AnalyticsAllowlist.patternProperties.keys)
            .union(AnalyticsAllowlist.eventProperties[event].map { Array($0.keys) } ?? [])
    }

    private var allEvents: [AnalyticsEvent] {
        let playbacks = AnalyticsEvent.Media.allCases.flatMap { media in
            AnalyticsEvent.StreamMethod.allCases.flatMap { method in
                AnalyticsEvent.Player.allCases.map { AnalyticsEvent.Playback(media: media, streamMethod: method, player: $0) }
            }
        }
        var events: [AnalyticsEvent] = [.supportStarted]
        events += AnalyticsEvent.Entry.allCases.map(AnalyticsEvent.appOpened)
        events += AnalyticsEvent.SessionDuration.allCases.map(AnalyticsEvent.appBackgrounded)
        events += AnalyticsEvent.Screen.allCases.map(AnalyticsEvent.screenViewed)
        for setting in AnalyticsEvent.Setting.allCases {
            events += AnalyticsEvent.ValueClass.allCases.map { AnalyticsEvent.settingsChanged(setting, $0) }
        }
        for playback in playbacks {
            events.append(.playbackStarted(playback))
            for completion in AnalyticsEvent.Completion.allCases {
                events += AnalyticsEvent.PlaybackDuration.allCases.map { AnalyticsEvent.playbackEnded(playback, completion, $0) }
            }
            events += AnalyticsEvent.PlaybackError.allCases.map { AnalyticsEvent.playbackFailed(playback, $0) }
        }
        return events
    }

    /// A gate on a project token of its own, so no other test's SDK, requests,
    /// or storage are in the way.
    private func makeGate(
        token: String? = "phc_\(UUID().uuidString.replacingOccurrences(of: "-", with: ""))",
        eligible: Bool = true,
        now: @escaping () -> Date = Date.init
    ) -> (ProductAnalyticsGate, String) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RecordingURLProtocol.self]
        let gate = ProductAnalyticsGate(environment: .init(
            token: token,
            isEligible: eligible,
            storageDirectory: URL.applicationSupportDirectory.appending(path: Bundle.main.bundleIdentifier ?? ""),
            urlSessionConfiguration: configuration,
            compression: .none,
            now: now
        ))
        addTeardownBlock { gate.update(accountID: nil, productAnalyticsEnabled: nil) }
        return (gate, token ?? "phc_none")
    }

    private func requests(token: String) -> [RecordingURLProtocol.Request] {
        RecordingURLProtocol.requests.filter { request in
            request.url?.path.contains(token) == true || (request.json?["api_key"] as? String) == token
        }
    }

    private func sentEvents(token: String) -> [[String: Any]] {
        requests(token: token).flatMap { $0.json?["batch"] as? [[String: Any]] ?? [] }
    }

    private func waitForEvents(token: String, count: Int, timeout: TimeInterval = 10) throws -> [[String: Any]] {
        let deadline = Date().addingTimeInterval(timeout)
        while sentEvents(token: token).count < count, Date() < deadline {
            spinRunLoop(seconds: 0.05)
        }
        let sent = sentEvents(token: token)
        XCTAssertEqual(sent.count, count, "\(requests(token: token).map(\.url))")
        return sent
    }

    private func spinRunLoop(seconds: TimeInterval) {
        RunLoop.current.run(until: Date().addingTimeInterval(seconds))
    }
}

/// Stands in for burrow.put.io: records each request with its body.
private final class RecordingURLProtocol: URLProtocol {
    struct Request {
        let url: URL?
        let body: Data?

        var json: [String: Any]? {
            body.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        }
    }

    private static let recorded = OSAllocatedUnfairLock(uncheckedState: [Request]())

    static var requests: [Request] {
        recorded.withLock { $0 }
    }

    static func reset() {
        recorded.withLock { $0.removeAll() }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let recorded = Request(url: request.url, body: request.httpBody ?? request.httpBodyStream.map(Self.read))
        Self.recorded.withLock { $0.append(recorded) }
        guard let url = request.url,
              let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])
        else { return }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(url.path.hasSuffix("/config") ? #"{"hasFeatureFlags":false}"#.utf8 : #"{"status":"Ok"}"#.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    private static func read(_ stream: InputStream) -> Data {
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 16_384)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            guard count > 0 else { break }
            data.append(buffer, count: count)
        }
        return data
    }
}
