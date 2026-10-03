import PutioCore
import SwiftUI

/// A destination pushed from Home. Some exist only while an account setting
/// allows them.
enum TVRoute: Hashable {
  case files
  case search
  case history
  case account
  case proxy
  case trash
  case folder(PutioFolderRoute)
  case file(PutioFileItem)

  func isAvailable(for account: PutioAccountSnapshot) -> Bool {
    switch self {
    case .history: account.historyEnabled
    case .trash: account.trashEnabled
    case .files, .search, .account, .proxy, .folder, .file: true
    }
  }

  /// Cuts the path at the first destination the account no longer offers, so
  /// turning History or Trash off closes those screens and everything above
  /// them at once.
  static func reconcile(_ path: [TVRoute], account: PutioAccountSnapshot) -> [TVRoute] {
    guard let index = path.firstIndex(where: { !$0.isAvailable(for: account) }) else {
      return path
    }
    return Array(path[..<index])
  }
}

/// The shipped Home list.
enum TVHomeEntry: CaseIterable, Identifiable {
  case files
  case search
  case history
  case account

  var id: Self { self }

  static func entries(for account: PutioAccountSnapshot) -> [TVHomeEntry] {
    allCases.filter { $0.route.isAvailable(for: account) }
  }

  var route: TVRoute {
    switch self {
    case .files: .files
    case .search: .search
    case .history: .history
    case .account: .account
    }
  }

  var title: String {
    switch self {
    case .files: "Your Files"
    case .search: "Search"
    case .history: "History"
    case .account: "Account"
    }
  }

  /// Search keeps the system glyph; the other rows use Phosphor icons.
  var icon: Image {
    switch self {
    case .files: Image(putioIcon: .folderFill)
    case .search: Image(systemName: "magnifyingglass")
    case .history: Image(putioIcon: .clockCounterClockwise)
    case .account: Image(putioIcon: .userCircle)
    }
  }
}

// The 10-foot shell: Home is the root of one stack. Menu pops a pushed
// screen; Menu on Home leaves the app, which is the system contract for a
// root screen.
struct TVSignedInShell: View {
  let runtime: PutioRuntime
  let account: PutioAccountSnapshot

  @Environment(\.scenePhase) private var scenePhase
  @State private var path: [TVRoute] = []
  @State private var trashReconciliation = PutioTrashReconciliation()
  @State private var folderRefreshRequests = PutioFolderRefreshRequests()
  @State private var playbackPositionPipeline = PutioPlaybackPositionPipeline()
  @State private var hasShownHome = false

  var body: some View {
    NavigationStack(path: $path) {
      TVHomeScreen(entries: TVHomeEntry.entries(for: account))
        .onAppear {
          // Returning to Home picks up settings changed on another device,
          // which may hide or reveal History.
          if hasShownHome { Task { await runtime.refreshAccount() } }
          hasShownHome = true
        }
        .navigationDestination(for: TVRoute.self) { route in
          destination(for: route)
        }
    }
    .onChange(of: account) { previous, current in
      PutioAccountPreferencesReconciliation.apply(
        previous: previous, current: current, folders: folderRefreshRequests,
        trash: trashReconciliation)
      path = TVRoute.reconcile(path, account: current)
    }
    // A stale row selected as it disappears must not open a screen the
    // account no longer offers.
    .onChange(of: path) { _, pushed in
      let allowed = TVRoute.reconcile(pushed, account: account)
      if allowed != pushed { path = allowed }
    }
    .onChange(of: scenePhase) { _, phase in
      if phase == .active { Task { await runtime.refreshAccount() } }
    }
  }

  private func open(_ item: PutioFileItem) {
    path.append(.opening(item))
  }

