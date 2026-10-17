#if DEBUG
import UIKit
import os

// Counters PutioUITests/PerformanceUITests reads to count work no signpost
// shows: /files/list requests the mock served, and FilesViewControllers still
// alive. Installed only with the large fixture, as a 1pt accessibility element
// whose value is read fresh on every query.
enum PutioE2EPerfProbe {
    static let accessibilityIdentifier = "putio-perf-probe"

    private struct Counts {
        var filesListRequests = 0
        var liveFilesControllers = 0
    }

    private static let counts = OSAllocatedUnfairLock(initialState: Counts())

    static func recordRequest(path: String) {
        guard path == "/v2/files/list" else { return }
        counts.withLock { $0.filesListRequests += 1 }
    }

    /// Held by every FilesViewController, so the count follows deallocation
    /// whichever initializer built the controller.
    final class FilesControllerToken {
        init() {
            PutioE2EPerfProbe.counts.withLock { $0.liveFilesControllers += 1 }
        }

        deinit {
            PutioE2EPerfProbe.counts.withLock { $0.liveFilesControllers -= 1 }
        }
    }

    static func installIfEnabled(in window: UIWindow?) {
        guard PutioE2ELargeFixture.isEnabled, let window else { return }

        window.subviews.filter { $0 is ProbeView }.forEach { $0.removeFromSuperview() }
        window.addSubview(ProbeView(frame: CGRect(x: 0, y: 0, width: 1, height: 1)))
    }

    private final class ProbeView: UIView {
        override init(frame: CGRect) {
            super.init(frame: frame)
            isUserInteractionEnabled = false
            isAccessibilityElement = true
            accessibilityIdentifier = PutioE2EPerfProbe.accessibilityIdentifier
        }

        required init?(coder: NSCoder) {
            nil
        }

        override var accessibilityValue: String? {
            get {
                let counts = PutioE2EPerfProbe.counts.withLock { $0 }
                return "files-list-requests=\(counts.filesListRequests) live-files-controllers=\(counts.liveFilesControllers)"
            }
            set {}
        }
    }
}
#endif
