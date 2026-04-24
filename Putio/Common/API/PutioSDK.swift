import Foundation
import PutioSDK
import SwiftyJSON

let api = PutioSDK(config: PutioSDKConfig(
    clientID: PUTIOKIT_CLIENT_ID,
    clientName: UIDevice.current.name)
)

typealias PutioSDKBoolCompletion = (Result<PutioOKResponse, PutioSDKError>) -> Void

struct PutioRawAPIError: PutioErrorLocalizableInput {
    let localizerType: PutioSDKErrorType
    let localizerMessage: String
    let underlyingError: Error
}

enum PutioAppAPIError: PutioErrorLocalizableInput {
    case sdk(PutioSDKError)
    case raw(PutioRawAPIError)

    var localizerType: PutioSDKErrorType {
        switch self {
        case .sdk(let error):
            return error.localizerType
        case .raw(let error):
            return error.localizerType
        }
    }

    var localizerMessage: String {
        switch self {
        case .sdk(let error):
            return error.localizerMessage
        case .raw(let error):
            return error.localizerMessage
        }
    }
}

extension PutioMp4Conversion {
    typealias Status = PutioMp4ConversionStatus
}

extension PutioListTrashResponse {
    var trash_size: Int64 { trashSize }
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

    func get(_ path: String, _ completion: @escaping (Result<JSON, PutioRawAPIError>) -> Void) {
        rawJSONRequest(path, method: "GET", completion: completion)
    }

    func put(_ path: String, body: [String: Any], _ completion: @escaping (Result<JSON, PutioRawAPIError>) -> Void) {
        rawJSONRequest(path, method: "PUT", body: body, completion: completion)
    }

    private func rawJSONRequest(
        _ path: String,
        method: String,
        body: [String: Any]? = nil,
        completion: @escaping (Result<JSON, PutioRawAPIError>) -> Void
    ) {
        let trimmedBaseURL = config.baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let trimmedPath = path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let url = URL(string: "\(trimmedBaseURL)/\(trimmedPath)") else {
            completion(.failure(PutioRawAPIError(
                localizerType: .unknownError,
                localizerMessage: NSLocalizedString("Unable to build put.io request URL.", comment: ""),
                underlyingError: URLError(.badURL)
            )))
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = config.timeoutInterval
        if !config.token.isEmpty {
            request.setValue("token \(config.token)", forHTTPHeaderField: "Authorization")
        }

        if let body {
            do {
                request.httpBody = try JSONSerialization.data(withJSONObject: body)
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            } catch {
                completion(.failure(PutioRawAPIError(
                    localizerType: .unknownError,
                    localizerMessage: error.localizedDescription,
                    underlyingError: error
                )))
                return
            }
        }

        Task {
            do {
                let (data, response) = try await URLSession.shared.data(for: request)
                guard let httpResponse = response as? HTTPURLResponse else {
                    await MainActor.run {
                        completion(.failure(PutioRawAPIError(
                            localizerType: .unknownError,
                            localizerMessage: NSLocalizedString("put.io returned an invalid response.", comment: ""),
                            underlyingError: URLError(.badServerResponse)
                        )))
                    }
                    return
                }

                let json = try JSON(data: data)
                guard (200..<300).contains(httpResponse.statusCode) else {
                    await MainActor.run {
                        completion(.failure(PutioRawAPIError(
                            localizerType: .httpError(statusCode: httpResponse.statusCode, errorType: json["error_type"].string),
                            localizerMessage: json["message"].string ?? json["error_message"].string ?? "put.io returned HTTP \(httpResponse.statusCode)",
                            underlyingError: URLError(.badServerResponse)
                        )))
                    }
                    return
                }

                await MainActor.run {
                    completion(.success(json))
                }
            } catch {
                await MainActor.run {
                    completion(.failure(PutioRawAPIError(
                        localizerType: .networkError,
                        localizerMessage: error.localizedDescription,
                        underlyingError: error
                    )))
                }
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

    func getFiles(
        parentID: Int,
        query: [String: Any] = [:],
        completion: @escaping (Result<PutioFilesListResult, PutioSDKError>) -> Void
    ) {
        complete(completion) {
            try await self.getFiles(parentID: parentID, query: PutioFilesListQuery(contentType: query["content_type"] as? String))
        }
    }

    func getFile(fileID: Int, _ completion: @escaping (Result<PutioFile, PutioSDKError>) -> Void) {
        complete(completion) {
            try await self.getFile(fileID: fileID)
        }
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

    func getSubtitles(fileID: Int, _ completion: @escaping (Result<[PutioSubtitle], PutioSDKError>) -> Void) {
        complete(completion) {
            try await self.getSubtitles(fileID: fileID).subtitles
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

    func saveAccountSettings(
        body: [String: Any],
        _ completion: @escaping (Result<PutioOKResponse, PutioSDKError>) -> Void
    ) {
        complete(completion) {
            try await self.saveAccountSettings(accountSettingsUpdate(from: body))
        }
    }

    func clearAccountData(
        options: [String: Bool],
        _ completion: @escaping (Result<PutioOKResponse, PutioSDKError>) -> Void
    ) {
        complete(completion) {
            try await self.clearAccountData(options: PutioAccountClearOptions(
                files: options["files"] ?? false,
                finishedTransfers: options["finished_transfers"] ?? false,
                activeTransfers: options["active_transfers"] ?? false,
                rssFeeds: options["rss_feeds"] ?? false,
                rssLogs: options["rss_logs"] ?? false,
                history: options["history"] ?? false,
                trash: options["trash"] ?? false,
                friends: options["friends"] ?? false
            ))
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

private func accountSettingsUpdate(from body: [String: Any]) -> PutioAccountSettingsUpdate {
    if let twoFactor = body["two_factor_enabled"] as? [String: Any],
       let code = twoFactor["code"] as? String,
       let enable = boolValue(twoFactor, key: "enable") {
        return .twoFactor(PutioTwoFactorSettings(code: code, enable: enable))
    }

    return .patch(PutioAccountSettingsPatch(
        historyEnabled: boolValue(body, key: "history_enabled"),
        trashEnabled: boolValue(body, key: "trash_enabled"),
        hideSubtitles: boolValue(body, key: "hide_subtitles"),
        dontAutoSelectSubtitles: boolValue(body, key: "dont_autoselect_subtitles"),
        tunnelRouteName: body["tunnel_route_name"] as? String,
        showOptimisticUsage: boolValue(body, key: "show_optimistic_usage"),
        sortBy: body["sort_by"] as? String
    ))
}

private func boolValue(_ body: [String: Any], key: String) -> Bool? {
    if let value = body[key] as? Bool {
        return value
    }

    if let value = body[key] as? NSNumber {
        return value.boolValue
    }

    return nil
}
