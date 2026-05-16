import SwiftUI
import PutioSDK

@main
struct PutioTVApp: App {
    @State private var container = AppContainer()

    var body: some Scene {
        WindowGroup {
            RootView(container: container)
                .preferredColorScheme(.dark)
                .background(Color.put.bg.ignoresSafeArea())
                .onAppear { container.authSession.restore() }
        }
    }
}

/// Top-level shell. The signed-in surface uses tvOS's system top tab bar
/// (`TabView`), with `Your Files` as the launch tab. Each tab owns its own
/// `NavigationStack` so drilling into folders or the player only affects the
/// active tab.
struct RootView: View {
    let container: AppContainer
    @State private var accountSettings: PutioAccount.Settings?

    var body: some View {
        switch container.authSession.state {
        case .linked:
            MainTabs(
                container: container,
                historyEnabled: accountSettings?.historyEnabled ?? true
            )
            .task { await loadSettings() }
        default:
            AuthCodeView(session: container.authSession)
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

struct MainTabs: View {
    let container: AppContainer
    let historyEnabled: Bool

    @State private var filesPath: [TabDestination] = []
    @State private var searchPath: [TabDestination] = []
    @State private var historyPath: [TabDestination] = []
    @State private var accountPath: [TabDestination] = []
    @State private var selected: Tab = Tab.fromEnv()

    enum Tab: Hashable {
        case files, search, history, account

        static func fromEnv() -> Tab {
            #if DEBUG
            switch ProcessInfo.processInfo.environment["PUTIO_INITIAL_TAB"] {
            case "search": return .search
            case "history": return .history
            case "account": return .account
            default: return .files
            }
            #else
            return .files
            #endif
        }
    }

    var body: some View {
        TabView(selection: $selected) {
            NavigationStack(path: $filesPath) {
                FilesView(container: container, path: $filesPath, parentID: 0)
                    .navigationDestination(for: TabDestination.self, destination: tabDestination)
            }
            .tabItem { Label("Your Files", systemImage: "folder.fill") }
            .tag(Tab.files)

            NavigationStack(path: $searchPath) {
                SearchView(container: container, path: $searchPath)
                    .navigationDestination(for: TabDestination.self, destination: tabDestination)
            }
            .tabItem { Label("Search", systemImage: "magnifyingglass") }
            .tag(Tab.search)

            if historyEnabled {
                NavigationStack(path: $historyPath) {
                    HistoryView(container: container, path: $historyPath)
                        .navigationDestination(for: TabDestination.self, destination: tabDestination)
                }
                .tabItem { Label("History", systemImage: "clock.arrow.circlepath") }
                .tag(Tab.history)
            }

            NavigationStack(path: $accountPath) {
                AccountView(container: container, path: $accountPath)
                    .navigationDestination(for: TabDestination.self, destination: tabDestination)
            }
            .tabItem { Label("Account", systemImage: "person.crop.circle") }
            .tag(Tab.account)
        }
        .fullScreenCover(item: Bindable(container.player).presented) { request in
            PlayerView(container: container, fileID: request.fileID)
                .background(Color.black.ignoresSafeArea())
                .onDisappear { container.player.dismiss() }
        }
    }

    @ViewBuilder
    private func tabDestination(_ destination: TabDestination) -> some View {
        switch destination.route {
        case let .files(parentID):
            FilesView(container: container, path: bindingForActiveTab, parentID: parentID)
        case .search:
            SearchView(container: container, path: bindingForActiveTab)
        case .history:
            HistoryView(container: container, path: bindingForActiveTab)
        case .account:
            AccountView(container: container, path: bindingForActiveTab)
        case .trash:
            TrashView(container: container, path: bindingForActiveTab)
        case .diagnostics:
            DiagnosticsView()
        case let .player(fileID):
            PlayerView(container: container, fileID: fileID)
        }
    }

    private var bindingForActiveTab: Binding<[TabDestination]> {
        switch selected {
        case .files: return $filesPath
        case .search: return $searchPath
        case .history: return $historyPath
        case .account: return $accountPath
        }
    }
}

/// Per-tab navigation destination. Same shape as the old `HomeDestination`
/// (renamed for the tab-shell era).
struct TabDestination: Hashable {
    enum Route: Hashable {
        case files(parentID: Int)
        case search
        case history
        case account
        case trash
        case diagnostics
        case player(fileID: Int)
    }

    let route: Route
}

/// Compatibility alias. Existing feature views accept `Binding<[HomeDestination]>`
/// — keep that signature working by aliasing the type rather than touching
/// every call site.
typealias HomeDestination = TabDestination
