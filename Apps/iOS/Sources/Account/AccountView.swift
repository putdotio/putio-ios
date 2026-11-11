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
  let onDataCleared: @MainActor (Set<PutioAccountDataCategory>, Bool) -> Void
  let onAccountDestroyed: @MainActor () -> Void
  @Environment(\.openURL) private var openURL
  @State private var preferences: PutioAccountPreferencesModel
  @State private var isRefreshingStorage = false
  @State private var confirmsSignOut = false
  @State private var confirmation: AccountSettingConfirmation?

  init(
    runtime: PutioRuntime,
    account: PutioAccountSnapshot,
    refreshRequests: PutioFolderRefreshRequests,
    trashReconciliation: PutioTrashReconciliation,
    cast: PutioCastModel,
    appConfig: PutioAppConfigModel,
    showsLinkDevice: Binding<Bool>,
    linkDeviceCode: String?,
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
    self.onDataCleared = onDataCleared
    self.onAccountDestroyed = onAccountDestroyed
    _preferences = State(
      initialValue: PutioAccountPreferencesModel(actions: .init(runtime: runtime)))
  }

  var body: some View {
    List {
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
        preferencesStatusSection
        filesSection
        playbackSection
        subtitlesSection
        privacySection
        securitySection
        aboutSection
        Section {
          PutioDestructiveRow(String(localized: "Sign out"), alignment: .center) {
            confirmsSignOut = true
          }
          .accessibilityIdentifier("auth.sign-out")
        }
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
      .listRowBackground(PutioTheme.Colors.surface)
    }
    .navigationTitle("Account")
    .putioFont(PutioTheme.Typography.body)
    .putioContentBackground()
    .task { await appConfig.loadIfNeeded() }
    .alert("Are you sure?", isPresented: $confirmsSignOut) {
      Button("Cancel", role: .cancel) {}
      Button("Log out", role: .destructive) {
        PutioFilesNavigationRestoration().clear(accountID: account.id)
        Task { await runtime.session.signOut() }
      }
      .accessibilityIdentifier("auth.sign-out-confirm")
    }
    .confirmationDialog(
      confirmation?.title ?? String(localized: "Update settings?"),
      isPresented: Binding(
        get: { confirmation != nil },
        set: { if !$0 { confirmation = nil } }),
      titleVisibility: .visible
    ) {
      switch confirmation {
      case .trash:
        Button("Turn Off Trash", role: .destructive) { save(.trash(false)) }
          .accessibilityIdentifier("settings.trash-disable")
      case .history:
        Button("Turn Off History", role: .destructive) { save(.history(false)) }
          .accessibilityIdentifier("settings.history-disable")
      case .resetSort:
        Button("Reset Folder Sorts", role: .destructive) { save(.resetFolderSorts) }
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
          .tint(PutioTheme.Colors.accent)
          .accessibilityHidden(true)
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
    Text(account.storage.usageSummary())
      .putioFont(PutioTheme.Typography.numeric)
      .foregroundStyle(PutioTheme.Colors.textSecondary)
      .accessibilityIdentifier("account.storage-used")
  }

  @ViewBuilder private var preferencesStatusSection: some View {
    if preferences.isStale {
      Section {
        Text(
          preferences.failure
            ?? String(localized: "Account settings could not be confirmed. Refresh to continue.")
        )
        .foregroundStyle(PutioTheme.Colors.textSecondary)
        Button(preferences.isRefreshing ? "Refreshing…" : "Refresh account") {
          Task { await preferences.retryRefresh() }
        }
        .disabled(preferences.isBusy)
        .accessibilityIdentifier("settings.refresh")
      }
    } else if let failure = preferences.failure {
      Section {
        Text(failure)
          .foregroundStyle(PutioTheme.Colors.textSecondary)
        if preferences.failedMutation != nil {
          Button("Try again") { Task { await preferences.retrySave() } }
            .disabled(preferences.isBusy)
            .accessibilityIdentifier("settings.retry-save")
        }
      }
    }
  }

  private var filesSection: some View {
    PutioSettingsSection(String(localized: "Files")) {
      PutioPickerRow(
        title: String(localized: "Default sort order"),
        icon: .sortAscending,
        selection: defaultSort,
        options: sortOptions
      ) { sort in
        sort?.title ?? String(localized: "Current server setting")
      }
      .disabled(settingsLocked)
      .accessibilityIdentifier("settings.default-sort")
      PutioToggleRow(
        title: String(localized: "Move deleted files to trash"), icon: .trash,
        isOn: trashEnabled
      )
      .disabled(settingsLocked)
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
        appConfig: appConfig)
      PutioNavigationRow(
        String(localized: "Proxy"), icon: .globe, value: preferences.account?.routeName
      ) {
        ProxySettingsView(runtime: runtime, preferences: preferences)
      }
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
        title: String(localized: "Show subtitles"), icon: .closedCaptioning, isOn: showSubtitles
      )
      .disabled(settingsLocked)
      .accessibilityIdentifier("playback-settings.subtitles")
      if !(preferences.account ?? account).hideSubtitles {
        PutioToggleRow(
          title: String(localized: "Pick matching subtitles"), icon: .listChecks,
          isOn: pickMatchingSubtitles
        )
        .disabled(settingsLocked)
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

  private var settingsLocked: Bool { preferences.isBusy || preferences.isStale }

  private var sortOptions: [PutioFolderSort?] {
    let sorts = PutioFolderSort.allCases.map(Optional.some)
    return preferences.account?.defaultSort == nil ? [nil] + sorts : sorts
  }

  private var defaultSort: Binding<PutioFolderSort?> {
    Binding(
      get: { preferences.account?.defaultSort },
      set: { if let sort = $0 { save(.defaultSort(sort)) } })
  }

  private var trashEnabled: Binding<Bool> {
    Binding(
      get: { preferences.account?.trashEnabled ?? false },
      set: { enabled in
        if enabled { save(.trash(true)) } else { confirmation = .trash }
      })
  }

  private var historyEnabled: Binding<Bool> {
    Binding(
      get: { preferences.account?.historyEnabled ?? false },
      set: { enabled in
        if enabled { save(.history(true)) } else { confirmation = .history }
      })
  }

  private var showSubtitles: Binding<Bool> {
    Binding(
      get: { !(preferences.account ?? account).hideSubtitles },
      set: { save(.showSubtitles($0)) })
  }

  private var pickMatchingSubtitles: Binding<Bool> {
    Binding(
      get: { !(preferences.account ?? account).dontAutoSelectSubtitles },
      set: { save(.dontAutoSelectSubtitles(!$0)) })
  }

  private func save(_ mutation: PutioAccountPreferenceMutation) {
    confirmation = nil
    Task { await preferences.save(mutation) }
  }

  private func reconcileRestoredFile(destinationID: PutioFileID?) {
    PutioRestoredFileReconciliation.apply(destinationID: destinationID, to: refreshRequests)
  }
}

struct PutioPlaybackConfigRows: View {
  let suggestsNextVideo: Bool
  let showsRotation: Bool
  let appConfig: PutioAppConfigModel

  var body: some View {
    if appConfig.config != nil {
      if suggestsNextVideo {
        PutioToggleRow(
          title: String(localized: "Autoplay next video"), icon: .skipForward,
          isOn: autoplayNextVideo
        )
        .disabled(!appConfig.canSave)
        .accessibilityIdentifier("playback-settings.autoplay")
      }
      if showsRotation {
        PutioToggleRow(
          title: String(localized: "Rotate to landscape"), icon: .deviceRotate,
          isOn: autoRotateVideo
        )
        .disabled(!appConfig.canSave)
        .accessibilityIdentifier("playback-settings.auto-rotate")
      }
    } else if appConfig.isLoading, suggestsNextVideo || showsRotation {
      ProgressView("Loading playback settings")
    }
    if let failure = appConfig.failure, suggestsNextVideo || showsRotation {
      Text(failure).foregroundStyle(PutioTheme.Colors.textSecondary)
      Button("Try again") { Task { await appConfig.retry() } }
        .disabled(appConfig.isBusy)
        .accessibilityIdentifier("playback-settings.retry-autoplay")
    }
  }

  private var autoplayNextVideo: Binding<Bool> {
    Binding(
      get: { appConfig.autoplayNextVideo },
      set: { enabled in Task { await appConfig.setAutoplayNextVideo(enabled) } })
  }

  private var autoRotateVideo: Binding<Bool> {
    Binding(
      get: { appConfig.autoRotateVideo },
      set: { enabled in Task { await appConfig.setAutoRotateVideo(enabled) } })
  }
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
