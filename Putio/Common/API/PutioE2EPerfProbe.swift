#if DEBUG
import UIKit
import os

// The /files/list requests the mock served, for PutioUITests to read. Installed
// with the mocked API, as a 1pt accessibility element whose value is read fresh
// on every query.
enum PutioE2EPerfProbe {
    static let accessibilityIdentifier = "putio-perf-probe"

    private static let filesListRequests = OSAllocatedUnfairLock(initialState: 0)

    static func recordRequest(path: String) {
        guard path == "/v2/files/list" else { return }
        filesListRequests.withLock { $0 += 1 }
    }

    static func installIfEnabled(in window: UIWindow?) {
        guard PutioE2EEnvironment.isMockAPIEnabled, let window else { return }

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
            get { "files-list-requests=\(PutioE2EPerfProbe.filesListRequests.withLock { $0 })" }
            set {}
        }
    }
}
#endif
