import PutioCore
import SwiftUI

struct AccountView: View {
  let runtime: PutioRuntime
  let account: PutioAccountSnapshot
  let refreshRequests: PutioFolderRefreshRequests
  let trashReconciliation: PutioTrashReconciliation
  let cast: PutioCastModel
  let appConfig: PutioAppConfigModel
  @Binding var showsLinkDevice: Bool
  let linkDeviceCode: String?
  let downloadedBytes: Int64?
  let removeDownloads: @MainActor () -> Void
  let onDataCleared: @MainActor (Set<PutioAccountDataCategory>, Bool) -> Void
  let onAccountDestroyed: @MainActor () -> Void
  @Environment(\.openURL) private var openURL
  @Environment(\.locale) private var locale
  @State private var preferences: PutioAccountPreferencesModel
  @State private var isRefreshingStorage = false
  @State private var signOutAlert: PutioConfirmAlert?
  @State private var signOutDownloadedBytes: Int64?
  @State private var confirmation: AccountSettingConfirmation?
  @State private var saveFailures = PutioSettingSaveFailures()
  @State private var revealRequest: AccountSettingReveal?

  init(
    runtime: PutioRuntime,
    account: PutioAccountSnapshot,
    refreshRequests: PutioFolderRefreshRequests,
    trashReconciliation: PutioTrashReconciliation,
    cast: PutioCastModel,
    appConfig: PutioAppConfigModel,
    showsLinkDevice: Binding<Bool>,
    linkDeviceCode: String?,
    downloadedBytes: Int64?,
    removeDownloads: @escaping @MainActor () -> Void,
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
    self.downloadedBytes = downloadedBytes
    self.removeDownloads = removeDownloads
    self.onDataCleared = onDataCleared
    self.onAccountDestroyed = onAccountDestroyed
    _preferences = State(
      initialValue: PutioAccountPreferencesModel(actions: .init(runtime: runtime)))
  }

  var body: some View {
    ScrollViewReader { proxy in
      settingsList
        .onChange(of: revealRequest) { _, request in
          guard let request else { return }
          withAnimation { proxy.scrollTo(request.row, anchor: .center) }
        }
    }
    .putioSettingSaveFailures(saveFailures)
  }

