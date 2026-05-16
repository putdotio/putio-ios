import Foundation
import Observation
import PutioSDK

@MainActor
@Observable
final class AccountViewModel {
    struct Snapshot: Equatable {
        let account: PutioAccount
        let settings: PutioAccount.Settings
        let routes: [PutioRoute]

        static func == (lhs: Snapshot, rhs: Snapshot) -> Bool {
            lhs.account.id == rhs.account.id &&
                lhs.settings.routeName == rhs.settings.routeName &&
                lhs.settings.dontAutoSelectSubtitles == rhs.settings.dontAutoSelectSubtitles &&
                lhs.settings.rememberVideoTime == rhs.settings.rememberVideoTime &&
                lhs.settings.trashEnabled == rhs.settings.trashEnabled &&
                lhs.settings.historyEnabled == rhs.settings.historyEnabled &&
                lhs.routes.count == rhs.routes.count
        }
    }

    enum State: Equatable {
        case loading
        case ready(Snapshot)
        case failed(LocalizedFailure)
    }

    private(set) var state: State = .loading
    private let repository: AccountRepositoryProtocol

    init(repository: AccountRepositoryProtocol) {
        self.repository = repository
    }

    func load() {
        state = .loading
        Task { [weak self] in
            guard let self else { return }
            do {
                async let info = repository.info()
                async let settings = repository.settings()
                async let routes = repository.routes()
                let snapshot = try await Snapshot(account: info, settings: settings, routes: routes)
                state = .ready(snapshot)
            } catch {
                state = .failed(ErrorMapping.localize(error, retry: { [weak self] in self?.load() }))
            }
        }
    }

    func updateSettings(_ patch: PutioAccountSettingsPatch) {
        Task { [weak self] in
            guard let self else { return }
            do {
                try await repository.updateSettings(patch)
                load()
            } catch {
                state = .failed(ErrorMapping.localize(error, retry: { [weak self] in self?.load() }))
            }
        }
    }
}
