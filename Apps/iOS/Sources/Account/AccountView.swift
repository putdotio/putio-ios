import PutioCore
import SwiftUI

struct AccountView: View {
  let runtime: PutioRuntime
  let account: PutioAccountSnapshot
  let preferences: PutioAccountPreferencesModel
  let appConfig: PutioAppConfigModel
  let downloads: PutioOfflineQueue
  let openDestination: AccountDestination?
  @Environment(\.openURL) private var openURL
  @Environment(\.locale) private var locale
  @State private var isRefreshingStorage = false
  @State private var signOutDownloadedBytes: Int64?
  @State private var confirmAlert: PutioConfirmAlert?
  @State private var saveFailures = PutioSettingSaveFailures()
  @State private var revealRequest: AccountSettingReveal?

  var body: some View {
    ScrollViewReader { proxy in
      settingsList
        .onChange(of: revealRequest) { _, request in
          guard let request else { return }
          withAnimation { proxy.scrollTo(request.row, anchor: .center) }
        }
        .onAppear {
          guard let open = openDestination else { return }
          Task { proxy.scrollTo(open, anchor: .center) }
        }
        .onChange(of: openDestination) { _, open in
          guard let open else { return }
          withAnimation { proxy.scrollTo(open) }
        }
    }
    .putioSettingSaveFailures(saveFailures)
  }

  private var settingsList: some View {
    List { settingsRows }
      .modifier(AccountListStyle(preferences: preferences, appConfig: appConfig))
      .putioConfirmAlert($confirmAlert)
  }

