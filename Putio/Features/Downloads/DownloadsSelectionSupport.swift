import Foundation

struct DownloadsSelectionState {
    private(set) var selectedIDs = Set<Int>()

    var count: Int {
        selectedIDs.count
    }

    func contains(_ id: Int) -> Bool {
        selectedIDs.contains(id)
    }

    func hasSelectedAll(_ selectableIDs: [Int]) -> Bool {
        !selectableIDs.isEmpty && selectedIDs == Set(selectableIDs)
    }

    mutating func select(_ id: Int, isCompleted: Bool) {
        guard isCompleted else { return }
        selectedIDs.insert(id)
    }

    mutating func deselect(_ id: Int) {
        selectedIDs.remove(id)
    }

    mutating func selectAll(_ selectableIDs: [Int]) {
        selectedIDs = Set(selectableIDs)
    }

    mutating func retain(_ ids: [Int]) {
        selectedIDs.formIntersection(ids)
    }

    mutating func clear() {
        selectedIDs.removeAll()
    }
}

struct DownloadDeletionItem: Equatable {
    let id: Int
    let name: String
    let fileType: Download.FileType
}

enum DownloadsBulkDeletion {
    private static let maximumNamedFailures = 3

    static func failures(
        deleting items: [DownloadDeletionItem],
        with delete: (Int, Download.FileType) -> Bool
    ) -> [DownloadDeletionItem] {
        items.filter { !delete($0.id, $0.fileType) }
    }

    static func failureNamesSummary(_ failures: [DownloadDeletionItem]) -> String {
        var parts = failures.prefix(maximumNamedFailures).map(\.name)
        let remainingCount = failures.count - parts.count
        if remainingCount > 0 {
            parts.append(
                String(
                    format: NSLocalizedString("%d more", comment: ""),
                    remainingCount
                )
            )
        }

        return parts.formatted(.list(type: .and))
    }
}
