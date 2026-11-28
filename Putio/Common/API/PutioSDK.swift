import Foundation
import UIKit
import PutioSDK

let api = PutioSDKFactory.make()

enum PutioSDKFactory {
    static func make(environment: [String: String] = ProcessInfo.processInfo.environment) -> PutioSDK {
        let config = PutioSDKConfig(
            clientID: PUTIOKIT_CLIENT_ID,
            clientName: UIDevice.current.name,
            token: environment["PUTIO_E2E_ACCESS_TOKEN"] ?? ""
        )

        #if DEBUG
        if environment["PUTIO_E2E_MOCK_API"] == "1" {
            let sessionConfiguration = URLSessionConfiguration.ephemeral
            sessionConfiguration.protocolClasses = [PutioE2EMockURLProtocol.self]
            // Only bounds stray requests to hosts the mock does not claim, since
            // mocked responses return in-process. Generous on purpose: a loaded
            // CI runner can blow a tight timeout even on an instant response,
            // and a sign-in bootstrap that fails that way strands the suite on
            // the login screen.
            sessionConfiguration.timeoutIntervalForRequest = 10
            sessionConfiguration.timeoutIntervalForResource = 10
            return PutioSDK(config: config, urlSession: URLSession(configuration: sessionConfiguration))
        }
        #endif

        return PutioSDK(config: config)
    }
}

typealias PutioSDKBoolCompletion = (Result<PutioOKResponse, PutioSDKError>) -> Void

extension PutioMp4Conversion {
    typealias Status = PutioMp4ConversionStatus
}

extension PutioListTrashResponse {
    var trash_size: Int64 { trashSize }
}

/// The app's keys in the account's `/config` document.
struct AppConfig: Decodable {
    enum CodingKeys: String, CodingKey {
        case chromecastPlaybackType = "chromecast_playback_type"
        case autoRotateVideo = "auto_rotate_video"
        // One flat key, dot included. put.io keeps it per OAuth app, so an
        // answer given on the web doesn't reach this app.
        case productAnalyticsPromptAnswered = "dismissed.product_analytics_prompt"
        case usesPutioCastReceiver = "beta.putio_cast_receiver"
    }

    let chromecastPlaybackType: PutioChromecastPlaybackType
    let autoRotateVideo: Bool
    let productAnalyticsPromptAnswered: Bool
    let usesPutioCastReceiver: Bool

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let rawValue = try? container.decodeIfPresent(String.self, forKey: .chromecastPlaybackType)
        chromecastPlaybackType = rawValue.flatMap(PutioChromecastPlaybackType.init(rawValue:)) ?? .hls
        autoRotateVideo = (try? container.decodeIfPresent(Bool.self, forKey: .autoRotateVideo)) ?? true
        usesPutioCastReceiver = (try? container.decodeIfPresent(Bool.self, forKey: .usesPutioCastReceiver)) == true

        do {
            productAnalyticsPromptAnswered = try container.decodeIfPresent(Bool.self, forKey: .productAnalyticsPromptAnswered) ?? false
        } catch {
            // Only a readable "not answered" asks, and an unreadable value must
            // not fail /config, which would fail sign-in.
            productAnalyticsPromptAnswered = true
        }
    }
}

enum MediaTokenError: Error {
    case unavailable
}

extension PutioSDK {
    var mediaToken: String? {
        let token = PutioRealm.open(context: "PutioSDK.mediaToken")?.objects(User.self).first?.downloadToken
        return token?.isEmpty == false ? token : nil
    }

    func resolveMediaToken() async throws -> String {
        if let mediaToken { return mediaToken }
        let account = try await getAccountInfo(query: PutioAccountInfoQuery(downloadToken: true))
        guard !account.downloadToken.isEmpty else { throw MediaTokenError.unavailable }
        return account.downloadToken
    }
}

