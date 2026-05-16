import SwiftUI
import Observation
import PutioSDK

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

/// Trash rendered with `List` + `.navigationTitle`. Empty state and the
/// 14-day retention copy live in `ContentUnavailableView`. The `Empty trash`
/// action is in the toolbar and confirmed via `.confirmationDialog`.
struct TrashView: View {
    let container: AppContainer
    @Binding var path: [HomeDestination]
    @State private var viewModel: TrashViewModel
    @State private var confirmEmpty = false
    @State private var pendingFile: PutioTrashFile?

    init(container: AppContainer, path: Binding<[HomeDestination]>) {
        self.container = container
        self._path = path
        _viewModel = State(initialValue: TrashViewModel(repository: container.trash))
    }

    var body: some View {
        content
            .navigationTitle("Trash")
            .toolbar { toolbarItems }
            .confirmationDialog(
                "Empty Trash?",
                isPresented: $confirmEmpty,
                titleVisibility: .visible
            ) {
                Button("Empty Trash", role: .destructive) { viewModel.empty() }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Everything in Trash will be permanently deleted.")
            }
            .confirmationDialog(
                pendingFile?.name ?? "",
                isPresented: Binding(get: { pendingFile != nil }, set: { if !$0 { pendingFile = nil } }),
                titleVisibility: .visible
            ) {
                if let file = pendingFile {
                    Button("Restore") {
                        viewModel.restore(fileID: file.id)
                        pendingFile = nil
                    }
                    Button("Cancel", role: .cancel) { pendingFile = nil }
                }
            }
            .onAppear { viewModel.load() }
    }

    @ToolbarContentBuilder
    private var toolbarItems: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            if case .loaded = viewModel.state {
                Button(role: .destructive) {
                    confirmEmpty = true
                } label: {
                    Label("Empty Trash", systemImage: "trash.slash")
                }
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch viewModel.state {
        case .loading:
            ProgressView()
                .controlSize(.large)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case let .loaded(files):
            List(files, id: \.id) { file in
                Button {
                    pendingFile = file
                } label: {
                    TrashRowLabel(file: file)
                }
            }
        case .empty:
            ContentUnavailableView(
                "Your trash is empty",
                systemImage: "trash",
                description: Text("When you send files to trash, we keep them here for 14 days.")
            )
        case let .failed(failure):
            PutErrorState(failure: failure)
        }
    }
}

private struct TrashRowLabel: View {
    let file: PutioTrashFile

    var body: some View {
        HStack(spacing: PutSpacing.md) {
            Image(systemName: "trash")
                .font(.system(size: 36))
                .foregroundStyle(Color.put.yellowSolid)
                .frame(width: 48, height: 48)
            VStack(alignment: .leading, spacing: 2) {
                Text(file.name).lineLimit(1)
                Text(expiryText)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: PutSpacing.md)
        }
        .padding(.vertical, PutSpacing.xs)
    }

    private var expiryText: String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return "Expires \(formatter.localizedString(for: file.expiresOn, relativeTo: .now))"
    }
}