  private var settingsList: some View {
    List {
      if let notice = PutioInactiveAccountNotice(account: account) {
        PutioInactiveAccountNoticeView(notice: notice, identifier: "account.status-notice")
          .listRowInsets(
            EdgeInsets(top: 0, leading: 0, bottom: PutioTheme.Spacing.space3, trailing: 0)
          )
          .listRowSeparator(.hidden)
          .listRowBackground(Color.clear)
      }
      AccountProfileHeader(account: account)
      Group {
        storageSection
        PutioSettingsSection(String(localized: "Library")) {
          if account.trashEnabled {
            PutioNavigationRow(
              String(localized: "Trash"), icon: .trash,
              value: PutioFileRowModel.sizeText(bytes: account.trashSizeBytes),
              valueStyle: .measurement
            ) {
              TrashManagementView(
                runtime: runtime,
                reconciliation: trashReconciliation,
                onRestored: reconcileRestoredFile
              )
            }
            .accessibilityIdentifier("account.trash")
          }
        }
        switch preferences.settingsState {
        case .loading:
          Section {
            PutioSettingsLoadingRow(String(localized: "Loading account settings"))
              .accessibilityIdentifier("account.settings-loading")
          }
        case .failed:
          Section {
            PutioSettingsFailedRows(
              String(localized: "Couldn’t load account settings"),
              identifier: "account.settings-failed",
              retryIdentifier: "account.settings-retry"
            ) {
              Task { await preferences.loadSettings() }
            }
          }
        case .ready:
          filesSection
          playbackSection
          subtitlesSection
          privacySection
          securitySection
          aboutSection
        }
        if preferences.settingsState != .loading {
          Section {
            signOutRow
          }
        }
        if preferences.settingsState == .ready {
          PutioSettingsSection(String(localized: "Danger zone")) {
            PutioNavigationRow(String(localized: "Clear your data"), icon: .eraser) {
              ClearDataView(actions: .init(runtime: runtime), onCleared: onDataCleared)
            }
            .accessibilityIdentifier("account.clear-data")
            PutioNavigationRow(String(localized: "Destroy your account"), icon: .userCircleMinus) {
              DestroyAccountView(actions: .init(runtime: runtime), onDestroyed: onAccountDestroyed)
            }
            .accessibilityIdentifier("account.destroy-account")
          }
        }
      }
      .listRowBackground(PutioTheme.Colors.surface)
    }
    .navigationTitle("Account")
    .putioFont(PutioTheme.Typography.body)
    .putioContentBackground()
    .task { await preferences.loadSettingsIfNeeded() }
    .task { await appConfig.loadIfNeeded() }
    .putioConfirmAlert($signOutAlert)
    .confirmationDialog(
      confirmation?.title ?? String(localized: "Update settings?"),
      isPresented: Binding(
        get: { confirmation != nil },
        set: { if !$0 { confirmation = nil } }),
      titleVisibility: .visible
    ) {
      switch confirmation {
      case .trash:
        Button("Turn Off Trash", role: .destructive) { save(.trash, .trash(false)) }
          .accessibilityIdentifier("settings.trash-disable")
      case .history:
        Button("Turn Off History", role: .destructive) { save(.history, .history(false)) }
          .accessibilityIdentifier("settings.history-disable")
      case .resetSort:
        Button("Reset Folder Sorts", role: .destructive) { save(nil, .resetFolderSorts) }
          .accessibilityIdentifier("settings.reset-sort-confirm")
      case nil:
        EmptyView()
      }
      Button("Cancel", role: .cancel) { confirmation = nil }
    } message: {
      Text(confirmation?.message ?? "")
    }
    .navigationDestination(isPresented: $showsLinkDevice) {
      LinkDeviceView(actions: .init(runtime: runtime), code: linkDeviceCode)
    }
  }

  private var signOutRow: some View {
    PutioDestructiveRow(String(localized: "Sign out"), alignment: .center) {
      askToSignOut()
    }
    .accessibilityIdentifier("auth.sign-out")
    .confirmationDialog(
      PutioSignOutPrompt.title,
      isPresented: Binding(
        get: { signOutDownloadedBytes != nil },
        set: { if !$0 { signOutDownloadedBytes = nil } }),
      titleVisibility: .visible,
      presenting: signOutDownloadedBytes
    ) { bytes in
      Button(String(localized: "Sign out"), role: .destructive) {
        signOut(removingDownloads: false)
      }
      .accessibilityIdentifier("auth.sign-out-confirm")
      Button(String(localized: "Sign out and remove downloads"), role: .destructive) {
        signOut(removingDownloads: true)
      }
      .accessibilityIdentifier("auth.sign-out-remove-downloads")
      Button("Cancel", role: .cancel) {}
    } message: { bytes in
      Text(PutioSignOutPrompt.message(downloadedBytes: bytes))
    }
  }

  private func askToSignOut() {
    if let downloadedBytes {
      signOutDownloadedBytes = downloadedBytes
      return
    }
    let runtime = runtime
    let accountID = account.id
    signOutAlert = PutioConfirmAlert(
      title: PutioSignOutPrompt.title,
      message: PutioSignOutPrompt.message,
      confirmTitle: String(localized: "Sign out")
    ) {
      PutioFilesNavigationRestoration().clear(accountID: accountID)
      Task { await runtime.session.signOut() }
    }
  }

  private func signOut(removingDownloads: Bool) {
    signOutDownloadedBytes = nil
    if removingDownloads { removeDownloads() }
    PutioFilesNavigationRestoration().clear(accountID: account.id)
    Task { await runtime.session.signOut() }
  }

