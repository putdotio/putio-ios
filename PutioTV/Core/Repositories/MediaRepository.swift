import Foundation
import PutioSDK

protocol MediaRepositoryProtocol: Sendable {
    func startFrom(fileID: Int) async throws -> Int
    func setStartFrom(fileID: Int, seconds: Int) async throws
    func resetStartFrom(fileID: Int) async throws
}

struct MediaRepository: MediaRepositoryProtocol {
    let api: PutioSDK

    func startFrom(fileID: Int) async throws -> Int {
        try await api.getStartFrom(fileID: fileID)
    }

    func setStartFrom(fileID: Int, seconds: Int) async throws {
        _ = try await api.setStartFrom(fileID: fileID, time: seconds)
    }

    func resetStartFrom(fileID: Int) async throws {
        _ = try await api.resetStartFrom(fileID: fileID)
    }
}
