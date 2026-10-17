import AVFoundation
import Foundation
import PutioSDK

/// The events from the Analytics event contract that this app has a hook for.
/// Every value is a fixed vocabulary, so a call site can't send free text.
enum AnalyticsEvent: Equatable {
    enum Entry: String, CaseIterable {
        case direct, deeplink, resume
    }

    enum Screen: String, CaseIterable {
        case files, account, player
    }

    enum SessionDuration: String, CaseIterable {
        case under1m = "lt_1m", from1mTo5m = "1m_5m", from5mTo15m = "5m_15m", from15mTo60m = "15m_60m", over60m = "gt_60m"

        init(seconds: TimeInterval) {
            switch seconds {
            case ..<60: self = .under1m
            case ..<300: self = .from1mTo5m
            case ..<900: self = .from5mTo15m
            case ..<3600: self = .from15mTo60m
            default: self = .over60m
            }
        }
    }

    /// Account settings this app saves, minus the privacy controls: consent
    /// state stays out of events.
    enum Setting: String, CaseIterable {
        case showOptimisticUsage = "show_optimistic_usage"
        case trashEnabled = "trash_enabled"
        case historyEnabled = "history_enabled"
        case sortBy = "sort_by"
        case hideSubtitles = "hide_subtitles"
        case dontAutoSelectSubtitles = "dont_autoselect_subtitles"
        case tunnelRoute = "tunnel_route_name"
        case chromecastPlaybackType = "chromecast_playback_type"
        case downloadConcurrency = "download_concurrency"
    }

    /// The kind of value saved, never the value itself.
    enum ValueClass: String, CaseIterable {
        case on, off, option, number

        init(_ enabled: Bool) {
            self = enabled ? .on : .off
        }
    }

    enum Media: String, CaseIterable {
        case video, audio
    }

    enum StreamMethod: String, CaseIterable {
        case hls, progressive, mp4, localFile = "local_file"
    }

    enum Player: String, CaseIterable {
        case native, chromecast
    }

    struct Playback: Equatable {
        let media: Media
        let streamMethod: StreamMethod
        let player: Player
    }

    enum PlaybackDuration: String, CaseIterable {
        case under5m = "lt_5m", from5mTo30m = "5m_30m", from30mTo90m = "30m_90m", over90m = "gt_90m"

        init(seconds: TimeInterval) {
            switch seconds {
            case ..<300: self = .under5m
            case ..<1800: self = .from5mTo30m
            case ..<5400: self = .from30mTo90m
            default: self = .over90m
            }
        }
    }

    enum Completion: String, CaseIterable {
        case completed, partial
    }

    enum PlaybackError: String, CaseIterable {
        case network, media, notFound = "not_found", needsConversion = "needs_conversion", unknown

        /// The error's kind only: its message and URL stay on the device.
        init(_ error: Error?) {
            if let error = error as? PutioSDKError {
                switch error.type {
                case .networkError: self = .network
                case .httpError(404, _): self = .notFound
                default: self = .unknown
                }
                return
            }
            switch (error as NSError?)?.domain {
            case NSURLErrorDomain?: self = .network
            case AVFoundationErrorDomain?, "CoreMediaErrorDomain"?: self = .media
            default: self = .unknown
            }
        }
    }

    case appOpened(Entry)
    case appBackgrounded(SessionDuration)
    case screenViewed(Screen)
    case settingsChanged(Setting, ValueClass)
    case supportStarted
    case playbackStarted(Playback)
    case playbackEnded(Playback, Completion, PlaybackDuration)
    case playbackFailed(Playback, PlaybackError)

    var name: String {
        switch self {
        case .appOpened: return "app_opened"
        case .appBackgrounded: return "app_backgrounded"
        case .screenViewed: return "screen_viewed"
        case .settingsChanged: return "settings_changed"
        case .supportStarted: return "support_started"
        case .playbackStarted: return "playback_started"
        case .playbackEnded: return "playback_ended"
        case .playbackFailed: return "playback_failed"
        }
    }

