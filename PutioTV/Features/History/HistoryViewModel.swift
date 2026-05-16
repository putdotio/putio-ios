import Foundation
import Observation
import PutioSDK

@MainActor
@Observable
final class HistoryViewModel {
    enum State: Equatable {
        case loading
        case loaded([HistoryGroup])
        case empty
        case failed(LocalizedFailure)
    }

    private(set) var state: State = .loading
    private let repository: HistoryRepositoryProtocol

    init(repository: HistoryRepositoryProtocol) {
        self.repository = repository
    }

    func load() {
        state = .loading
        Task { [weak self] in
            guard let self else { return }
            do {
                let events = try await repository.events()
                let items = HistoryGrouping.tvFiltered(events)
                let groups = HistoryGrouping.grouped(items)
                state = groups.isEmpty ? .empty : .loaded(groups)
            } catch {
                state = .failed(ErrorMapping.localize(error, retry: { [weak self] in self?.load() }))
            }
        }
    }

    func clear() {
        Task { [weak self] in
            guard let self else { return }
            do {
                try await repository.clear()
                state = .empty
            } catch {
                state = .failed(ErrorMapping.localize(error, retry: { [weak self] in self?.clear() }))
            }
        }
    }
}
