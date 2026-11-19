import AVFoundation
import Foundation
import GoogleCast
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
        case internalFailure = "internal_failure"
        case pushRegistration = "push_registration"
        case realmOpen = "realm_open"
        case realmWrite = "realm_write"
        case sessionLoad = "session_load"
        case supportLogin = "support_login"
        case unplayableOfflineDownload = "unplayable_offline_download"
        case unplayableOfflineVideo = "unplayable_offline_video"
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

    enum Interval: String, CaseIterable {
        case fetchUser = "FetchUser"
        case filesFetch = "FilesFetch"
        case playbackStart = "PlaybackStart"
        case downloadStart = "DownloadStart"

        var operation: String {
            switch self {
            case .fetchUser: return "putio.fetch_user"
            case .filesFetch: return "putio.files_fetch"
            case .playbackStart: return "putio.playback_start"
            case .downloadStart: return "putio.download_start"
            }
        }
    }

    enum Outcome {
        case succeeded, failed, cancelled
    }

    enum Action: CaseIterable {
        case tabSelected(MainTabBarController.Tab)

        static var allCases: [Action] { MainTabBarController.Tab.allCases.map(Action.tabSelected) }

        fileprivate var category: String {
            switch self {
            case .tabSelected: return "putio.tab"
            }
        }

        fileprivate var message: String {
            switch self {
            case .tabSelected: return "Selected tab"
            }
        }

        fileprivate var data: [String: String] {
            switch self {
            case .tabSelected(.files): return ["tab": "files"]
            case .tabSelected(.history): return ["tab": "history"]
            case .tabSelected(.downloads): return ["tab": "downloads"]
            case .tabSelected(.account): return ["tab": "settings"]
            }
        }

        fileprivate func breadcrumb(at timestamp: Date?) -> Breadcrumb {
            let sent = Breadcrumb(level: .info, category: category)
            sent.type = "user"
            sent.message = message
            sent.timestamp = timestamp
            for (key, value) in data { sent.setData(value: value, key: key) }
            return sent
        }
    }

    struct Timing {
        fileprivate let span: Sentry.Span?
    }

    private static let tracesSampleRate = 0.1

    private static func isContext(_ value: String) -> Bool {
        (1...80).contains(value.count) && value.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "." || $0 == "_") }
    }

    /// The put.io "Playback failure reports" event, schema 2. This app has no
    /// rescue path and no `media_info`, so every report is a terminal failure
    /// and every media fact is `unknown`.
    struct PlaybackFailure {
        static let event = "playback_failure"
        static let schemaVersion = "2"
        static let platform = "ios"
        static let outcome = "failed"
        static let notApplicable = "none"
        static let unknown = "unknown"

        enum SourceKind: String, CaseIterable {
            case hls, converted, original
            case localFile = "local_file"
        }

        enum StreamingMethod: String, CaseIterable {
            case hls, file
        }

        enum DeviceCheck: String, CaseIterable {
            case pass, fail, skipped
        }

        enum Mode: String, CaseIterable {
            case network, load, decode, drm, aborted, unknown
            case sourceGone = "source_gone"
            case unsupportedSource = "unsupported_source"

            init(_ error: NSError?) {
                guard let error else {
                    self = .unknown
                    return
                }
                switch error.domain {
                case NSURLErrorDomain: self.init(urlCode: URLError.Code(rawValue: error.code))
                case AVFoundationErrorDomain: self.init(avCode: AVError.Code(rawValue: error.code))
                case ErrorDomain.coreMedia.rawValue: self = .load
                case NSCocoaErrorDomain:
                    self = [CocoaError.fileNoSuchFile.rawValue, CocoaError.fileReadNoSuchFile.rawValue].contains(error.code) ? .sourceGone : .unknown
                case NSPOSIXErrorDomain: self.init(posixCode: Int32(exactly: error.code).flatMap(POSIXErrorCode.init(rawValue:)))
                case kGCKErrorDomain: self.init(castCode: GCKErrorCode(rawValue: error.code))
                default: self = .unknown
                }
            }

            private init(urlCode: URLError.Code) {
                switch urlCode {
                case .cancelled: self = .aborted
                case .fileDoesNotExist: self = .sourceGone
                case .notConnectedToInternet, .networkConnectionLost, .timedOut, .cannotFindHost, .cannotConnectToHost,
                     .dnsLookupFailed, .internationalRoamingOff, .dataNotAllowed, .callIsActive, .secureConnectionFailed:
                    self = .network
                default: self = .load
                }
            }

            private init(avCode: AVError.Code?) {
                switch avCode {
                case .decodeFailed?, .decoderNotFound?, .decoderTemporarilyUnavailable?: self = .decode
                case .fileFormatNotRecognized?, .fileFailedToParse?: self = .unsupportedSource
                case .contentIsProtected?, .contentIsNotAuthorized?: self = .drm
                case .operationInterrupted?: self = .aborted
                case .failedToLoadMediaData?, .serverIncorrectlyConfigured?: self = .load
                default: self = .unknown
                }
            }

            private init(posixCode: POSIXErrorCode?) {
                switch posixCode {
                case .ENOENT?: self = .sourceGone
                case .ECONNRESET?, .ECONNABORTED?, .ECONNREFUSED?, .ETIMEDOUT?, .ENETDOWN?, .ENETUNREACH?, .EHOSTUNREACH?, .ENOTCONN?, .EPIPE?:
                    self = .network
                default: self = .unknown
                }
            }

            private init(castCode: GCKErrorCode?) {
                switch castCode {
                case .networkError?, .timeout?, .networkNotReachable?, .channelNotConnected?, .deviceNotConnected?, .disconnected?:
                    self = .network
                case .mediaLoadFailed?, .mediaError?: self = .load
                case .invalidRequest?, .unsupportedFeature?, .deviceCapabilityNotSupported?: self = .unsupportedSource
                case .cancelled?, .replaced?: self = .aborted
                default: self = .unknown
                }
            }
        }

        enum Tag: String, CaseIterable {
            case telemetryEvent = "telemetry_event"
            case schemaVersion = "schema_version"
            case platform, player
            case playbackOutcome = "playback_outcome"
            case playbackTerminal = "playback_terminal"
            case playbackStarted = "playback_started"
            case failureMode = "failure_mode"
            case streamingMethod = "streaming_method"
            case sourceKind = "source_kind"
            case deviceCheck = "device_check"
            case rescueReason = "rescue_reason"
            case rescueTo = "rescue_to"
            case engineErrorDomain = "engine_error_domain"
            case engineErrorCategory = "engine_error_category"
            case engineErrorCode = "engine_error_code"
            case sourceRequestStatus = "source_request_status"
            case fileID = "file_id"
            case containerFamily = "container_family"
            case videoCodec = "video_codec"
            case videoProfile = "video_profile"
            case videoLevel = "video_level"
            case videoBitDepth = "video_bit_depth"
            case videoResolution = "video_resolution"
            case videoHDR = "video_hdr"
            case audioCodec = "audio_codec"
            case audioChannels = "audio_channels"

            static let mediaFacts: [Tag] = [
                .containerFamily, .videoCodec, .videoProfile, .videoLevel, .videoBitDepth, .videoResolution, .videoHDR, .audioCodec, .audioChannels
            ]

            func allows(_ value: String) -> Bool {
                switch self {
                case .telemetryEvent: return value == PlaybackFailure.event
                case .schemaVersion: return value == PlaybackFailure.schemaVersion
                case .platform: return value == PlaybackFailure.platform
                case .player: return AnalyticsEvent.Player(rawValue: value) != nil
                case .playbackOutcome: return value == PlaybackFailure.outcome
                case .playbackTerminal: return value == String(true)
                case .playbackStarted: return Bool(value) != nil
                case .failureMode: return Mode(rawValue: value) != nil
                case .streamingMethod: return StreamingMethod(rawValue: value) != nil
                case .sourceKind: return SourceKind(rawValue: value) != nil
                case .deviceCheck: return DeviceCheck(rawValue: value) != nil
                case .rescueReason, .rescueTo, .engineErrorCategory: return value == PlaybackFailure.notApplicable
                case .engineErrorDomain: return ErrorDomain(rawValue: value) != nil
                case .engineErrorCode: return value == PlaybackFailure.notApplicable || Int(value).map(String.init) == value
                case .sourceRequestStatus: return value == PlaybackFailure.notApplicable || value == PlaybackFailure.unknown
                case .fileID: return Int(value).map { $0 > 0 && String($0) == value } == true
                case .containerFamily, .videoCodec, .videoProfile, .videoLevel, .videoBitDepth, .videoResolution, .videoHDR, .audioCodec, .audioChannels:
                    return value == PlaybackFailure.unknown
                }
            }
        }

        let playback: AnalyticsEvent.Playback
        let fileID: Int
        let started: Bool

        var sourceKind: SourceKind {
            switch playback.streamMethod {
            case .hls: return .hls
            case .mp4: return .converted
            case .progressive: return .original
            case .localFile: return .localFile
            }
        }

        /// Video downloads are HLS packages; audio downloads and streams are the original file.
        var streamingMethod: StreamingMethod {
            switch playback.streamMethod {
            case .hls: return .hls
            case .localFile: return playback.media == .video ? .hls : .file
            case .mp4, .progressive: return .file
            }
        }

        /// Cast plays an original only after `ChromecastManager` finds it needs
        /// no conversion or is H.264; no other source runs a device check.
        var deviceCheck: DeviceCheck {
            playback.player == .chromecast && playback.streamMethod == .progressive ? .pass : .skipped
        }

        /// AVFoundation's unknown error wraps the CoreMedia or OSStatus error that names the fault.
        static func engineError(_ error: Error?) -> NSError? {
            guard let error = error.map({ $0 as NSError }) else { return nil }
            guard error.domain == AVFoundationErrorDomain, error.code == AVError.Code.unknown.rawValue,
                  let underlying = error.userInfo[NSUnderlyingErrorKey] as? NSError
            else { return error }
            return underlying
        }

        func tags(error: Error?) -> [Tag: String] {
            let engine = Self.engineError(error)
            var tags: [Tag: String] = [
                .telemetryEvent: Self.event,
                .schemaVersion: Self.schemaVersion,
                .platform: Self.platform,
                .player: playback.player.rawValue,
                .playbackOutcome: Self.outcome,
                .playbackTerminal: String(true),
                .playbackStarted: String(started),
                .failureMode: Mode(engine).rawValue,
                .streamingMethod: streamingMethod.rawValue,
                .sourceKind: sourceKind.rawValue,
                .deviceCheck: deviceCheck.rawValue,
                .rescueReason: Self.notApplicable,
                .rescueTo: Self.notApplicable,
                .engineErrorDomain: ErrorDomain(engine).rawValue,
                .engineErrorCategory: Self.notApplicable,
                .engineErrorCode: engine.map { String($0.code) } ?? Self.notApplicable,
                .sourceRequestStatus: sourceKind == .localFile ? Self.notApplicable : Self.unknown,
                .fileID: String(fileID)
            ]
            for fact in Tag.mediaFacts { tags[fact] = Self.unknown }
            return tags
        }

        static func message(failureMode: String) -> String {
            "playback \(outcome): \(failureMode)"
        }

        static func fingerprint(_ tags: [String: String]) -> [String] {
            [Tag.platform, .playbackOutcome, .failureMode, .engineErrorCode].map { tags[$0.rawValue] ?? unknown }
        }
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
                InternalFailurePresenter.logLocally("SentryTelemetry: legacy cache not deleted: \(error.localizedDescription)")
            }
        }
        return deleted
    }

    static func transportConfiguration() -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [SentryTransportGate.self] + (configuration.protocolClasses ?? [])
        return configuration
    }

    private static let transportSession = URLSession(configuration: transportConfiguration())

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
                InternalFailurePresenter.logLocally("SentryTelemetry: cache not deleted: \(error.localizedDescription)")
            }
        }
    }

    static func options(dsn: String) -> Options {
        let options = Options()
        options.dsn = dsn
        options.enableAutoSessionTracking = true
        options.sessionTrackingIntervalMillis = 60000
        options.cacheDirectoryPath = cacheDirectory.path
        options.urlSession = transportSession
        options.maxBreadcrumbs = 30
        options.beforeBreadcrumb = { isCapturing ? allowlisted($0) : nil }
        options.enableCaptureFailedRequests = false
        options.tracesSampleRate = NSNumber(value: tracesSampleRate)
        options.enableAutoPerformanceTracing = false
        options.enableUIViewControllerTracing = false
        options.enableUserInteractionTracing = false
        options.enableNetworkTracking = false
        options.enableFileIOTracing = false
        options.enableCoreDataTracing = false
        options.tracePropagationTargets = []
        options.enableMetricKit = true
        options.enableMetricKitRawPayload = false
        options.beforeSend = { event in
            guard isCapturing, !predatesConsent(event) else { return nil }
            return event.type == transactionType ? allowlistedTransaction(event) : allowlisted(event)
        }
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
        let tags = failure.tags(error: error)
        let message = PlaybackFailure.message(failureMode: tags[.failureMode] ?? PlaybackFailure.unknown)
        SentrySDK.capture(message: message) { scope in
            scope.setLevel(.error)
            for (tag, value) in tags { scope.setTag(value: value, key: tag.rawValue) }
        }
    }

    static func captureInCurrentSession() -> (PlaybackFailure, Error?) -> Void {
        let session = AccountNoticeStore.shared.session
        return { failure, error in
            DispatchQueue.main.async { capture(failure, error: error, startedIn: session) }
        }
    }

    static func record(_ action: Action) {
        SentrySDK.addBreadcrumb(action.breadcrumb(at: Date()))
    }

    static func begin(_ interval: Interval) -> Timing {
        guard isCapturing, SentrySDK.isEnabled else { return Timing(span: nil) }
        let span = SentrySDK.startTransaction(name: interval.rawValue, operation: interval.operation)
        for key in span.data.keys { span.removeData(key: key) }
        return Timing(span: span)
    }

    static func end(_ timing: Timing, outcome: Outcome) {
        switch outcome {
        case .succeeded: timing.span?.finish(status: .ok)
        case .failed: timing.span?.finish(status: .internalError)
        case .cancelled: timing.span?.finish(status: .cancelled)
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
    /// Sentry upgrade adds to the event, stay on the device.
    static func allowlisted(_ event: Event) -> Event {
        let tags = event.tags ?? [:]
        if tags[PlaybackFailure.Tag.telemetryEvent.rawValue] == PlaybackFailure.event {
            return allowlistedPlaybackFailure(event, tags: tags)
        }
        let category = tags["category"].flatMap(Failure.init(rawValue:))?.rawValue
        var sentTags: [String: String] = [:]
        sentTags["category"] = category
        sentTags["reason"] = tags["reason"].flatMap(Reason.init(rawValue:))?.rawValue
        sentTags["endpoint"] = tags["endpoint"].flatMap(Endpoint.init(rawValue:))?.rawValue
        sentTags["context"] = tags["context"].flatMap { isContext($0) ? $0 : nil }
        let sent = allowlistedBase(event, level: event.level)
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

    /// Anonymous: no user, and the message and fingerprint are rebuilt from the kept tags.
    private static func allowlistedPlaybackFailure(_ event: Event, tags: [String: String]) -> Event {
        let sentTags = tags.filter { key, value in PlaybackFailure.Tag(rawValue: key)?.allows(value) == true }
        let sent = allowlistedBase(event, level: .error)
        sent.tags = sentTags
        sent.message = SentryMessage(formatted: PlaybackFailure.message(
            failureMode: sentTags[PlaybackFailure.Tag.failureMode.rawValue] ?? PlaybackFailure.unknown
        ))
        sent.fingerprint = PlaybackFailure.fingerprint(sentTags)
        return sent
    }

    private static func allowlistedBase(_ event: Event, level: SentryLevel) -> Event {
        let sent = Event(level: level)
        sent.eventId = event.eventId
        sent.timestamp = event.timestamp
        sent.releaseName = event.releaseName
        sent.dist = event.dist
        sent.environment = event.environment
        sent.sdk = event.sdk
        sent.threads = event.threads
        sent.debugMeta = event.debugMeta
        sent.context = sentContext(event.context)
        let breadcrumbs = event.breadcrumbs?.compactMap(allowlisted)
        sent.breadcrumbs = breadcrumbs?.isEmpty == false ? breadcrumbs : nil
        return sent
    }

    private static let transactionType = "transaction"

    private static let sentContextKeys: Set<String> = ["app", "device", "os", "runtime"]

    private static let sentDeviceKeys: Set<String> = [
        "arch", "battery_level", "charging", "family", "free_memory", "ios_app_on_macos", "ios_app_on_visionos",
        "locale", "low_power_mode", "mac_catalyst_app", "memory_size", "model", "model_id", "orientation",
        "processor_count", "screen_height_pixels", "screen_width_pixels", "simulator", "thermal_state", "usable_memory"
    ]

    private static func sentContext(_ context: [String: [String: Any]]?) -> [String: [String: Any]]? {
        guard var sent = context?.filter({ sentContextKeys.contains($0.key) }) else { return nil }
        sent["device"] = sent["device"]?.filter { sentDeviceKeys.contains($0.key) }
        return sent
    }

    private static let screenKeys = ["screen", "parentViewController", "presentingViewController"]

    private static let appStates: Set<String> = ["foreground", "background", "active", "inactive"]

    private static let httpMethods: Set<String> = ["GET", "HEAD", "POST", "PUT", "PATCH", "DELETE"]

    static func allowlisted(_ breadcrumb: Breadcrumb) -> Breadcrumb? {
        let data = breadcrumb.data ?? [:]
        var kept: [String: Any] = [:]
        switch breadcrumb.category {
        case "ui.lifecycle":
            for key in screenKeys {
                if let name = data[key] as? String, isContext(name) { kept[key] = name }
            }
            guard kept["screen"] != nil else { return nil }
        case "app.lifecycle":
            guard let state = data["state"] as? String, appStates.contains(state) else { return nil }
            kept["state"] = state
        case "http":
            let host = ((data["url"] as? String).flatMap { URLComponents(string: $0)?.host } ?? data["host"] as? String)?.lowercased()
            guard let host, host == "put.io" || host.hasSuffix(".put.io")
            else { return nil }
            kept["host"] = host
            if let method = data["method"] as? String, httpMethods.contains(method) { kept["method"] = method }
            if let status = data["status_code"] as? NSNumber, (100..<600).contains(status.intValue) {
                kept["status_code"] = status.intValue
            }
        default:
            let action = Action.allCases.first {
                $0.category == breadcrumb.category && $0.message == breadcrumb.message && $0.data == breadcrumb.data as? [String: String]
            }
            return action?.breadcrumb(at: breadcrumb.timestamp)
        }
        let sent = Breadcrumb(level: breadcrumb.level, category: breadcrumb.category)
        sent.type = breadcrumb.category == "http" ? "http" : "navigation"
        sent.timestamp = breadcrumb.timestamp
        for (key, value) in kept { sent.setData(value: value, key: key) }
        return sent
    }

    private static let transactionKeys: Set<String> = [
        "contexts", "dist", "environment", "event_id", "extra", "level", "measurements", "platform",
        "release", "sdk", "spans", "start_timestamp", "tags", "timestamp", "transaction", "transaction_info", "type"
    ]

    private static let traceKeys: Set<String> = [
        "type", "span_id", "trace_id", "parent_span_id", "op", "origin", "sampled", "status", "timestamp", "start_timestamp", "data", "tags"
    ]

    private static let measurementKeys: Set<String> = ["frames_total", "frames_slow", "frames_frozen"]

    private static let timingDataKeys: Set<String> = ["frames.delay"]

    static func allowlistedTransaction(_ event: Event) -> Event? {
        event.tags = nil
        event.extra = nil
        event.breadcrumbs = nil
        event.request = nil
        event.message = nil
        event.logger = nil
        event.serverName = nil
        event.modules = nil
        event.fingerprint = nil
        event.exceptions = nil
        event.threads = nil
        event.stacktrace = nil
        event.debugMeta = nil
        event.context = sentContext(event.context)
        event.user = nil
        return isStaticTiming(event.serialize()) ? event : nil
    }

    private static func isStaticTiming(_ payload: [String: Any]) -> Bool {
        func isEmptyOrMissing(_ value: Any?) -> Bool {
            switch value {
            case nil: return true
            case let value as [String: Any]: return value.isEmpty
            case let value as [Any]: return value.isEmpty
            default: return false
            }
        }
        func keys(_ value: Any?, within allowed: Set<String>) -> Bool {
            guard let value else { return true }
            guard let dictionary = value as? [String: Any] else { return false }
            return Set(dictionary.keys).isSubset(of: allowed)
        }
        guard keys(payload, within: transactionKeys),
              let interval = (payload["transaction"] as? String).flatMap(Interval.init(rawValue:)),
              (payload["transaction_info"] as? [String: String]) == ["source": "custom"],
              isEmptyOrMissing(payload["spans"]),
              isEmptyOrMissing(payload["tags"]),
              keys(payload["extra"], within: timingDataKeys),
              keys(payload["measurements"], within: measurementKeys),
              let contexts = payload["contexts"] as? [String: Any],
              keys(contexts, within: sentContextKeys.union(["trace", "profile"])),
              isEmptyOrMissing(contexts["profile"]),
              let trace = contexts["trace"] as? [String: Any],
              keys(trace, within: traceKeys),
              trace["op"] as? String == interval.operation,
              isEmptyOrMissing(trace["tags"]),
              keys(trace["data"], within: timingDataKeys)
        else { return false }
        return true
    }
}

final class SentryTransportGate: URLProtocol {
    override static func canInit(with request: URLRequest) -> Bool { !SentryTelemetry.isCapturing }

    override static func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        client?.urlProtocol(self, didFailWithError: URLError(.cancelled))
    }

    override func stopLoading() {}
}