  @ViewBuilder
  private func destination(for route: TVRoute) -> some View {
    switch route {
    case .account:
      TVAccountView(runtime: runtime)
    case .proxy:
      TVProxyChooserView(runtime: runtime)
    case .files:
      TVFolderView(
        route: .root, runtime: runtime, account: account,
        refreshRequests: folderRefreshRequests, open: open)
    case .search:
      TVSearchView(
        runtime: runtime, account: account, refreshRequests: folderRefreshRequests, open: open)
    case .history:
      TVHistoryView(runtime: runtime, open: open)
    case .trash:
      TVTrashView(runtime: runtime, reconciliation: trashReconciliation)
    case .folder(let folder):
      TVFolderView(
        route: folder, runtime: runtime, account: account,
        refreshRequests: folderRefreshRequests, open: open)
    case .file(let item):
      if case .video(let video) = PutioFileRoute(item: item).openAction {
        TVVideoSession(
          route: video, runtime: runtime, account: account, pipeline: playbackPositionPipeline,
          refreshRequests: folderRefreshRequests)
      } else {
        TVFileScreen(item: item)
      }
    }
  }
}

struct TVHomeScreen: View {
  let entries: [TVHomeEntry]

  @Namespace private var focusScope
  @Environment(\.resetFocus) private var resetFocus
  @FocusState private var focusedEntry: TVHomeEntry?
  @State private var lastFocusedEntry: TVHomeEntry?

  var body: some View {
    VStack(alignment: .leading, spacing: PutioTheme.TV.Spacing.medium) {
      Text("put.io")
        .putioFont(PutioTheme.TV.Typography.heading)
        .foregroundStyle(PutioTheme.TV.Colors.textPrimary)
        .accessibilityAddTraits(.isHeader)
      TVRowList {
        ForEach(entries) { entry in
          NavigationLink(value: entry.route) {
            HStack(spacing: PutioTheme.TV.Spacing.small) {
              TVIconLabel(title: entry.title, image: entry.icon)
              Spacer(minLength: PutioTheme.TV.Spacing.small)
              TVDisclosure()
            }
            .tvRowPadding()
          }
          .focused($focusedEntry, equals: entry)
          .prefersDefaultFocus(entry == entries.first, in: focusScope)
          .accessibilityIdentifier("home.\(entry.route.identifier)")
        }
      }
      // A new column per entry set, so a removed row cannot keep the focus.
      .id(entries)
    }
    .focusScope(focusScope)
    .onChange(of: focusedEntry) { _, entry in
      if let entry { lastFocusedEntry = entry }
    }
    // Hiding History while its row has focus would strand the remote.
    .onChange(of: entries) { _, entries in
      guard let lastFocusedEntry, !entries.contains(lastFocusedEntry) else { return }
      Task { @MainActor in
        await Task.yield()
        resetFocus(in: focusScope)
        focusedEntry = entries.first
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    .tvOverscanPadding()
    .background(PutioTheme.Colors.background.ignoresSafeArea())
  }
}

/// A row label: a yellow Phosphor icon and the title, as the shipped lists.
struct TVIconLabel: View {
  let title: String
  let image: Image

  init(title: String, icon: PutioIcon) {
    self.init(title: title, image: Image(putioIcon: icon))
  }

  init(title: String, image: Image) {
    self.title = title
    self.image = image
  }

  var body: some View {
    HStack(spacing: PutioTheme.TV.Spacing.small) {
      image
        .resizable()
        .scaledToFit()
        .frame(width: TVRowLayout.iconSize, height: TVRowLayout.iconSize)
        .foregroundStyle(PutioTheme.Components.FileRow.icon)
        .accessibilityHidden(true)
      Text(title)
        .putioFont(PutioTheme.TV.Typography.body)
        .foregroundStyle(PutioTheme.TV.Colors.textPrimary)
    }
  }
}

extension TVRoute {
  var identifier: String {
    switch self {
    case .files: "files"
    case .search: "search"
    case .history: "history"
    case .account: "account"
    case .proxy: "proxy"
    case .trash: "trash"
    case .folder(let folder): "folder.\(folder.id.rawValue)"
    case .file(let item): "file.\(item.id.rawValue)"
    }
  }
}
