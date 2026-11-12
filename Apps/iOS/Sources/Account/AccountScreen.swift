import PutioCore
import SwiftUI

enum AccountDestination: Hashable {
  case publicLinks, trash
  case playbackMethod, proxy, chromecast
  case downloads
  case privacy
  case loggedInApps, linkDevice, twoFactor
  case appInfo, licenses
  case clearData, destroyAccount
}

struct AccountScreen: View {
  let runtime: PutioRuntime
  let account: PutioAccountSnapshot
  let refreshRequests: PutioFolderRefreshRequests
  let trashReconciliation: PutioTrashReconciliation
  let cast: PutioCastModel
  let appConfig: PutioAppConfigModel
  @Binding var showsLinkDevice: Bool
  let linkDeviceCode: String?
  let downloads: PutioOfflineQueue
  let onDataCleared: @MainActor (Set<PutioAccountDataCategory>, Bool) -> Void
  let onAccountDestroyed: @MainActor () -> Void
  @Environment(\.horizontalSizeClass) private var horizontalSizeClass
  @State private var preferences: PutioAccountPreferencesModel
  @State private var destination: AccountDestination?
  @State private var isLandscape = false

  init(
    runtime: PutioRuntime,
    account: PutioAccountSnapshot,
    refreshRequests: PutioFolderRefreshRequests,
    trashReconciliation: PutioTrashReconciliation,
    cast: PutioCastModel,
    appConfig: PutioAppConfigModel,
    showsLinkDevice: Binding<Bool>,
    linkDeviceCode: String?,
    downloads: PutioOfflineQueue,
    onDataCleared: @escaping @MainActor (Set<PutioAccountDataCategory>, Bool) -> Void,
    onAccountDestroyed: @escaping @MainActor () -> Void
  ) {
    self.runtime = runtime
    self.account = account
    self.refreshRequests = refreshRequests
    self.trashReconciliation = trashReconciliation
    self.cast = cast
    self.appConfig = appConfig
    _showsLinkDevice = showsLinkDevice
    self.linkDeviceCode = linkDeviceCode
    self.downloads = downloads
    self.onDataCleared = onDataCleared
    self.onAccountDestroyed = onAccountDestroyed
    _preferences = State(
      initialValue: PutioAccountPreferencesModel(actions: .init(runtime: runtime)))
  }

  var body: some View {
    Group {
      if showsColumns {
        columns
      } else {
        stack
      }
    }
    .onGeometryChange(for: Bool.self) { geometry in
      let insets = geometry.safeAreaInsets
      return geometry.size.width + insets.leading + insets.trailing
        > geometry.size.height + insets.top + insets.bottom
    } action: { landscape in
      isLandscape = landscape
    }
    .onChange(of: showsLinkDevice, initial: true) { _, shows in
      if shows { destination = .linkDevice }
    }
    .onChange(of: destination) { _, current in
      if current != .linkDevice, showsLinkDevice { showsLinkDevice = false }
    }
  }

  private var showsColumns: Bool {
    horizontalSizeClass == .regular && isLandscape
  }

  private var columns: some View {
    PutioListDetail(selection: $destination, listWidth: Self.listWidth) { _ in
      list(open: destination)
        .navigationBarTitleDisplayMode(.inline)
    } detail: { destination in
      destinationView(destination)
        .modifier(AccountDetailReadableWidth())
    }
  }

  private static let listWidth =
    PutioTheme.Spacing.space8 - PutioTheme.Spacing.space5 - PutioTheme.Spacing.space4
    + PutioTheme.Spacing.space1

  private var stack: some View {
    NavigationStack(path: stackPath) {
      list(open: nil)
        .navigationDestination(for: AccountDestination.self) { destination in
          destinationView(destination)
        }
    }
  }

  private var stackPath: Binding<[AccountDestination]> {
    Binding(
      get: { destination.map { [$0] } ?? [] },
      set: { path in destination = path.last })
  }

  private func list(open: AccountDestination?) -> some View {
    AccountView(
      runtime: runtime,
      account: account,
      preferences: preferences,
      appConfig: appConfig,
      downloads: downloads,
      openDestination: open
    )
  }

  @ViewBuilder private func destinationView(_ destination: AccountDestination) -> some View {
    switch destination {
    case .publicLinks:
      PublicLinksView(runtime: runtime)
    case .trash:
      TrashManagementView(
        runtime: runtime,
        reconciliation: trashReconciliation,
        onRestored: { destinationID in
          PutioRestoredFileReconciliation.apply(destinationID: destinationID, to: refreshRequests)
        }
      )
    case .playbackMethod:
      PlaybackMethodView(appConfig: appConfig)
    case .proxy:
      ProxySettingsView(runtime: runtime, preferences: preferences)
    case .chromecast:
      PutioCastPreferencesView(model: cast)
    case .downloads:
      DownloadSettingsView(queue: downloads)
    case .privacy:
      PrivacyControlsView(runtime: runtime)
    case .loggedInApps:
      LoggedInAppsView(actions: .init(runtime: runtime))
    case .linkDevice:
      LinkDeviceView(
        actions: .init(runtime: runtime), code: showsLinkDevice ? linkDeviceCode : nil)
    case .twoFactor:
      TwoFactorSettingsView(runtime: runtime)
    case .appInfo:
      AppInfoView()
    case .licenses:
      OpenSourceLicensesView()
    case .clearData:
      ClearDataView(actions: .init(runtime: runtime), onCleared: onDataCleared)
    case .destroyAccount:
      DestroyAccountView(actions: .init(runtime: runtime), onDestroyed: onAccountDestroyed)
    }
  }
}

private struct AccountDetailReadableWidth: ViewModifier {
  func body(content: Content) -> some View {
    content
      .frame(maxWidth: Self.readableWidth)
      .frame(maxWidth: .infinity)
      .background(PutioTheme.Colors.background)
  }

  private static let readableWidth =
    PutioTheme.Spacing.space8 + PutioTheme.Spacing.space5 + PutioTheme.Spacing.space3
    + PutioTheme.Spacing.space2
}
