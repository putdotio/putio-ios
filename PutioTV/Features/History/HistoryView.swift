import SwiftUI

/// History screen. Matches `08-history`: TV-filtered events grouped by date,
/// `CLEAR` button in the top right.
struct HistoryView: View {
    let container: AppContainer
    @Binding var path: [HomeDestination]
    @State private var viewModel: HistoryViewModel

    init(container: AppContainer, path: Binding<[HomeDestination]>) {
        self.container = container
        self._path = path
        _viewModel = State(initialValue: HistoryViewModel(repository: container.history))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            PutScreenHeader {
                Text("History")
            } trailing: {
                PutGlassToolbar {
                    Button { viewModel.clear() } label: {
                        Label("Clear", systemImage: "trash")
                            .labelStyle(.titleAndIcon)
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
        case let .loaded(groups):
            ScrollView {
                LazyVStack(alignment: .leading, spacing: PutSpacing.md) {
                    ForEach(groups) { group in
                        Text(group.bucket.rawValue)
                            .font(.put.body)
                            .foregroundStyle(Color.put.textSecondary)
                            .padding(.horizontal, PutSpacing.md)
                            .padding(.top, PutSpacing.md)

                        VStack(spacing: PutSpacing.xs) {
                            ForEach(group.items) { item in
                                Button {
                                    if let fileID = item.fileID {
                                        container.player.present(fileID: fileID)
                                    }
                                } label: {
                                    PutListRow(
                                        icon: icon(for: item.kind),
                                        title: item.title,
                                        subtitle: item.subtitle
                                    )
                                }
                                .buttonStyle(PutFocusableRowStyle())
                                .disabled(item.fileID == nil)
                            }
                        }
                    }
                }
                .padding(.horizontal, PutSpacing.xl)
                .padding(.bottom, PutSpacing.xl)
            }
        case .empty:
            PutEmptyState(icon: "history", title: "No recent activity")
        case let .failed(failure):
            PutErrorState(failure: failure)
        }
    }

    private func icon(for kind: HistoryEventViewItem.Kind) -> String {
        switch kind {
        case .completedTransfer: return "circle-check"
        case .sharedFile: return "user"
        case .zipCreated: return "package-open"
        case .uploaded: return "file"
        }
    }
}