    var properties: [String: String] {
        switch self {
        case .appOpened(let entry):
            return ["entry": entry.rawValue]
        case .appBackgrounded(let duration):
            return ["session_duration": duration.rawValue]
        case .screenViewed(let screen):
            return ["screen": screen.rawValue]
        case .settingsChanged(let setting, let valueClass):
            return ["setting": setting.rawValue, "value_class": valueClass.rawValue]
        case .supportStarted:
            return [:]
        case .playbackStarted(let playback):
            return playback.properties
        case .playbackEnded(let playback, let completion, let duration):
            return playback.properties.merging(["completion": completion.rawValue, "duration": duration.rawValue]) { $1 }
        case .playbackFailed(let playback, let error):
            return playback.properties.merging(["error_class": error.rawValue]) { $1 }
        }
    }
}

private extension AnalyticsEvent.Playback {
    var properties: [String: String] {
        ["media": media.rawValue, "stream_method": streamMethod.rawValue, "player": player.rawValue]
    }
}

/// The contract's allowlist, written out apart from `AnalyticsEvent` so a new
/// event, key, or value is dropped until it is listed here too. Everything the
/// SDK adds, its device census included, is dropped unless `sdkProperties`
/// keeps it.
enum AnalyticsAllowlist {
    private static let playback: [String: Set<String>] = [
        "media": ["video", "audio"],
        "stream_method": ["hls", "progressive", "mp4", "local_file"],
        "player": ["native", "chromecast"]
    ]

    static let eventProperties: [String: [String: Set<String>]] = [
        "app_opened": ["entry": ["direct", "deeplink", "resume"]],
        "app_backgrounded": ["session_duration": ["lt_1m", "1m_5m", "5m_15m", "15m_60m", "gt_60m"]],
        "screen_viewed": ["screen": ["files", "account", "player"]],
        "settings_changed": [
            "setting": [
                "show_optimistic_usage", "trash_enabled", "history_enabled", "sort_by", "hide_subtitles",
                "dont_autoselect_subtitles", "tunnel_route_name", "chromecast_playback_type", "download_concurrency"
            ],
            "value_class": ["on", "off", "option", "number"]
        ],
        "support_started": [:],
        "playback_started": playback,
        "playback_ended": playback.merging([
            "completion": ["completed", "partial"],
            "duration": ["lt_5m", "5m_30m", "30m_90m", "gt_90m"]
        ]) { $1 },
        "playback_failed": playback.merging([
            "error_class": ["network", "media", "not_found", "needs_conversion", "unknown"]
        ]) { $1 }
    ]

    static let commonProperties: [String: Set<String>] = [
        "app": ["ios"],
        "runtime": ["ios"],
        "device_class": ["phone", "tablet", "desktop", "unknown"],
        "auth_state": ["signed_in"],
        "release_channel": ["stable", "beta"]
    ]

    static let patternProperties: [String: String] = [
        "app_version": "^[A-Za-z0-9_.+-]{1,64}$",
        "runtime_version": "^[0-9]+(\\.[0-9]+){0,2}$"
    ]

    /// The SDK's own keys that ingestion needs, each checked for its shape.
    static let sdkProperties: [String: (Any) -> Bool] = [
        "$lib": { $0 as? String == "posthog-ios" },
        "$lib_version": { ($0 as? String)?.range(of: "^[0-9]+(\\.[0-9]+){1,3}$", options: .regularExpression) != nil },
        "$session_id": { ($0 as? String).flatMap(UUID.init(uuidString:)) != nil },
        "$is_identified": { $0 is Bool },
        "$process_person_profile": { $0 is Bool },
        "$geoip_disable": { $0 as? Bool == true }
    ]

