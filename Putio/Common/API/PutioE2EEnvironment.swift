import Foundation

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
}
