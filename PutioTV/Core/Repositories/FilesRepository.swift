import Foundation
import PutioSDK

protocol FilesRepositoryProtocol: Sendable {
    func list(parentID: Int, sortBy: String?) async throws -> PutioFilesListResult
    func details(fileID: Int) async throws -> PutioFile
    func setSort(fileID: Int, sortBy: String) async throws
    func search(keyword: String) async throws -> PutioFileSearchResponse
    func subtitles(fileID: Int) async throws -> PutioSubtitlesResponse
    func conversionStatus(fileID: Int) async throws -> PutioMp4Conversion
    func startMp4Conversion(fileID: Int) async throws
}

struct FilesRepository: FilesRepositoryProtocol {
    let api: PutioSDK

    func list(parentID: Int, sortBy: String?) async throws -> PutioFilesListResult {
        let query = PutioFilesListQuery(perPage: 200, sortBy: sortBy)
        return try await api.getFiles(parentID: parentID, query: query)
    }

    func details(fileID: Int) async throws -> PutioFile {
        try await api.getFile(fileID: fileID)
    }

    func setSort(fileID: Int, sortBy: String) async throws {
        _ = try await api.setSortBy(fileId: fileID, sortBy: sortBy)
    }

    func search(keyword: String) async throws -> PutioFileSearchResponse {
        try await api.searchFiles(query: PutioFileSearchQuery(keyword: keyword, perPage: 100))
    }

    func subtitles(fileID: Int) async throws -> PutioSubtitlesResponse {
        try await api.getSubtitles(fileID: fileID)
    }

    func conversionStatus(fileID: Int) async throws -> PutioMp4Conversion {
        try await api.getMp4ConversionStatus(fileID: fileID)
    }

    func startMp4Conversion(fileID: Int) async throws {
        _ = try await api.startMp4Conversion(fileID: fileID)
    }
}
