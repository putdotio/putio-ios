import os
import QuartzCore

/// `io.put.perf` Points of Interest intervals that Instruments and
/// `PutioUITests/PerformanceUITests.swift` measure. Debug builds only, which
/// `mise run perf` optimizes: in Release every signpost compiles to nothing, so
/// shipping builds emit none and never flush Core Animation early. An interval
/// begun from a `SentryTelemetry.Interval` also times a sampled Sentry
/// transaction under the same static name, in every build. Metadata is row
/// counts only, never ids, names, or URLs.
enum PerfSignpost {
    struct Interval {
        #if DEBUG
        fileprivate let name: StaticString
        fileprivate let state: OSSignpostIntervalState
        #endif
        fileprivate var timing: SentryTelemetry.Timing?
    }

    #if DEBUG
    private static let signposter = OSSignposter(subsystem: "io.put.perf", category: .pointsOfInterest)
    private static let launchToFiles = OSAllocatedUnfairLock<OSSignpostIntervalState?>(initialState: nil)
    #endif

    @inline(__always)
    static func begin(_ name: StaticString) -> Interval {
        #if DEBUG
        Interval(name: name, state: signposter.beginInterval(name, id: signposter.makeSignpostID()))
        #else
        Interval()
        #endif
    }

    @inline(__always)
    static func begin(_ name: StaticString, rows: Int) -> Interval {
        #if DEBUG
        Interval(name: name, state: signposter.beginInterval(name, id: signposter.makeSignpostID(), "rows \(rows)"))
        #else
        Interval()
        #endif
    }

    static func begin(_ traced: SentryTelemetry.Interval) -> Interval {
        var interval = begin(traced.signpostName)
        interval.timing = SentryTelemetry.begin(traced)
        return interval
    }

    static func end(_ interval: Interval, outcome: SentryTelemetry.Outcome = .succeeded) {
        #if DEBUG
        signposter.endInterval(interval.name, interval.state)
        #endif
        if let timing = interval.timing {
            SentryTelemetry.end(timing, outcome: outcome)
        }
    }

    /// Ends the interval once Core Animation has committed the pending UI work,
    /// so it covers the layout, drawing, and image decoding UIKit defers to the
    /// next commit. Points of Interest is enabled even with no recorder attached,
    /// so Debug builds pull the commit forward on every call.
    static func endAfterCommit(_ interval: Interval, outcome: SentryTelemetry.Outcome = .succeeded) {
        #if DEBUG
        if signposter.isEnabled {
            CATransaction.flush()
        }
        #endif
        end(interval, outcome: outcome)
    }

    static func beginLaunchToFiles() {
        #if DEBUG
        let state = signposter.beginInterval("LaunchToFiles", id: signposter.makeSignpostID())
        launchToFiles.withLock { $0 = state }
        #endif
    }

    /// Called after every successful root listing; only the first ends the interval.
    static func endLaunchToFilesIfNeeded() {
        #if DEBUG
        guard let state = launchToFiles.withLock({ state in
            defer { state = nil }
            return state
        }) else { return }

        endAfterCommit(Interval(name: "LaunchToFiles", state: state))
        #endif
    }
}

extension SentryTelemetry.Interval {
    var signpostName: StaticString {
        switch self {
        case .fetchUser: return "FetchUser"
        case .filesFetch: return "FilesFetch"
        case .playbackStart: return "PlaybackStart"
        }
    }
}
