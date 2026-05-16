import SwiftUI
import PutioSDK

struct HomeDestination: Hashable {
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

/// Top-level menu: Your Files / Search / History / Account.
/// Matches the `03-home` exported tvOS screenshot.
struct HomeView: View {
    let container: AppContainer
    @Binding var path: [HomeDestination]
    let accountSettings: PutioAccount.Settings?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            PutScreenHeader {
                Label {
                    Text("put.io")
                } icon: {
                    LucideIcon(name: "tv", size: 56)
                        .foregroundStyle(Color.put.accentYellow)
                }
            }

            ScrollView {
                LazyVStack(spacing: PutSpacing.xs) {
                    homeButton(icon: "folder-closed", title: "Your Files") {
                        path.append(HomeDestination(route: .files(parentID: 0)))
                    }
                    homeButton(icon: "search", title: "Search") {
                        path.append(HomeDestination(route: .search))
                    }
                    if accountSettings?.historyEnabled ?? true {
                        homeButton(icon: "history", title: "History") {
                            path.append(HomeDestination(route: .history))
                        }
                    }
                    homeButton(icon: "user", title: "Account") {
                        path.append(HomeDestination(route: .account))
                    }
                }
                .padding(.horizontal, PutSpacing.xl)
                .padding(.bottom, PutSpacing.xl)
            }
        }
        .background(Color.put.surface)
    }

    private func homeButton(icon: String, title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            PutListRow(icon: icon, title: title)
        }
        .buttonStyle(PutFocusableRowStyle())
    }
}
