import os
import QuartzCore

/// Points of Interest intervals that Instruments and
/// `PutioUITests/PerformanceUITests.swift` measure. Metadata carries ids and
/// counts only, never names or URLs.
enum PerfSignpost {
    static let signposter = OSSignposter(subsystem: "io.put.perf", category: .pointsOfInterest)

    private static let launchToFiles = OSAllocatedUnfairLock<OSSignpostIntervalState?>(initialState: nil)

    /// Ends the interval once Core Animation has committed the pending UI work,
    /// so it covers the layout, drawing, and image decoding UIKit defers to the
    /// next commit. The commit is pulled forward only while a tool records
    /// signposts; otherwise this just ends the interval.
    static func endAfterCommit(_ name: StaticString, _ state: OSSignpostIntervalState) {
        if signposter.isEnabled {
            CATransaction.flush()
        }
        signposter.endInterval(name, state)
    }

    static func beginLaunchToFiles() {
        let state = signposter.beginInterval("LaunchToFiles", id: signposter.makeSignpostID())
        launchToFiles.withLock { $0 = state }
    }

    /// Called after every successful root listing; only the first ends the interval.
    static func endLaunchToFilesIfNeeded() {
        guard let state = launchToFiles.withLock({ state in
            defer { state = nil }
            return state
        }) else { return }

        endAfterCommit("LaunchToFiles", state)
    }
}
