import Foundation

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

extension MediaPreviewSession {
    static func body(_ data: Data?, of response: URLResponse?) -> Data? {
        guard let data, let response = response as? HTTPURLResponse, (200..<300).contains(response.statusCode) else {
            return nil
        }
        return data
    }

    static func fetchFailureMessage(for response: URLResponse?, otherwise fallback: String) -> String {
        guard (response as? HTTPURLResponse)?.statusCode == 404 else { return fallback }
        return NSLocalizedString("The original version of this file has been deleted from your put.io account.", comment: "")
    }
}
