import PutioCore
import SwiftUI

enum TVTab: Hashable, CaseIterable {
  case home
  case files
  case search
  case history
  case account

  func isAvailable(for account: PutioAccountSnapshot, showsHome: Bool = true) -> Bool {
    switch self {
    case .home: showsHome
    case .history: account.historyEnabled
    case .files, .search, .account: true
    }
  }

  static func tabs(for account: PutioAccountSnapshot, showsHome: Bool = true) -> [TVTab] {
    allCases.filter { $0.isAvailable(for: account, showsHome: showsHome) }
  }

  var title: String {
    switch self {
    case .home: String(localized: "Home", bundle: .putioCore)
    case .files: String(localized: "Files", bundle: .putioCore)
    case .search: String(localized: "Search", bundle: .putioCore)
    case .history: String(localized: "History", bundle: .putioCore)
    case .account: String(localized: "Account", bundle: .putioCore)
    }
  }

  var icon: Image {
    switch self {
    case .home: Image(systemName: "house")
    case .files: Image(systemName: "folder")
    case .search: Image(systemName: "magnifyingglass")
    case .history: Image(systemName: "clock.arrow.circlepath")
    case .account: Image(systemName: "person.crop.circle")
    }
  }

  var identifier: String {
    switch self {
    case .home: "tab.home"
    case .files: "tab.files"
    case .search: "tab.search"
    case .history: "tab.history"
    case .account: "tab.account"
    }
  }
}

enum TVRoute: Hashable {
  case trash
  case privacy
  case licenses
  case folder(PutioFolderRoute)
  case file(PutioFileItem)
  case video(PutioFileItem, PutioVideoResumePrompt.Choice)

  func isAvailable(for account: PutioAccountSnapshot) -> Bool {
    switch self {
    case .trash: account.trashEnabled
    case .privacy, .licenses, .folder, .file, .video: true
    }
  }

  static func reconcile(_ path: [TVRoute], account: PutioAccountSnapshot) -> [TVRoute] {
    guard let index = path.firstIndex(where: { !$0.isAvailable(for: account) }) else {
      return path
    }
    return Array(path[..<index])
  }
}

struct TVShellNavigation: Equatable {
  var selection: TVTab = .home
  var paths: [TVTab: [TVRoute]] = [:]

  func path(for tab: TVTab) -> [TVRoute] {
    paths[tab] ?? []
  }

  var showsFullScreen: Bool {
    path(for: selection).last?.isFullScreen ?? false
  }

  mutating func setPath(_ path: [TVRoute], for tab: TVTab, account: PutioAccountSnapshot) {
    let allowed = TVRoute.reconcile(path, account: account)
    paths[tab] = allowed.isEmpty ? nil : allowed
  }

  mutating func reconcile(account: PutioAccountSnapshot, showsHome: Bool = true) {
    let tabs = TVTab.tabs(for: account, showsHome: showsHome)
    for tab in TVTab.allCases {
      guard tabs.contains(tab) else {
        paths[tab] = nil
        continue
      }
      if let path = paths[tab] { setPath(path, for: tab, account: account) }
    }
    if !tabs.contains(selection), let first = tabs.first { selection = first }
  }
}

struct TVSignedInShell: View {
  let runtime: PutioRuntime
  let account: PutioAccountSnapshot

  @Environment(\.scenePhase) private var scenePhase
  @State private var navigation: TVShellNavigation
  @State private var showHome: PutioShowHomePreference
  @State private var trashReconciliation = PutioTrashReconciliation()
  @State private var folderRefreshRequests = PutioFolderRefreshRequests()
  @State private var playbackPositionPipeline = PutioPlaybackPositionPipeline()
  @State private var historyActivations = 0

  init(runtime: PutioRuntime, account: PutioAccountSnapshot) {
    self.runtime = runtime
    self.account = account
    let showHome = PutioShowHomePreference(accountID: account.id)
    _showHome = State(initialValue: showHome)
    _navigation = State(
      initialValue: TVShellNavigation(selection: showHome.isShown ? .home : .files))
  }

  var body: some View {
    TabView(selection: $navigation.selection) {
      ForEach(TVTab.tabs(for: account, showsHome: showHome.isShown), id: \.self) { tab in
        Tab(value: tab, role: tab == .search ? .search : nil) {
          stack(for: tab)
        } label: {
          if tab == .search {
            tab.icon
              .accessibilityLabel(Text(tab.title))
              .accessibilityIdentifier(tab.identifier)
          } else {
            Label {
              Text(tab.title)
            } icon: {
              tab.icon
            }
            .accessibilityIdentifier(tab.identifier)
          }
        }
      }
    }
    .overlay(alignment: .topLeading) {
      if !navigation.showsFullScreen { TVWordmark() }
    }
    .onChange(of: account) { previous, current in
      PutioAccountPreferencesReconciliation.apply(
        previous: previous, current: current, folders: folderRefreshRequests,
        trash: trashReconciliation)
      navigation.reconcile(account: current, showsHome: showHome.isShown)
    }
    .onChange(of: showHome.isShown) { _, shown in
      navigation.reconcile(account: account, showsHome: shown)
    }
    .onChange(of: navigation.selection) { _, tab in
      if tab == .home { Task { await runtime.refreshAccount() } }
      if tab == .history { historyActivations &+= 1 }
    }
    .onChange(of: scenePhase) { _, phase in
      if phase == .active { Task { await runtime.refreshAccount() } }
    }
  }