  private var storageSection: some View {
    Section {
      VStack(alignment: .leading, spacing: PutioTheme.Spacing.space2) {
        ViewThatFits(in: .horizontal) {
          HStack(spacing: PutioTheme.Spacing.space2) {
            Text("Storage")
            Spacer(minLength: PutioTheme.Spacing.space2)
            storageUsage
          }
          VStack(alignment: .leading, spacing: PutioTheme.Spacing.space1) {
            Text("Storage")
            storageUsage
          }
        }
        ProgressView(value: account.storage.usedFraction)
          .tint(showsStorageFull ? PutioTheme.Colors.destructive : PutioTheme.Colors.accent)
          .accessibilityHidden(true)
        if showsStorageFull {
          Text(PutioAccountSnapshot.Storage.fullMessage)
            .putioFont(PutioTheme.Typography.caption)
            .foregroundStyle(PutioTheme.Colors.destructive)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityIdentifier("account.storage-full")
        }
      }
      .padding(.vertical, PutioTheme.Spacing.space1)
      if runtime.session.isAccountStorageStale {
        PutioErrorStateView(
          title: PutioTrashErrorPresentation.staleStorage.title,
          message: PutioTrashErrorPresentation.staleStorage.message,
          retryTitle: isRefreshingStorage
            ? String(localized: "Updating…") : String(localized: "Update storage")
        ) {
          guard !isRefreshingStorage else { return }
          isRefreshingStorage = true
          Task {
            defer { isRefreshingStorage = false }
            _ = await runtime.refreshAccount()
          }
        }
        .disabled(isRefreshingStorage)
        .accessibilityIdentifier("account.storage-retry")
      }
    }
  }

  private var storageUsage: some View {
    Text(account.storage.statusSummary(locale: locale))
      .putioFont(PutioTheme.Typography.numeric)
      .foregroundStyle(PutioTheme.Colors.textSecondary)
      .accessibilityIdentifier("account.storage-used")
  }

  private var filesSection: some View {
    PutioSettingsSection(String(localized: "Files")) {
      PutioPickerRow(
        String(localized: "Default sort order"),
        icon: .sortAscending,
        selection: preferences.account?.defaultSort,
        options: sortOptions,
        save: { sort in
          guard let sort else { throw CancellationError() }
          try await commit(.defaultSort, .defaultSort(sort))
        }
      ) { sort in
        sort?.accountValue ?? String(localized: "Current server setting")
      }
      .disabled(settingsLocked)
      .id(AccountSettingRow.defaultSort)
      .accessibilityIdentifier("settings.default-sort")
      PutioToggleRow(
        title: String(localized: "Move deleted files to trash"), icon: .trash,
        isOn: trashEnabled
      )
      .disabled(settingsLocked)
      .id(AccountSettingRow.trash)
      .accessibilityIdentifier("settings.trash")
      PutioActionRow(String(localized: "Reset all sort settings"), icon: .arrowCounterClockwise) {
        confirmation = .resetSort
      }
      .disabled(settingsLocked)
      .accessibilityIdentifier("settings.reset-sort")
    }
  }

  private var playbackSection: some View {
    PutioSettingsSection(String(localized: "Playback")) {
      PutioPlaybackConfigRows(
        suggestsNextVideo: account.suggestNextVideo,
        showsRotation: UIDevice.current.userInterfaceIdiom == .phone,
        appConfig: appConfig,
        onSaveFailed: { write in
          switch write {
          case .autoplayNextVideo: reveal(.autoplay)
          case .autoRotateVideo: reveal(.autoRotate)
          }
        })
      PutioNavigationRow(
        String(localized: "Proxy"), icon: .globe, value: preferences.account?.routeName
      ) {
        ProxySettingsView(runtime: runtime, preferences: preferences) { name in
          Task { await commitReporting(.proxy, .route(name)) }
        }
      }
      .id(AccountSettingRow.proxy)
      .accessibilityIdentifier("playback-settings.route")
      PutioNavigationRow(String(localized: "Chromecast"), icon: .screencast) {
        PutioCastPreferencesView(model: cast)
      }
      .accessibilityIdentifier("account.chromecast")
    }
  }

