import SwiftUI
import Observation
import PutioSDK

/// Trash screen. Matches `13-trash-empty`: empty-state copy reinforces the
/// 14-day retention rule; non-empty trash shows a list with Restore + Empty
/// Trash actions.
@MainActor
@Observable
final class TrashViewModel {
    enum State {
        case loading
        case loaded([PutioTrashFile])
        case empty
        case failed(LocalizedFailure)
    }

    private(set) var state: State = .loading
    private let repository: TrashRepositoryProtocol

    init(repository: TrashRepositoryProtocol) { self.repository = repository }

    func load() {
        state = .loading
        Task { [weak self] in
            guard let self else { return }
            do {
                let response = try await repository.list()
                state = response.files.isEmpty ? .empty : .loaded(response.files)
            } catch {
                state = .failed(ErrorMapping.localize(error, retry: { [weak self] in self?.load() }))
            }
        }
    }

    func restore(fileID: Int) {
        Task { [weak self] in
            guard let self else { return }
            do {
                try await repository.restore(fileIDs: [fileID])
                load()
            } catch {
                state = .failed(ErrorMapping.localize(error, retry: { [weak self] in self?.load() }))
            }
        }
    }

    func empty() {
        Task { [weak self] in
            guard let self else { return }
            do {
                try await repository.empty()
                state = .empty
            } catch {
                state = .failed(ErrorMapping.localize(error, retry: { [weak self] in self?.load() }))
            }
        }
    }
}

struct TrashView: View {
    let container: AppContainer
    @Binding var path: [HomeDestination]
    @State private var viewModel: TrashViewModel

    init(container: AppContainer, path: Binding<[HomeDestination]>) {
        self.container = container
        self._path = path
        _viewModel = State(initialValue: TrashViewModel(repository: container.trash))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            PutScreenHeader {
                Text("Trash")
            } trailing: {
                if case .loaded = viewModel.state {
                    PutGlassToolbar {
                        Button(role: .destructive) {
                            viewModel.empty()
                        } label: {
                            Label("Empty trash", systemImage: "trash.slash")
                                .labelStyle(.titleAndIcon)
                        }
                    }
                }
            }

            content
        }
        .background(Color.put.bg)
        .onAppear { viewModel.load() }
    }

    @ViewBuilder
    private var content: some View {
        switch viewModel.state {
        case .loading:
            PutLoadingState()
        case let .loaded(files):
            ScrollView {
                LazyVStack(spacing: PutSpacing.xs) {
                    ForEach(files, id: \.id) { file in
                        Button {
                            viewModel.restore(fileID: file.id)
                        } label: {
                            PutListRow(
                                icon: "rotate-ccw",
                                title: file.name,
                                subtitle: subtitle(for: file),
                                trailing: "Restore"
                            )
                        }
                        .buttonStyle(PutFocusableRowStyle())
                    }
                }
                .padding(.horizontal, PutSpacing.xl)
                .padding(.bottom, PutSpacing.xl)
            }
        case .empty:
            PutEmptyState(
                icon: "trash",
                title: "Trash is empty",
                message: "Deleted files stay in Trash for 14 days, then put.io removes them automatically."
            )
        case let .failed(failure):
            PutErrorState(failure: failure)
        }
    }

    private func subtitle(for file: PutioTrashFile) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return "Expires \(formatter.localizedString(for: file.expiresOn, relativeTo: .now))"
    }
}
