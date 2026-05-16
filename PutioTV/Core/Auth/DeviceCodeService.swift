import Foundation
import PutioSDK

/// Drives a single device-code attempt: creates a code, polls every 3s, and
/// returns the redeemed token. The token-validation step is performed by
/// `AuthSession` so the polling loop stays focused on the SDK contract.
protocol DeviceCodeServicing: Sendable {
    func createCode() async throws -> PutioAuthCode
    func awaitLinkedToken(forCode code: String) async throws -> String
}

actor DeviceCodeService: DeviceCodeServicing {
    private let api: PutioSDK
    private let pollInterval: Duration

    init(api: PutioSDK, pollInterval: Duration = .seconds(3)) {
        self.api = api
        self.pollInterval = pollInterval
    }

    func createCode() async throws -> PutioAuthCode {
        try await api.getAuthCode()
    }

    func awaitLinkedToken(forCode code: String) async throws -> String {
        while !Task.isCancelled {
            if let token = try await api.checkAuthCodeMatch(code: code), !token.isEmpty {
                return token
            }
            try await Task.sleep(for: pollInterval)
        }
        throw CancellationError()
    }
}
