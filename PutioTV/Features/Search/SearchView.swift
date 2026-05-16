import SwiftUI
import PutioSDK

/// Search screen. Empty state matches `07-search-empty`; populated results
/// reuse the same row anatomy as the files screen. Native `TextField`
/// surfaces tvOS dictation / system keyboard automatically.
struct SearchView: View {
    let container: AppContainer
    @Binding var path: [HomeDestination]
    @State private var viewModel: SearchViewModel
    @FocusState private var keyboardFocused: Bool

    init(container: AppContainer, path: Binding<[HomeDestination]>) {
        self.container = container
        self._path = path
        _viewModel = State(initialValue: SearchViewModel(files: container.files))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            PutScreenHeader {
                Text("Search")
            }

            TextField("Search your files", text: $viewModel.keyword)
                .textFieldStyle(.plain)
                .font(.put.label)
                .padding(.horizontal, PutSpacing.xl)
                .focused($keyboardFocused)
                .submitLabel(.search)

            content
        }
        .background(Color.put.bg)
        .onAppear { keyboardFocused = true }
    }

    @ViewBuilder
    private var content: some View {
        switch viewModel.state {
        case .idle:
            PutEmptyState(icon: "search", title: "Tap to start typing")
        case .searching:
            PutLoadingState(title: "Searching")
        case let .results(files):
            ScrollView {
                LazyVStack(spacing: PutSpacing.xs) {
                    ForEach(files, id: \.id) { file in
                        Button {
                            if file.type == .folder {
                                path.append(HomeDestination(route: .files(parentID: file.id)))
                            } else {
                                container.player.present(fileID: file.id)
                            }
                        } label: {
                            PutListRow(
                                icon: rowIcon(for: file),
                                title: file.name,
                                subtitle: subtitle(for: file)
                            )
                        }
                        .buttonStyle(PutFocusableRowStyle())
                    }
                }
                .padding(.horizontal, PutSpacing.xl)
                .padding(.bottom, PutSpacing.xl)
            }
        case let .empty(keyword):
            PutEmptyState(
                icon: "search",
                title: "No results",
                message: "Nothing in your library matched \"\(keyword)\"."
            )
        case let .failed(failure):
            PutErrorState(failure: failure)
        }
    }

    private func rowIcon(for file: PutioFile) -> String {
        switch file.type {
        case .folder: return "folder-closed"
        case .video: return "video"
        case .audio: return "music"
        case .image: return "image"
        case .pdf: return "file-text"
        default: return "file"
        }
    }

    private func subtitle(for file: PutioFile) -> String? {
        if file.type == .folder { return nil }
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: file.size)
    }
}