    /// Nil drops the whole event.
    static func allowedProperties(event: String, properties: [String: Any]) -> [String: Any]? {
        guard let eventValues = eventProperties[event] else { return nil }
        return properties.filter { key, value in
            if let isValid = sdkProperties[key] { return isValid(value) }
            guard let value = value as? String else { return false }
            if let listed = eventValues[key] ?? commonProperties[key] { return listed.contains(value) }
            if let pattern = patternProperties[key] { return value.range(of: pattern, options: .regularExpression) != nil }
            return false
        }
    }
}

/// Turns scene transitions into `app_opened` and `app_backgrounded`. Main
/// thread only, as UIKit calls the scene delegate.
final class AppSessionAnalytics {
    private let capture: (AnalyticsEvent) -> Void
    private let now: () -> Date
    /// A launch is an open, whether or not the scene reports entering the foreground.
    private var opensOnActive = true
    private var openedFromLink = false
    private var hasOpened = false
    private var activeSince: Date?

    init(capture: @escaping (AnalyticsEvent) -> Void, now: @escaping () -> Date = Date.init) {
        self.capture = capture
        self.now = now
    }

    func willEnterForeground() {
        opensOnActive = true
    }

    /// A cold-launch link arrives before the scene enters the foreground.
    func didOpenLink() {
        openedFromLink = true
    }

    /// Also called after a system alert or Control Center, which is no open.
    func didBecomeActive() {
        guard opensOnActive else { return }
        let entry: AnalyticsEvent.Entry = openedFromLink ? .deeplink : (hasOpened ? .resume : .direct)
        opensOnActive = false
        openedFromLink = false
        hasOpened = true
        activeSince = now()
        capture(.appOpened(entry))
    }

    func didEnterBackground() {
        openedFromLink = false
        guard let activeSince else { return }
        self.activeSince = nil
        capture(.appBackgrounded(.init(seconds: now().timeIntervalSince(activeSince))))
    }
}

/// One player's playback events: started once, then ended or failed once.
/// AVFoundation can report from any thread.
final class PlaybackAnalytics {
    private let playback: AnalyticsEvent.Playback
    private let capture: (AnalyticsEvent) -> Void
    private let now: () -> Date
    private let lock = NSLock()
    private var startedAt: Date?
    private var reachedEnd = false
    private var isFinished = false
    private var queueObservation: NSKeyValueObservation?

    init(_ playback: AnalyticsEvent.Playback, capture: @escaping (AnalyticsEvent) -> Void = ProductAnalytics.capture, now: @escaping () -> Date = Date.init) {
        self.playback = playback
        self.capture = capture
        self.now = now
    }

    func start() {
        let started: Bool = lock.withLock {
            guard startedAt == nil, !isFinished else { return false }
            startedAt = now()
            return true
        }
        if started { capture(.playbackStarted(playback)) }
    }

    /// For a queue: failed when its current item fails, played to the end
    /// when it runs out.
    func start(following player: AVPlayer?) {
        let observation = player?.observe(\.currentItem?.status, options: [.new]) { [weak self] player, _ in
            guard let item = player.currentItem else {
                self?.didReachEnd()
                return
            }
            if item.status == .failed { self?.fail(item.error) }
        }
        lock.withLock { queueObservation = observation }
        start()
    }

    func didReachEnd() {
        lock.withLock { reachedEnd = true }
    }

    /// Before `start()`, as when the player closes while it looks up the
    /// position, it sends nothing and a later `start()` sends nothing either.
    func end() {
        let ended: AnalyticsEvent? = lock.withLock {
            queueObservation = nil
            defer { isFinished = true }
            guard let startedAt, !isFinished else { return nil }
            return .playbackEnded(playback, reachedEnd ? .completed : .partial, .init(seconds: now().timeIntervalSince(startedAt)))
        }
        ended.map(capture)
    }

    func fail(_ error: Error?) {
        let failed: Bool = lock.withLock {
            guard !isFinished else { return false }
            isFinished = true
            return true
        }
        if failed { capture(.playbackFailed(playback, .init(error))) }
    }
}