  private var subtitlesSection: some View {
    PutioSettingsSection(String(localized: "Subtitles")) {
      PutioToggleRow(
        String(localized: "Show subtitles"), icon: .closedCaptioning,
        isOn: !(preferences.account ?? account).hideSubtitles
      ) { show in
        try await commit(.showSubtitles, .showSubtitles(show))
      }
      .disabled(settingsLocked)
      .id(AccountSettingRow.showSubtitles)
      .accessibilityIdentifier("playback-settings.subtitles")
      if !(preferences.account ?? account).hideSubtitles {
        PutioToggleRow(
          String(localized: "Pick matching subtitles"), icon: .listChecks,
          isOn: !(preferences.account ?? account).dontAutoSelectSubtitles
        ) { pick in
          try await commit(.pickMatchingSubtitles, .dontAutoSelectSubtitles(!pick))
        }
        .disabled(settingsLocked)
        .id(AccountSettingRow.pickMatchingSubtitles)
        .accessibilityIdentifier("playback-settings.subtitle-selection")
      }
    }
  }

  private var privacySection: some View {
    PutioSettingsSection(String(localized: "Privacy")) {
      PutioToggleRow(
        title: String(localized: "Keep account history"), icon: .clockCounterClockwise,
        isOn: historyEnabled
      )
      .disabled(settingsLocked)
      .id(AccountSettingRow.history)
      .accessibilityIdentifier("settings.history")
      PutioNavigationRow(
        PutioPrivacyControls.title, subtitle: PutioPrivacyControls.summary(for: account),
        icon: .shieldCheck
      ) {
        PrivacyControlsView(runtime: runtime)
      }
      .accessibilityIdentifier("account.privacy")
    }
  }

  private var securitySection: some View {
    PutioSettingsSection(String(localized: "Security")) {
      PutioNavigationRow(String(localized: "Logged-in apps"), icon: .devices) {
        AuthorizedAppsView(actions: .init(runtime: runtime))
      }
      .accessibilityIdentifier("security.apps")
      PutioNavigationRow(String(localized: "Link a device"), icon: .plugs) {
        LinkDeviceView(actions: .init(runtime: runtime))
      }
      .accessibilityIdentifier("security.link-device")
      PutioNavigationRow(
        String(localized: "Two-factor authentication"), icon: .lockKey,
        value: account.twoFactorEnabled ? String(localized: "On") : String(localized: "Off")
      ) {
        TwoFactorSettingsView(runtime: runtime)
      }
      .accessibilityIdentifier("account.two-factor")
    }
  }

  private var aboutSection: some View {
    PutioSettingsSection(String(localized: "About")) {
      PutioNavigationRow(
        String(localized: "App info"), icon: .info, value: AboutView.shortVersion,
        valueStyle: .measurement
      ) {
        AboutView()
      }
      .accessibilityIdentifier("account.about")
      PutioLinkRow(String(localized: "Privacy policy"), icon: .fileText) {
        openURL(PutioPrivacyControls.privacyPolicyURL)
      }
      .accessibilityIdentifier("account.privacy-policy")
      PutioNavigationRow(String(localized: "Open source licenses"), icon: .list) {
        OpenSourceLicensesView()
      }
      .accessibilityIdentifier("account.licenses")
      if let reviewURL = PutioAppStoreReview.url() {
        PutioLinkRow(String(localized: "Rate put.io on App Store"), icon: .star) {
          openURL(reviewURL)
        }
        .accessibilityIdentifier("account.rate-app")
      }
      PutioActionRow(String(localized: "Contact us"), icon: .chatCircle) {
        PutioSupportMessenger.shared.contactSupport { openURL($0) }
      }
      .accessibilityIdentifier("account.contact-support")
    }
  }

  private var showsStorageFull: Bool {
    account.storage.isFull && !runtime.session.isAccountStorageStale
  }

  private var settingsLocked: Bool { preferences.isBusy || preferences.isStale }

  private var sortOptions: [PutioFolderSort?] {
    let sorts = PutioFolderSort.allCases.map(Optional.some)
    return preferences.account?.defaultSort == nil ? [nil] + sorts : sorts
  }

