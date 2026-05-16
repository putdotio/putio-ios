import Foundation
import Observation
import PutioSDK

@MainActor
@Observable
final class FilesViewModel {
    enum State {
        case loading
        case loaded(parent: PutioFile?, children: [PutioFile])
        case empty
        case failed(LocalizedFailure)
    }

    private(set) var state: State = .loading
    private(set) var currentSort: String?

    let parentID: Int
    private let files: FilesRepositoryProtocol

    init(parentID: Int, files: FilesRepositoryProtocol) {
        self.parentID = parentID
        self.files = files
    }

    func load(force: Bool = false) {
        if !force, case .loaded = state { return }
        state = .loading
        refresh()
    }

    func refresh() {
        Task { [weak self] in
            guard let self else { return }
            do {
                let result = try await files.list(parentID: parentID, sortBy: currentSort)
                let children = result.children
                if children.isEmpty {
                    state = .empty
                } else {
                    state = .loaded(parent: result.parent, children: children)
                }
            } catch {
                state = .failed(ErrorMapping.localize(error, retry: { [weak self] in self?.refresh() }))
            }
        }
    }

    func setSort(_ sort: String) {
        currentSort = sort
        state = .loading
        Task { [weak self] in
            guard let self else { return }
            if parentID != 0 {
                try? await files.setSort(fileID: parentID, sortBy: sort)
            }
            refresh()
        }
    }
}

enum FileSort: String, CaseIterable, Identifiable {
    case nameAsc = "NAME_ASC"
    case nameDesc = "NAME_DESC"
    case sizeAsc = "SIZE_ASC"
    case sizeDesc = "SIZE_DESC"
    case dateAsc = "DATE_ASC"
    case dateDesc = "DATE_DESC"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .nameAsc: return "Name A → Z"
        case .nameDesc: return "Name Z → A"
        case .sizeAsc: return "Smallest first"
        case .sizeDesc: return "Largest first"
        case .dateAsc: return "Oldest first"
        case .dateDesc: return "Newest first"
        }
    }
}
