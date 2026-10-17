import Foundation

/// Loads image and PDF previews. Their URLs carry the OAuth token as
/// `oauth_token`, so the session keeps no URL cache: no response, and no cache
/// key holding the token, is ever stored.
enum MediaPreviewSession {
    static let shared = URLSession(configuration: configuration())

    static func configuration(environment: [String: String] = ProcessInfo.processInfo.environment) -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil

        #if DEBUG
        if environment["PUTIO_E2E_MOCK_API"] == "1" {
            configuration.protocolClasses = [PutioE2EMockURLProtocol.self] + (configuration.protocolClasses ?? [])
        }
        #endif

        return configuration
    }
}