extension URLRequest {
    init?(headerAuthorizedMediaURL url: URL) {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let token = components.queryItems?.first(where: { $0.name == "oauth_token" })?.value,
              !token.isEmpty else { return nil }
        let queryItems = components.queryItems?.filter { $0.name != "oauth_token" } ?? []
        components.queryItems = queryItems.isEmpty ? nil : queryItems
        guard let tokenFreeURL = components.url else { return nil }
        self.init(url: tokenFreeURL)
        setValue("Token \(token)", forHTTPHeaderField: "Authorization")
    }
}

extension PutioSDK {
    private func complete<T>(
        _ completion: @escaping (Result<T, PutioSDKError>) -> Void,
        operation: @escaping () async throws -> T
    ) {
        Task {
            do {
                let value = try await operation()
                await MainActor.run {
                    completion(.success(value))
                }
            } catch let error as PutioSDKError {
                await MainActor.run {
                    completion(.failure(error))
                }
            } catch {
                preconditionFailure("PutioSDK async APIs should throw PutioSDKError, got \(error)")
            }
        }
    }

    func getAccountInfo(
        query: PutioAccountInfoQuery = PutioAccountInfoQuery(),
        _ completion: @escaping (Result<PutioAccount, PutioSDKError>) -> Void
    ) {
        complete(completion) {
            try await self.getAccountInfo(query: query)
        }
    }

    func searchFiles(
        keyword: String,
        perPage: Int? = 50,
        _ completion: @escaping (Result<PutioFileSearchResponse, PutioSDKError>) -> Void
    ) {
        complete(completion) {
            try await self.searchFiles(query: PutioFileSearchQuery(keyword: keyword, perPage: perPage))
        }
    }

    func getConfig(_ completion: @escaping (Result<AppConfig, PutioSDKError>) -> Void) {
        complete(completion) {
            try await self.getConfig(as: AppConfig.self)
        }
    }

    func setChromecastPlaybackType(
        _ playbackType: PutioChromecastPlaybackType,
        _ completion: @escaping (Result<PutioOKResponse, PutioSDKError>) -> Void
    ) {
        complete(completion) {
            try await self.setConfigValue(key: AppConfig.CodingKeys.chromecastPlaybackType.rawValue, playbackType)
        }
    }

    func setAutoRotateVideo(
        _ enabled: Bool,
        _ completion: @escaping (Result<PutioOKResponse, PutioSDKError>) -> Void
    ) {
        complete(completion) {
            try await self.setConfigValue(key: AppConfig.CodingKeys.autoRotateVideo.rawValue, enabled)
        }
    }

    func setUsesPutioCastReceiver(
        _ enabled: Bool,
        _ completion: @escaping (Result<PutioOKResponse, PutioSDKError>) -> Void
    ) {
        complete(completion) {
            try await self.setConfigValue(key: AppConfig.CodingKeys.usesPutioCastReceiver.rawValue, enabled)
        }
    }

    func markProductAnalyticsPromptAnswered(_ completion: @escaping (Result<PutioOKResponse, PutioSDKError>) -> Void) {
        complete(completion) {
            try await self.setConfigValue(key: AppConfig.CodingKeys.productAnalyticsPromptAnswered.rawValue, true)
        }
    }

    func getFiles(
        parentID: Int,
        query: PutioFilesListQuery = PutioFilesListQuery(),
        completion: @escaping (Result<PutioFilesListResult, PutioSDKError>) -> Void
    ) {
        complete(completion) {
            try await self.getFiles(parentID: parentID, query: query)
        }
    }

    func getFile(
        fileID: Int,
        query: PutioFileDetailsQuery,
        _ completion: @escaping (Result<PutioFile, PutioSDKError>) -> Void
    ) {
        complete(completion) {
            try await self.getFile(fileID: fileID, query: query)
        }
    }

    func getFile(fileID: Int, _ completion: @escaping (Result<PutioFile, PutioSDKError>) -> Void) {
        getFile(fileID: fileID, query: PutioFileDetailsQuery(), completion)
    }

