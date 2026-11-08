import Foundation
import PutioSDK

// Launch-environment flags the mocked e2e suite sets. Release builds always
// read false, so call sites need no `#if DEBUG` of their own.
enum PutioE2EEnvironment {
    // True means anything reaching the real network, or animating against
    // wall-clock time, should hold still instead.
    static var isMockAPIEnabled: Bool {
        #if DEBUG
        return ProcessInfo.processInfo.environment["PUTIO_E2E_MOCK_API"] == "1"
        #else
        return false
        #endif
    }

    static var isAnimationDisabled: Bool {
        isMockAPIEnabled && ProcessInfo.processInfo.environment["PUTIO_E2E_ANIMATIONS"] != "1"
    }

    static let animationSpeed: Float = 2

    private static var startFileOpened = false

    static func takeStartFile(from files: [PutioFile]) -> PutioFile? {
        guard isMockAPIEnabled, !startFileOpened,
              let id = ProcessInfo.processInfo.environment["PUTIO_E2E_OPEN_FILE"].flatMap(Int.init),
              let file = files.first(where: { $0.id == id }) else { return nil }
        startFileOpened = true
        return file
    }
}
