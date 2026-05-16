import SwiftUI
import PutioSDK

@main
struct PutioTVApp: App {
    @State private var container = AppContainer()

    var body: some Scene {
        WindowGroup {
            RootView(container: container)
                .preferredColorScheme(.dark)
                .background(Color.put.surface.ignoresSafeArea())
                .onAppear { container.authSession.restore() }
        }
    }
}

struct RootView: View {
    let container: AppContainer
    @State private var navigationPath: [HomeDestination] = []
    @State private var accountSettings: PutioAccount.Settings?

    var body: some View {
        switch container.authSession.state {
        case .linked:
            NavigationStack(path: $navigationPath) {
                HomeView(
                    container: container,
                    path: $navigationPath,
                    accountSettings: accountSettings
                )
                .navigationDestination(for: HomeDestination.self) { destination in
                    destinationView(for: destination)
                }
            }
            .task { await loadSettings() }
        default:
            AuthCodeView(session: container.authSession)
        }
    }

    @ViewBuilder
    private func destinationView(for destination: HomeDestination) -> some View {
        switch destination.route {
        case let .files(parentID):
            FilesView(container: container, path: $navigationPath, parentID: parentID)
        case .search:
            SearchView(container: container, path: $navigationPath)
        case .history:
            HistoryView(container: container, path: $navigationPath)
        case .account:
            AccountView(container: container, path: $navigationPath)
        case .trash:
            TrashView(container: container, path: $navigationPath)
        case .diagnostics:
            DiagnosticsView()
        case let .player(fileID):
            PlayerView(container: container, fileID: fileID)
        }
    }

    private func loadSettings() async {
        do {
            accountSettings = try await container.account.settings()
        } catch {
            accountSettings = nil
        }
    }
}
