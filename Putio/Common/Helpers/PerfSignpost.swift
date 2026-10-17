import os
import QuartzCore

/// `io.put.perf` Points of Interest intervals that Instruments and
/// `PutioUITests/PerformanceUITests.swift` measure. Debug builds only, which
/// `mise run perf` optimizes: in Release every call compiles to nothing, so
/// shipping builds emit no signposts and never flush Core Animation early.
/// Metadata is row counts only, never ids, names, or URLs.
enum PerfSignpost {
    struct Interval {
        #if DEBUG
        fileprivate let name: StaticString
        fileprivate let state: OSSignpostIntervalState
        #endif
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

    static func end(_ interval: Interval) {
        #if DEBUG
        signposter.endInterval(interval.name, interval.state)
        #endif
    }

    /// Ends the interval once Core Animation has committed the pending UI work,
    /// so it covers the layout, drawing, and image decoding UIKit defers to the
    /// next commit. Points of Interest is enabled even with no recorder attached,
    /// so Debug builds pull the commit forward on every call.
    static func endAfterCommit(_ interval: Interval) {
        #if DEBUG
        if signposter.isEnabled {
            CATransaction.flush()
        }
        signposter.endInterval(interval.name, interval.state)
        #endif
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
