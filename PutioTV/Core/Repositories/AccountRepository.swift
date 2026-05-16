import Foundation
import PutioSDK

protocol AccountRepositoryProtocol: Sendable {
    func info() async throws -> PutioAccount
    func settings() async throws -> PutioAccount.Settings
    func updateSettings(_ patch: PutioAccountSettingsPatch) async throws
    func routes() async throws -> [PutioRoute]
}

struct AccountRepository: AccountRepositoryProtocol {
    let api: PutioSDK

    func info() async throws -> PutioAccount {
        try await api.getAccountInfo(query: PutioAccountInfoQuery())
    }

    func settings() async throws -> PutioAccount.Settings {
        try await api.getAccountSettings()
    }

    func updateSettings(_ patch: PutioAccountSettingsPatch) async throws {
        _ = try await api.saveAccountSettings(.patch(patch))
    }

    func routes() async throws -> [PutioRoute] {
        try await api.getRoutes()
    }
}