  private var trashEnabled: Binding<Bool> {
    Binding(
      get: { preferences.account?.trashEnabled ?? false },
      set: { enabled in
        if enabled { save(.trash, .trash(true)) } else { confirmation = .trash }
      })
  }

  private var historyEnabled: Binding<Bool> {
    Binding(
      get: { preferences.account?.historyEnabled ?? false },
      set: { enabled in
        if enabled { save(.history, .history(true)) } else { confirmation = .history }
      })
  }

  private func save(_ row: AccountSettingRow?, _ mutation: PutioAccountPreferenceMutation) {
    confirmation = nil
    Task { await commitReporting(row, mutation) }
  }

  private func commit(_ row: AccountSettingRow, _ mutation: PutioAccountPreferenceMutation)
    async throws
  {
    let outcome = await preferences.save(mutation)
    if outcome == .failed { reveal(row) }
    try outcome.requireSaved()
  }

  private func commitReporting(
    _ row: AccountSettingRow?, _ mutation: PutioAccountPreferenceMutation
  ) async {
    guard await preferences.save(mutation) == .failed else { return }
    if let row { reveal(row) }
    saveFailures.report()
  }

  private func reveal(_ row: AccountSettingRow) {
    revealRequest = AccountSettingReveal(row: row)
  }

  private func reconcileRestoredFile(destinationID: PutioFileID?) {
    PutioRestoredFileReconciliation.apply(destinationID: destinationID, to: refreshRequests)
  }
}

struct PutioPlaybackConfigRows: View {
  let suggestsNextVideo: Bool
  let showsRotation: Bool
  let appConfig: PutioAppConfigModel
  var onSaveFailed: @MainActor (PutioAppConfigWrite) -> Void = { _ in }

  var body: some View {
    if appConfig.config != nil {
      if suggestsNextVideo {
        PutioToggleRow(
          String(localized: "Autoplay next video"), icon: .skipForward,
          isOn: appConfig.autoplayNextVideo
        ) { enabled in
          try await commit(.autoplayNextVideo(enabled)) {
            await appConfig.setAutoplayNextVideo(enabled)
          }
        }
        .disabled(!appConfig.canSave)
        .id(AccountSettingRow.autoplay)
        .accessibilityIdentifier("playback-settings.autoplay")
      }
      if showsRotation {
        PutioToggleRow(
          String(localized: "Rotate to landscape"), icon: .deviceRotate,
          isOn: appConfig.autoRotateVideo
        ) { enabled in
          try await commit(.autoRotateVideo(enabled)) {
            await appConfig.setAutoRotateVideo(enabled)
          }
        }
        .disabled(!appConfig.canSave)
        .id(AccountSettingRow.autoRotate)
        .accessibilityIdentifier("playback-settings.auto-rotate")
      }
    } else if suggestsNextVideo || showsRotation {
      if appConfig.isLoading {
        PutioSettingsLoadingRow(String(localized: "Loading playback settings"))
      } else if appConfig.failure != nil {
        PutioSettingsFailedRows(
          String(localized: "Couldn’t load account settings"),
          identifier: "playback-settings.failed",
          retryIdentifier: "playback-settings.retry-autoplay"
        ) {
          Task { await appConfig.retry() }
        }
        .disabled(appConfig.isBusy)
      }
    }
  }

  private func commit(
    _ write: PutioAppConfigWrite, _ save: () async -> PutioSettingSaveOutcome
  ) async throws {
    let outcome = await save()
    if outcome == .failed { onSaveFailed(write) }
    try outcome.requireSaved()
  }
}

enum AccountSettingRow: Hashable {
  case defaultSort, trash, autoplay, autoRotate, proxy, showSubtitles, pickMatchingSubtitles
  case history
}

private struct AccountSettingReveal: Equatable {
  let row: AccountSettingRow
  let id = UUID()
}

private struct AccountProfileHeader: View {
  let account: PutioAccountSnapshot
  @PutioScaledMetric private var avatarSize: CGFloat

