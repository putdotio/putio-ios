import Foundation

// Launch-environment flags the mocked e2e suite sets on the app. Release builds
// always read false, so call sites can branch on these without their own
// `#if DEBUG` dance.
enum PutioE2EEnvironment {
    // Set by every mocked UI test: API traffic is served by
    // PutioE2EMockURLProtocol, so anything that reaches the real network or
    // animates against wall-clock time should hold still instead.
    static var isMockAPIEnabled: Bool {
        #if DEBUG
        return ProcessInfo.processInfo.environment["PUTIO_E2E_MOCK_API"] == "1"
        #else
        return false
        #endif
    }
}
