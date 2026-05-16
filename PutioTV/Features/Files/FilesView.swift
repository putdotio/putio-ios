import SwiftUI
import PutioSDK

/// Folder listing. Matches the exported `04-files-root` and `05-files-folder`
/// screenshots: list rows, top-right Sort + Refresh controls, watched
/// indicators on the row.
struct FilesView: View {
    let container: AppContainer
    @Binding var path: [HomeDestination]
    @State private var viewModel: FilesViewModel

    init(container: AppContainer, path: Binding<[HomeDestination]>, parentID: Int) {
        self.container = container
        self._path = path
        _viewModel = State(initialValue: FilesViewModel(parentID: parentID, files: container.files))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header

            switch viewModel.state {
            case .loading:
                PutLoadingState()
            case let .loaded(_, children):
                ScrollView {
                    LazyVStack(spacing: PutSpacing.xs) {
                        ForEach(children, id: \.id) { file in
                            row(for: file)
                        }
                    }
                    .padding(.horizontal, PutSpacing.xl)
                    .padding(.bottom, PutSpacing.xl)
                }
            case .empty:
                PutEmptyState(icon: "folder", title: "Empty folder", message: "Add files at put.io to fill this one up.")
            case let .failed(failure):
                PutErrorState(failure: failure)
            }
        }
        .background(Color.put.bg)
        .onAppear { viewModel.load() }
    }

    private var header: some View {
        PutScreenHeader {
            Text(headerTitle)
        } trailing: {
            PutGlassToolbar {
                Menu {
                    ForEach(FileSort.allCases) { sort in
                        Button(sort.label) { viewModel.setSort(sort.rawValue) }
                    }
                } label: {
                    Label("Sort", systemImage: "arrow.up.arrow.down")
                        .labelStyle(.titleAndIcon)
                }

                Button { viewModel.refresh() } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                        .labelStyle(.titleAndIcon)
                }
            }
        }
    }

    private var headerTitle: String {
        switch viewModel.state {
        case let .loaded(parent, _):
            return parent?.name.isEmpty == false ? parent!.name : "Your Files"
        default:
            return viewModel.parentID == 0 ? "Your Files" : "Folder"
        }
    }

    private func row(for file: PutioFile) -> some View {
        let isFolder = file.type == .folder
        let isVideo = file.type == .video

        return Button {
            if isFolder {
                path.append(HomeDestination(route: .files(parentID: file.id)))
            } else if isVideo {
                container.player.present(fileID: file.id)
            } else {
                // Non-video file: leaf that the player view will render the
                // unsupported-file state for.
                container.player.present(fileID: file.id)
            }
        } label: {
            PutListRow(
                icon: icon(for: file),
                title: file.name,
                subtitle: subtitle(for: file),
                watched: isVideo && file.startFrom > 0
            )
        }
        .buttonStyle(PutFocusableRowStyle())
    }

    private func icon(for file: PutioFile) -> String {
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
