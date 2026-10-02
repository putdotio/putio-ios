import PutioCore
import SwiftUI

/// A destination pushed from Home. Some exist only while an account setting
/// allows them.
enum TVRoute: Hashable {
  case history
  case account
  case proxy
  case trash
  case file(PutioFileItem)

  func isAvailable(for account: PutioAccountSnapshot) -> Bool {
    switch self {
    case .history: account.historyEnabled
    case .trash: account.trashEnabled
    case .account, .proxy, .file: true
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

/// The shipped Home list. Your Files and Search arrive with the browser.
enum TVHomeEntry: CaseIterable, Identifiable {
  case history
  case account

  var id: Self { self }

  static func entries(for account: PutioAccountSnapshot) -> [TVHomeEntry] {
    allCases.filter { $0.route.isAvailable(for: account) }
  }

  var route: TVRoute {
    switch self {
    case .history: .history
    case .account: .account
    }
  }

  var title: String {
    switch self {
    case .history: "History"
    case .account: "Account"
    }
  }

  var icon: PutioIcon {
    switch self {
    case .history: .clockCounterClockwise
    case .account: .userCircle
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
    .onChange(of: scenePhase) { _, phase in
      if phase == .active { Task { await runtime.refreshAccount() } }
    }
  }

  @ViewBuilder
  private func destination(for route: TVRoute) -> some View {
    switch route {
    case .account:
      TVAccountView(runtime: runtime)
    case .proxy:
      TVProxyChooserView(runtime: runtime)
    case .history:
      TVHistoryView(runtime: runtime) { path.append(.file($0)) }
    case .trash:
      TVTrashView(runtime: runtime, reconciliation: trashReconciliation)
    case .file(let item):
      TVFileSummaryScreen(item: item)
    }
  }
}

struct TVHomeScreen: View {
  let entries: [TVHomeEntry]

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
              TVIconLabel(title: entry.title, icon: entry.icon)
              Spacer(minLength: PutioTheme.TV.Spacing.small)
              TVDisclosure()
            }
            .tvRowPadding()
          }
          .accessibilityIdentifier("home.\(entry.route.identifier)")
        }
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
  let icon: PutioIcon

  var body: some View {
    HStack(spacing: PutioTheme.TV.Spacing.small) {
      Image(putioIcon: icon)
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

/// A scrolling column of rows. Rows that act as controls use the stock card
/// style, which owns the focus lift; the shipped app's lists are this shape.
struct TVRowList<Content: View>: View {
  @ViewBuilder let content: Content

  var body: some View {
    ScrollView {
      LazyVStack(alignment: .leading, spacing: PutioTheme.TV.Spacing.small) {
        content
      }
      .padding(.vertical, PutioTheme.TV.Spacing.small)
    }
    // The card lift grows past the column; clipping would cut it off.
    .scrollClipDisabled()
    .buttonStyle(.card)
  }
}

struct TVSectionHeader: View {
  let title: String

  var body: some View {
    Text(title)
      .putioFont(PutioTheme.TV.Typography.caption)
      .foregroundStyle(PutioTheme.TV.Colors.textSecondary)
      .padding(.top, PutioTheme.TV.Spacing.small)
      .accessibilityAddTraits(.isHeader)
  }
}

/// The chevron on a row that opens another screen.
struct TVDisclosure: View {
  var body: some View {
    Image(putioIcon: .caretRight)
      .resizable()
      .scaledToFit()
      .frame(width: TVRowLayout.disclosureSize, height: TVRowLayout.disclosureSize)
      .foregroundStyle(PutioTheme.TV.Colors.textSecondary)
      .accessibilityHidden(true)
  }
}

extension View {
  /// The inset a row's content keeps from its card edges.
  func tvRowPadding() -> some View {
    padding(.horizontal, PutioTheme.TV.Spacing.medium)
      .padding(.vertical, PutioTheme.TV.Spacing.small)
      .frame(maxWidth: .infinity, alignment: .leading)
  }
}

/// A screen's title with its header actions on the trailing edge.
struct TVScreenHeader<Actions: View>: View {
  let title: String
  @ViewBuilder let actions: Actions

  var body: some View {
    HStack(alignment: .center, spacing: PutioTheme.TV.Spacing.small) {
      Text(title)
        .putioFont(PutioTheme.TV.Typography.heading)
        .foregroundStyle(PutioTheme.TV.Colors.textPrimary)
        .accessibilityAddTraits(.isHeader)
      Spacer(minLength: PutioTheme.TV.Spacing.medium)
      actions
    }
    // Header actions sit far from the list's leading edge; the section lets
    // an upward swipe from any row reach them.
    .focusSection()
  }
}

enum TVRowLayout {
  static let iconSize = PutioTheme.TV.Typography.label.size
  static let disclosureSize = PutioTheme.TV.Typography.caption.size
}

/// Where a History event leads until the file browser lands: the resolved
/// file, so the lookup and its failures are real.
struct TVFileSummaryScreen: View {
  let item: PutioFileItem

  var body: some View {
    VStack(alignment: .leading, spacing: PutioTheme.TV.Spacing.medium) {
      PutioFileRow(PutioBrowserItemPresentation(item: item).row)
        .accessibilityIdentifier("file-summary.\(item.id.rawValue)")
      Text("Browsing and playback on Apple TV arrive with Your Files.")
        .putioFont(PutioTheme.TV.Typography.body)
        .foregroundStyle(PutioTheme.TV.Colors.textSecondary)
      Spacer(minLength: 0)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .tvOverscanPadding()
    .background(PutioTheme.Colors.background.ignoresSafeArea())
  }
}

extension TVRoute {
  var identifier: String {
    switch self {
    case .history: "history"
    case .account: "account"
    case .proxy: "proxy"
    case .trash: "trash"
    case .file(let item): "file.\(item.id.rawValue)"
    }
  }
}
