import Foundation

enum PutioTV {
    enum Constants {
        static let bundleClientIDKey = "PUTIO_OAUTH_CLIENT_ID"

        /// `2951` is the tvOS client id used by the React Native `tv-native`
        /// reference app. Override at build time by setting
        /// `PUTIO_OAUTH_CLIENT_ID` in the tvOS target's Info.plist.
        static let defaultClientID = "2951"

        static let appLinkURL = "put.io/link"

        /// `APP_RUNTIME_IDENTIFIER` mirrors the iOS app's bundle-id-driven
        /// keychain service; the tvOS Info.plist provides the value at runtime.
        static let bundleRuntimeIdentifierKey = "PUTIO_APP_IDENTIFIER"
        static let defaultRuntimeIdentifier = "io.put.tvos.dev"
    }

    static var clientID: String {
        bundleString(Constants.bundleClientIDKey) ?? Constants.defaultClientID
    }

    static var runtimeIdentifier: String {
        bundleString(Constants.bundleRuntimeIdentifierKey) ?? Constants.defaultRuntimeIdentifier
    }

    static var keychainService: String { runtimeIdentifier }

    private static func bundleString(_ key: String) -> String? {
        guard let raw = Bundle.main.object(forInfoDictionaryKey: key) as? String else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