  init(account: PutioAccountSnapshot) {
    self.account = account
    _avatarSize = PutioScaledMetric(
      PutioMetricRole(
        value: PutioTheme.Spacing.space4 + PutioTheme.Spacing.space2 + PutioTheme.Spacing.space1,
        relativeTo: .body))
  }

  var body: some View {
    HStack(spacing: PutioTheme.Spacing.space3) {
      avatar
      VStack(alignment: .leading, spacing: PutioTheme.Spacing.space1) {
        Text(account.username)
          .putioFont(PutioTheme.Typography.subheading)
          .foregroundStyle(PutioTheme.Colors.textPrimary)
          .accessibilityIdentifier("account.username")
        Text(account.email)
          .putioFont(PutioTheme.Typography.caption)
          .foregroundStyle(PutioTheme.Colors.textSecondary)
          .accessibilityIdentifier("account.email")
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .listRowBackground(Color.clear)
    .listRowInsets(EdgeInsets(top: 0, leading: PutioTheme.Spacing.space1, bottom: 0, trailing: 0))
    .accessibilityElement(children: .combine)
    .accessibilityIdentifier("account.profile")
  }

  private var avatar: some View {
    AsyncImage(url: account.avatarURL) { phase in
      if let image = phase.image {
        image.resizable().scaledToFill()
      } else {
        Text(account.username.prefix(1).uppercased())
          .putioFont(PutioTheme.Typography.subheading)
          .foregroundStyle(PutioTheme.Colors.textPrimary)
          .frame(maxWidth: .infinity, maxHeight: .infinity)
          .background(PutioTheme.Colors.surface)
      }
    }
    .frame(width: avatarSize, height: avatarSize)
    .clipShape(Circle())
    .accessibilityHidden(true)
  }
}

private enum PutioSignOutPrompt {
  static var title: String { String(localized: "Sign out of put.io?") }

  static var message: String {
    UIDevice.current.userInterfaceIdiom == .pad
      ? String(localized: "Downloads stay on this iPad and come back when you sign in again.")
      : String(localized: "Downloads stay on this iPhone and come back when you sign in again.")
  }

  static func message(downloadedBytes bytes: Int64) -> String {
    let size = PutioFileRowModel.sizeText(bytes: bytes)
    return UIDevice.current.userInterfaceIdiom == .pad
      ? String(
        localized:
          "Downloads use \(size) and stay on this iPad. They come back when you sign in again.")
      : String(
        localized:
          "Downloads use \(size) and stay on this iPhone. They come back when you sign in again.")
  }
}

private enum AccountSettingConfirmation {
  case trash, history, resetSort

  var title: String {
    switch self {
    case .trash: String(localized: "Turn off Trash?")
    case .history: String(localized: "Turn off History?")
    case .resetSort: String(localized: "Reset all folder sorts?")
    }
  }

  var message: String {
    switch self {
    case .trash:
      String(
        localized:
          "Every item in Trash will be permanently deleted. Future deletions cannot be restored.")
    case .history:
      String(
        localized:
          "Existing history will be cleared and new account events will no longer be saved.")
    case .resetSort:
      String(localized: "Every folder will use your account's default sort.")
    }
  }
}

extension PutioFolderSort {
  fileprivate var accountValue: String {
    switch self {
    case .nameAscending: String(localized: "Name, A to Z")
    case .nameDescending: String(localized: "Name, Z to A")
    case .sizeAscending: String(localized: "Size, smallest first")
    case .sizeDescending: String(localized: "Size, largest first")
    case .dateAddedAscending: String(localized: "Date added, oldest first")
    case .dateAddedDescending: String(localized: "Date added, newest first")
    case .dateModifiedAscending: String(localized: "Date modified, oldest first")
    case .dateModifiedDescending: String(localized: "Date modified, newest first")
    case .typeAscending: String(localized: "Type, A to Z")
    case .typeDescending: String(localized: "Type, Z to A")
    case .watchStatusAscending: String(localized: "Unwatched first")
    case .watchStatusDescending: String(localized: "Watched first")
    }
  }
}
