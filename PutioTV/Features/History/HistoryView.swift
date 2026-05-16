import SwiftUI

/// History rendered with a sectioned `List`. Native group headers handle the
/// "Today / Yesterday / Last week / Earlier" buckets. The `CLEAR` action lives
/// in the navigation toolbar and is guarded by a confirmation dialog.
struct HistoryView: View {
    let container: AppContainer
    @Binding var path: [HomeDestination]
    @State private var viewModel: HistoryViewModel
    @State private var confirmClear = false

    init(container: AppContainer, path: Binding<[HomeDestination]>) {
        self.container = container
        self._path = path
        _viewModel = State(initialValue: HistoryViewModel(repository: container.history))
    }

    var body: some View {
        content
            .navigationTitle("History")
            .toolbar { toolbarItems }
            .confirmationDialog(
                "Clear watch history?",
                isPresented: $confirmClear,
                titleVisibility: .visible
            ) {
                Button("Clear history", role: .destructive) { viewModel.clear() }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("You can't undo this.")
            }
            .onAppear { viewModel.load() }
    }

    @ToolbarContentBuilder
    private var toolbarItems: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            if case .loaded = viewModel.state {
                Button(role: .destructive) {
                    confirmClear = true
                } label: {
                    Label("Clear", systemImage: "trash")
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
        case let .loaded(groups):
            List {
                ForEach(groups) { group in
                    Section(group.bucket.rawValue) {
                        ForEach(group.items) { item in
                            historyRow(item: item)
                        }
                    }
                }
            }
        case .empty:
            ContentUnavailableView(
                "This is your history. It's currently empty.",
                systemImage: "clock",
                description: Text("You will see information here once things start happening.")
            )
        case let .failed(failure):
            PutErrorState(failure: failure)
        }
    }

    @ViewBuilder
    private func historyRow(item: HistoryEventViewItem) -> some View {
        if let fileID = item.fileID {
            Button {
                container.player.present(fileID: fileID)
            } label: {
                HistoryRowLabel(item: item)
            }
        } else {
            HistoryRowLabel(item: item)
        }
    }
}

private struct HistoryRowLabel: View {
    let item: HistoryEventViewItem

    var body: some View {
        HStack(spacing: PutSpacing.md) {
            Image(systemName: icon)
                .font(.system(size: 36))
                .foregroundStyle(Color.put.yellowSolid)
                .frame(width: 48, height: 48)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.title).lineLimit(1)
                if let subtitle = item.subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: PutSpacing.md)
        }
        .padding(.vertical, PutSpacing.xs)
    }

    private var icon: String {
        switch item.kind {
        case .completedTransfer: return "checkmark.circle.fill"
        case .sharedFile: return "person.crop.circle.fill.badge.plus"
        }
    }
}