    func createFolder(
        name: String,
        parentID: Int,
        completion: @escaping (Result<PutioFile, PutioSDKError>) -> Void
    ) {
        complete(completion) {
            try await self.createFolder(name: name, parentID: parentID)
        }
    }

    func deleteFile(fileID: Int, _ completion: @escaping (Result<PutioOKResponse, PutioSDKError>) -> Void) {
        complete(completion) {
            try await self.deleteFiles(fileIDs: [fileID])
        }
    }

    func deleteFiles(fileIDs: [Int], _ completion: @escaping (Result<PutioOKResponse, PutioSDKError>) -> Void) {
        complete(completion) {
            try await self.deleteFiles(fileIDs: fileIDs)
        }
    }

    func copyFile(fileID: Int, _ completion: @escaping (Result<PutioOKResponse, PutioSDKError>) -> Void) {
        complete(completion) {
            try await self.copyFiles(fileIDs: [fileID])
        }
    }

    func moveFiles(
        fileIDs: [Int],
        parentID: Int,
        _ completion: @escaping (Result<PutioFilesMoveResponse, PutioSDKError>) -> Void
    ) {
        complete(completion) {
            try await self.moveFiles(fileIDs: fileIDs, parentID: parentID)
        }
    }

    func renameFile(fileID: Int, name: String, _ completion: @escaping (Result<PutioOKResponse, PutioSDKError>) -> Void) {
        complete(completion) {
            try await self.renameFile(fileID: fileID, name: name)
        }
    }

    func findNextFile(
        fileID: Int,
        fileType: PutioNextFileType,
        _ completion: @escaping (Result<PutioNextFile, PutioSDKError>) -> Void
    ) {
        complete(completion) {
            try await self.findNextFile(fileID: fileID, fileType: fileType)
        }
    }

    func setSortBy(fileId: Int, sortBy: String, _ completion: @escaping (Result<PutioOKResponse, PutioSDKError>) -> Void) {
        complete(completion) {
            try await self.setSortBy(fileId: fileId, sortBy: sortBy)
        }
    }

    func resetFileSpecificSortSettings(_ completion: @escaping (Result<PutioOKResponse, PutioSDKError>) -> Void) {
        complete(completion) {
            try await self.resetFileSpecificSortSettings()
        }
    }

    func getSubtitles(fileID: Int, _ completion: @escaping (Result<PutioSubtitlesResponse, PutioSDKError>) -> Void) {
        complete(completion) {
            try await self.getSubtitles(fileID: fileID)
        }
    }

    func startMp4Conversion(fileID: Int, _ completion: @escaping (Result<PutioOKResponse, PutioSDKError>) -> Void) {
        complete(completion) {
            try await self.startMp4Conversion(fileID: fileID)
        }
    }

    func getMp4ConversionStatus(fileID: Int, _ completion: @escaping (Result<PutioMp4Conversion, PutioSDKError>) -> Void) {
        complete(completion) {
            try await self.getMp4ConversionStatus(fileID: fileID)
        }
    }

    func getStartFrom(fileID: Int, _ completion: @escaping (Result<Int, PutioSDKError>) -> Void) {
        complete(completion) {
            try await self.getStartFrom(fileID: fileID)
        }
    }

    func setStartFrom(fileID: Int, time: Int, completion: @escaping PutioSDKBoolCompletion) {
        complete(completion) {
            try await self.setStartFrom(fileID: fileID, time: time)
        }
    }

    func resetStartFrom(fileID: Int, completion: @escaping PutioSDKBoolCompletion) {
        complete(completion) {
            try await self.resetStartFrom(fileID: fileID)
        }
    }

    func getRoutes(_ completion: @escaping (Result<[PutioRoute], PutioSDKError>) -> Void) {
        complete(completion) {
            try await self.getRoutes()
        }
    }

