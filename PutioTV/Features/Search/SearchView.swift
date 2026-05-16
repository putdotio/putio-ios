import SwiftUI
import PutioSDK

/// Search rendered with the system `.searchable` modifier so tvOS owns the
/// full-screen search keyboard, dictation, and focus.
struct SearchView: View {
    let container: AppContainer
    @Binding var path: [HomeDestination]
    @State private var viewModel: SearchViewModel

    init(container: AppContainer, path: Binding<[HomeDestination]>) {
        self.container = container
        self._path = path
        _viewModel = State(initialValue: SearchViewModel(files: container.files))
    }

    var body: some View {
        @Bindable var vm = viewModel
        content
            .searchable(text: $vm.keyword, prompt: Text("Search your files"))
    }

    @ViewBuilder
    private var content: some View {
        switch viewModel.state {
        case .idle:
            ContentUnavailableView(
                "Search your files",
                systemImage: "magnifyingglass",
                description: Text("Find anything in your put.io library.")
            )
        case .searching:
            ProgressView()
                .controlSize(.large)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case let .results(files):
            List(files, id: \.id) { file in
                Button {
                    if file.type == .folder {
                        path.append(HomeDestination(route: .files(parentID: file.id)))
                    } else {
                        container.player.present(fileID: file.id)
                    }
                } label: {
                    FileRowLabel(file: file)
                }
            }
        case let .empty(keyword):
            ContentUnavailableView.search(text: keyword)
        case let .failed(failure):
            PutErrorState(failure: failure)
        }
    }
}