  @ViewBuilder private var settingsRows: some View {
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
        row(String(localized: "Exclusive links"), icon: .link, opens: .publicLinks)
          .accessibilityIdentifier("account.public-links")
        if account.trashEnabled {
          row(
            String(localized: "Trash"), icon: .trash,
            value: PutioFileRowModel.sizeText(bytes: account.trashSizeBytes),
            valueStyle: .measurement, opens: .trash
          )
          .accessibilityIdentifier("account.trash")
        }
      }
      switch settingsState {
      case .loading:
        AccountUntitledSection {
          PutioSettingsLoadingRow(String(localized: "Loading account settings"))
            .accessibilityIdentifier("account.settings-loading")
        }
        downloadsSection
      case .failed:
        AccountUntitledSection {
          PutioSettingsFailedRows(
            String(localized: "Couldn’t load account settings"),
            identifier: "account.settings-failed",
            retryIdentifier: "account.settings-retry"
          ) {
            retrySettingsLoad()
          }
        }
        downloadsSection
      case .ready:
        filesSection
        playbackSection
        subtitlesSection
        downloadsSection
        privacySection
        securitySection
        aboutSection
      }
      if preferences.settingsState != .loading {
        AccountUntitledSection {
          signOutRow
        }
      }
      if settingsState == .ready {
        PutioSettingsSection(String(localized: "Danger zone")) {
          row(String(localized: "Clear your data"), icon: .eraser, opens: .clearData)
            .accessibilityIdentifier("account.clear-data")
          row(
            String(localized: "Destroy your account"), icon: .userCircleMinus,
            opens: .destroyAccount
          )
          .accessibilityIdentifier("account.destroy-account")
        }
      }
    }
    .listRowBackground(PutioTheme.Colors.surface)
  }

  private func row(
    _ title: String, subtitle: String? = nil, icon: PutioIcon, value: String? = nil,
    valueStyle: PutioSettingValueStyle = .text, opens destination: AccountDestination
  ) -> some View {
    PutioNavigationValueRow(
      title, subtitle: subtitle, icon: icon, value: value, valueStyle: valueStyle,
      destination: destination
    )
    .putioListDetailRow(destination, style: .grouped)
    .id(destination)
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
    if !downloads.items.isEmpty {
      signOutDownloadedBytes = downloads.storedBytes
      return
    }
    let runtime = runtime
    let accountID = account.id
    confirmAlert = PutioConfirmAlert(
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
    if removingDownloads { downloads.purgeAccountStorage() }
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
        confirmAlert = PutioConfirmAlert(
          title: String(localized: "Reset all folder sorts?"),
          message: String(localized: "Every folder will use your account’s default sort."),
          confirmTitle: String(localized: "Reset folder sorts")
        ) {
          save(nil, .resetFolderSorts)
        }
      }
      .disabled(settingsLocked)
      .accessibilityIdentifier("settings.reset-sort")
    }
  }

  private var playbackSection: some View {
    PutioSettingsSection(String(localized: "Playback")) {
      PutioToggleRow(
        title: String(localized: "Resume where you left off"), icon: .playCircle,
        isOn: resumeEnabled
      )
      .disabled(settingsLocked)
      .id(AccountSettingRow.resume)
      .accessibilityIdentifier("playback-settings.resume")
      PutioPlaybackConfigRows(
        suggestsNextVideo: account.suggestNextVideo,
        showsRotation: UIDevice.current.userInterfaceIdiom == .phone,
        appConfig: appConfig,
        onSaveFailed: { write in
          switch write {
          case .autoplayNextVideo: reveal(.autoplay)
          case .autoRotateVideo: reveal(.autoRotate)
          case .playbackMethod: break
          }
        })
      row(
        String(localized: "Playback method"), icon: .filmStrip,
        value: appConfig.playbackMethod.title, opens: .playbackMethod
      )
      .accessibilityIdentifier("playback-settings.method")
      row(
        String(localized: "Proxy"), icon: .globe,
        value: preferences.account.map { PutioProxyChoices.title(for: $0.routeName) },
        opens: .proxy
      )
      .accessibilityIdentifier("playback-settings.route")
      row(String(localized: "Chromecast"), icon: .screencast, opens: .chromecast)
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

  private var downloadsSection: some View {
    PutioSettingsSection(String(localized: "Downloads")) {
      row(
        String(localized: "Downloads"), icon: .arrowCircleDown,
        value: PutioFileRowModel.sizeText(bytes: downloads.storedBytes),
        valueStyle: .measurement, opens: .downloads
      )
      .accessibilityIdentifier("account.downloads")
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
      row(
        PutioPrivacyControls.title, subtitle: PutioPrivacyControls.summary(for: account),
        icon: .shieldCheck, opens: .privacy
      )
      .accessibilityIdentifier("account.privacy")
    }
  }

  private var securitySection: some View {
    PutioSettingsSection(String(localized: "Security")) {
      row(String(localized: "Logged-in apps"), icon: .devices, opens: .loggedInApps)
        .accessibilityIdentifier("security.apps")
      row(String(localized: "Link a device"), icon: .plugs, opens: .linkDevice)
        .accessibilityIdentifier("security.link-device")
      PutioLinkRow(
        String(localized: "Two-factor authentication"), icon: .lockKey,
        value: account.twoFactorEnabled ? String(localized: "On") : String(localized: "Off")
      ) {
        openURL(PutioAccountWeb.securityURL)
      }
      .accessibilityIdentifier("account.two-factor")
    }
  }

  private var aboutSection: some View {
    PutioSettingsSection(String(localized: "About")) {
      row(
        String(localized: "App info"), icon: .info, value: PutioAppInfo.shortVersion,
        valueStyle: .measurement, opens: .appInfo
      )
      .accessibilityIdentifier("account.about")
      PutioLinkRow(String(localized: "Privacy policy"), icon: .fileText) {
        openURL(PutioPrivacyControls.privacyPolicyURL)
      }
      .accessibilityIdentifier("account.privacy-policy")
      row(String(localized: "Open source licenses"), icon: .list, opens: .licenses)
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

  private var settingsState: PutioAccountSettingsState {
    let accountSettings = preferences.settingsState
    guard accountSettings == .ready, appConfig.config == nil else { return accountSettings }
    return appConfig.failure != nil && !appConfig.isLoading ? .failed : .loading
  }

  private func retrySettingsLoad() {
    if preferences.settingsState == .failed { Task { await preferences.loadSettings() } }
    if appConfig.config == nil { Task { await appConfig.retry() } }
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
        if enabled { save(.trash, .trash(true)) } else { confirmTrashOff() }
      })
  }

  private var historyEnabled: Binding<Bool> {
    Binding(
      get: { preferences.account?.historyEnabled ?? false },
      set: { enabled in
        if enabled { save(.history, .history(true)) } else { confirmHistoryOff() }
      })
  }

  private var resumeEnabled: Binding<Bool> {
    Binding(
      get: { preferences.account?.rememberVideoTime ?? false },
      set: { enabled in
        if enabled { save(.resume, .resumePlayback(true)) } else { confirmResumeOff() }
      })
  }

  private func confirmResumeOff() {
    confirmAlert = PutioConfirmAlert(
      title: String(localized: "Turn off resume?"),
      message: String(
        localized: "This erases every saved playback position on your account, on all devices."),
      confirmTitle: String(localized: "Turn off")
    ) {
      save(.resume, .resumePlayback(false))
    }
  }

  private func confirmHistoryOff() {
    confirmAlert = PutioConfirmAlert(
      title: String(localized: "Turn off history?"),
      message: String(
        localized:
          "Existing history will be cleared and new account events will no longer be saved."),
      confirmTitle: String(localized: "Turn off")
    ) {
      save(.history, .history(false))
    }
  }

  private func confirmTrashOff() {
    confirmAlert = PutioConfirmAlert(
      title: String(localized: "Turn off trash?"),
      message: String(
        localized:
          "Deleted files will no longer be recoverable. Files already in trash stay for their 14 days."
      ),
      confirmTitle: String(localized: "Turn off")
    ) {
      save(.trash, .trash(false))
    }
  }

  private func save(_ row: AccountSettingRow?, _ mutation: PutioAccountPreferenceMutation) {
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

private struct AccountListStyle: ViewModifier {
  let preferences: PutioAccountPreferencesModel
  let appConfig: PutioAppConfigModel

  func body(content: Content) -> some View {
    content
      .listStyle(.insetGrouped)
      .listSectionSpacing(PutioTheme.Spacing.space1)
      .environment(\.defaultMinListHeaderHeight, PutioTheme.Spacing.space0)
      .navigationTitle("Account")
      .putioFont(PutioTheme.Typography.body)
      .putioContentBackground()
      .task { await preferences.loadSettingsIfNeeded() }
      .task { await appConfig.loadIfNeeded() }
  }
}

private struct AccountUntitledSection<Content: View>: View {
  @ViewBuilder let content: Content

  var body: some View {
    Section {
      content
    } header: {
      Color.clear
        .frame(height: PutioTheme.Spacing.space3)
        .listRowInsets(EdgeInsets())
        .accessibilityHidden(true)
    }
  }
}

enum AccountSettingRow: Hashable {
  case defaultSort, trash, resume, autoplay, autoRotate, showSubtitles
  case pickMatchingSubtitles
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
