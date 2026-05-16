import Foundation
import Observation
import PutioSDK

@MainActor
@Observable
final class SearchViewModel {
    enum State {
        case idle
        case searching
        case results([PutioFile])
        case empty(keyword: String)
        case failed(LocalizedFailure)
    }

    private(set) var state: State = .idle
    var keyword: String = "" {
        didSet { scheduleSearch() }
    }

    private let files: FilesRepositoryProtocol
    private var searchTask: Task<Void, Never>?

    init(files: FilesRepositoryProtocol) {
        self.files = files
    }

    private func scheduleSearch() {
        let trimmed = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        searchTask?.cancel()

        guard !trimmed.isEmpty else {
            state = .idle
            return
        }

        state = .searching
        searchTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            guard let self, !Task.isCancelled else { return }
            do {
                let response = try await files.search(keyword: trimmed)
                guard !Task.isCancelled else { return }
                state = response.files.isEmpty ? .empty(keyword: trimmed) : .results(response.files)
            } catch is CancellationError {
                return
            } catch {
                state = .failed(ErrorMapping.localize(error, retry: { [weak self] in self?.scheduleSearch() }))
            }
        }
    }
}