  private func stack(for tab: TVTab) -> some View {
    NavigationStack(
      path: Binding(
        get: { navigation.path(for: tab) },
        set: { navigation.setPath($0, for: tab, account: account) })
    ) {
      root(for: tab)
        .navigationDestination(for: TVRoute.self) { route in
          destination(for: route, in: tab)
        }
    }
  }

  @ViewBuilder
  private func root(for tab: TVTab) -> some View {
    switch tab {
    case .home:
      TVHomeScreen(notice: PutioInactiveAccountNotice(account: account))
    case .files:
      TVFolderView(
        route: .root, runtime: runtime, account: account,
        refreshRequests: folderRefreshRequests, open: { open($0, in: tab) },
        play: { play($0, $1, in: tab) })
    case .search:
      TVSearchView(
        runtime: runtime, account: account, refreshRequests: folderRefreshRequests,
        open: { open($0, in: tab) })
    case .history:
      TVHistoryView(runtime: runtime, open: { open($0, in: tab) })
        .environment(\.tvHistoryActivations, historyActivations)
    case .account:
      TVAccountView(runtime: runtime, showHome: showHome)
    }
  }

  private func open(_ item: PutioFileItem, in tab: TVTab) {
    navigation.setPath(navigation.path(for: tab) + [.opening(item)], for: tab, account: account)
  }

  private func play(_ item: PutioFileItem, _ choice: PutioVideoResumePrompt.Choice, in tab: TVTab) {
    navigation.setPath(
      navigation.path(for: tab) + [.video(item, choice)], for: tab, account: account)
  }

  @ViewBuilder
  private func destination(for route: TVRoute, in tab: TVTab) -> some View {
    switch route {
    case .trash:
      TVTrashView(
        runtime: runtime, reconciliation: trashReconciliation,
        refreshRequests: folderRefreshRequests)
    case .privacy:
      TVPrivacyControlsView(runtime: runtime)
    case .licenses:
      TVLicensesView()
    case .folder(let folder):
      TVFolderView(
        route: folder, runtime: runtime, account: account,
        refreshRequests: folderRefreshRequests, open: { open($0, in: tab) },
        play: { play($0, $1, in: tab) })
    case .file(let item):
      if case .video(let video) = PutioFileRoute(item: item).openAction {
        TVVideoSession(
          route: video, runtime: runtime, account: account, pipeline: playbackPositionPipeline,
          refreshRequests: folderRefreshRequests
        )
        .toolbar(.hidden, for: .tabBar)
      } else {
        TVFileScreen(item: item)
      }
    case .video(let item, _):
      if let video = route.videoRoute {
        TVVideoSession(
          route: video, runtime: runtime, account: account,
          pipeline: playbackPositionPipeline, refreshRequests: folderRefreshRequests
        )
        .toolbar(.hidden, for: .tabBar)
      } else {
        TVFileScreen(item: item)
      }
    }
  }
}

struct TVWordmark: View {
  var body: some View {
    Image.putioWordmark
      .resizable()
      .scaledToFit()
      .frame(height: TVShellLayout.wordmarkHeight)
      .padding(.leading, TVShellLayout.wordmarkLeading)
      .padding(.top, TVShellLayout.wordmarkTop)
      .ignoresSafeArea()
      .accessibilityLabel(Text(verbatim: "put.io"))
      .accessibilityAddTraits(.isHeader)
      .accessibilityIdentifier("shell.wordmark")
      .allowsHitTesting(false)
  }
}

enum TVShellLayout {
  static let wordmarkHeight: CGFloat = 40
  static let wordmarkLeading: CGFloat = 80
  static let wordmarkTop: CGFloat = 64
}

extension TVRoute {
  var videoRoute: PutioVideoRoute? {
    guard case .video(let item, let choice) = self,
      case .video(let video) = PutioFileRoute(item: item).openAction
    else { return nil }
    return video.starting(with: choice)
  }

  var isFullScreen: Bool {
    if case .video = self { return true }
    guard case .file(let item) = self else { return false }
    if case .video = PutioFileRoute(item: item).openAction { return true }
    return false
  }

  var identifier: String {
    switch self {
    case .trash: "trash"
    case .privacy: "privacy"
    case .licenses: "licenses"
    case .folder(let folder): "folder.\(folder.id.rawValue)"
    case .file(let item): "file.\(item.id.rawValue)"
    case .video(let item, _): "video.\(item.id.rawValue)"
    }
  }
}

extension EnvironmentValues {
  @Entry var tvHistoryActivations = 0
}
