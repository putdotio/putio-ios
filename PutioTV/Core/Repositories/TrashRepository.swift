import Foundation
import PutioSDK

protocol TrashRepositoryProtocol: Sendable {
    func list() async throws -> PutioListTrashResponse
    func restore(fileIDs: [Int]) async throws
    func empty() async throws
}

struct TrashRepository: TrashRepositoryProtocol {
    let api: PutioSDK

    func list() async throws -> PutioListTrashResponse {
        try await api.listTrash(query: PutioTrashListQuery(perPage: 100))
    }

    func restore(fileIDs: [Int]) async throws {
        _ = try await api.restoreTrashFiles(fileIDs: fileIDs, cursor: nil)
    }

    func empty() async throws {
        _ = try await api.emptyTrash()
    }
}