    func saveAccountSettings(_ update: PutioAccountSettingsUpdate, _ completion: @escaping (Result<PutioOKResponse, PutioSDKError>) -> Void) {
        complete(completion) {
            try await self.saveAccountSettings(update)
        }
    }

    func clearAccountData(
        options: PutioAccountClearOptions,
        _ completion: @escaping (Result<PutioOKResponse, PutioSDKError>) -> Void
    ) {
        complete(completion) {
            try await self.clearAccountData(options: options)
        }
    }

    func destroyAccount(
        currentPassword: String,
        _ completion: @escaping (Result<PutioOKResponse, PutioSDKError>) -> Void
    ) {
        complete(completion) {
            try await self.destroyAccount(currentPassword: currentPassword)
        }
    }

    func listTrash(_ completion: @escaping (Result<PutioListTrashResponse, PutioSDKError>) -> Void) {
        complete(completion) {
            try await self.listTrash()
        }
    }

    func emptyTrash(_ completion: @escaping (Result<PutioOKResponse, PutioSDKError>) -> Void) {
        complete(completion) {
            try await self.emptyTrash()
        }
    }

    func restoreTrashFiles(
        fileIDs: [Int] = [],
        cursor: String?,
        _ completion: @escaping (Result<PutioOKResponse, PutioSDKError>) -> Void
    ) {
        complete(completion) {
            try await self.restoreTrashFiles(fileIDs: fileIDs, cursor: cursor)
        }
    }

    func deleteTrashFiles(
        fileIDs: [Int] = [],
        cursor: String?,
        _ completion: @escaping (Result<PutioOKResponse, PutioSDKError>) -> Void
    ) {
        complete(completion) {
            try await self.deleteTrashFiles(fileIDs: fileIDs, cursor: cursor)
        }
    }

    func getHistoryEvents(completion: @escaping (Result<[PutioHistoryEvent], PutioSDKError>) -> Void) {
        complete(completion) {
            try await self.getHistoryEvents().events
        }
    }

    func clearHistoryEvents(_ completion: @escaping (Result<PutioOKResponse, PutioSDKError>) -> Void) {
        complete(completion) {
            try await self.clearHistoryEvents()
        }
    }

    func deleteHistoryEvent(
        eventID: Int,
        _ completion: @escaping (Result<PutioOKResponse, PutioSDKError>) -> Void
    ) {
        complete(completion) {
            try await self.deleteHistoryEvent(eventID: eventID)
        }
    }

    func getGrants(_ completion: @escaping (Result<[PutioOAuthGrant], PutioSDKError>) -> Void) {
        complete(completion) {
            try await self.getGrants()
        }
    }

    func revokeGrant(id: Int, _ completion: @escaping (Result<PutioOKResponse, PutioSDKError>) -> Void) {
        complete(completion) {
            try await self.revokeGrant(id: id)
        }
    }

    func linkDevice(code: String, _ completion: @escaping (Result<PutioOAuthGrant, PutioSDKError>) -> Void) {
        complete(completion) {
            try await self.linkDevice(code: code)
        }
    }

    func sendIFTTTEvent(
        event: PutioIFTTTEvent,
        completion: @escaping (Result<PutioOKResponse, PutioSDKError>) -> Void
    ) {
        complete(completion) {
            try await self.sendIFTTTEvent(event: event)
        }
    }

    func generateTOTP(_ completion: @escaping (Result<PutioGenerateTOTPResult, PutioSDKError>) -> Void) {
        complete(completion) {
            try await self.generateTOTP()
        }
    }

    func getRecoveryCodes(_ completion: @escaping (Result<PutioTwoFactorRecoveryCodes, PutioSDKError>) -> Void) {
        complete(completion) {
            try await self.getRecoveryCodes()
        }
    }

    func regenerateRecoveryCodes(_ completion: @escaping (Result<PutioTwoFactorRecoveryCodes, PutioSDKError>) -> Void) {
        complete(completion) {
            try await self.regenerateRecoveryCodes()
        }
    }
}
