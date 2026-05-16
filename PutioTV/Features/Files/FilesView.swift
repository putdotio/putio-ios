import SwiftUI
import PutioSDK

/// Folder listing rendered with the system `List` + `.navigationTitle` +
/// `.toolbar` so tvOS owns layout, focus, materials, and the title chrome.
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
        Group {
            switch viewModel.state {
            case .loading:
                ProgressView()
                    .controlSize(.large)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            case let .loaded(_, children):
                List(children, id: \.id) { file in
                    row(for: file)
                }
            case .empty:
                ContentUnavailableView(
                    "Empty folder",
                    systemImage: "folder",
                    description: Text("Add files at put.io to fill this one up.")
                )
            case let .failed(failure):
                PutErrorState(failure: failure)
            }
        }
        .navigationTitle(viewModel.parentID == 0 ? "" : navigationTitle)
        .toolbarTitleDisplayMode(viewModel.parentID == 0 ? .automatic : .inline)
        .toolbar { trailingActions }
        .onAppear { viewModel.load() }
    }

    @ToolbarContentBuilder
    private var trailingActions: some ToolbarContent {
        ToolbarItemGroup(placement: .topBarTrailing) {
            Button {
                viewModel.refresh()
            } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
                    .labelStyle(.iconOnly)
            }
            .help("Refresh")

            Menu {
                ForEach(FileSort.allCases) { sort in
                    Button {
                        viewModel.setSort(sort.rawValue)
                    } label: {
                        if sort.rawValue == viewModel.currentSort {
                            Label(sort.label, systemImage: "checkmark")
                        } else {
                            Text(sort.label)
                        }
                    }
                }
            } label: {
                Label("Sort", systemImage: "arrow.up.arrow.down")
                    .labelStyle(.iconOnly)
            }
            .help("Sort")
        }
    }

    private var sortLabel: String {
        guard let raw = viewModel.currentSort,
              let match = FileSort(rawValue: raw) else { return "Sort" }
        return match.label
    }

    private var navigationTitle: String {
        if case let .loaded(parent, _) = viewModel.state,
           let parent, !parent.name.isEmpty {
            return parent.name
        }
        return viewModel.parentID == 0 ? "Your Files" : "Folder"
    }

    @ViewBuilder
    private func row(for file: PutioFile) -> some View {
        let isFolder = file.type == .folder
        let isVideo = file.type == .video

        Button {
            if isFolder {
                path.append(HomeDestination(route: .files(parentID: file.id)))
            } else {
                container.player.present(fileID: file.id)
            }
        } label: {
            FileRowLabel(file: file)
        }
    }
}

struct FileRowLabel: View {
    let file: PutioFile

    var body: some View {
        HStack(spacing: PutSpacing.md) {
            Image(systemName: icon)
                .font(.system(size: 36))
                .foregroundStyle(.tint)
                .frame(width: 48, height: 48)
            VStack(alignment: .leading, spacing: 2) {
                Text(file.name)
                    .lineLimit(1)
                if let subtitle {
                    Text(subtitle)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: PutSpacing.md)
            if file.type == .video && file.startFrom > 0 {
                Image(systemName: "eye.fill")
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, PutSpacing.xs)
    }

    private var icon: String {
        switch file.type {
        case .folder: return "folder.fill"
        case .video: return "film.fill"
        case .audio: return "music.note"
        case .image: return "photo.fill"
        case .pdf: return "doc.text.fill"
        default: return "doc.fill"
        }
    }

    private var subtitle: String? {
        guard file.type != .folder else { return nil }
        return ByteCountFormatter.string(fromByteCount: file.size, countStyle: .file)
    }
}
