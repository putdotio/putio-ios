import PutioCore
import SwiftUI
import UIKit

/// What a settings row asks for when the remote selects it.
enum TVAccountChange: Equatable {
  case save(PutioAccountPreferenceMutation)
  case confirm(TVAccountConfirmation)
  case showHome(Bool)
  case autoplay(Bool)
}

/// Changes that lose data or end the session, confirmed in an alert first.
enum TVAccountConfirmation: Identifiable, Equatable {
  case trashOff
  case historyOff
  case resumeOff
  case signOut

  var id: Self { self }

  var words: PutioConfirmation {
    switch self {
    case .trashOff: PutioAccountConfirmations.trashOff
    case .historyOff: PutioAccountConfirmations.historyOff
    case .resumeOff: PutioAccountConfirmations.resumeOff
    case .signOut: PutioAccountConfirmations.signOut(device: .appleTV)
    }
  }

  var confirmIdentifier: String {
    switch self {
    case .trashOff: "account.trash-disable-confirm"
    case .historyOff: "account.history-disable-confirm"
    case .resumeOff: "account.resume-disable-confirm"
    case .signOut: "auth.sign-out-confirm"
    }
  }
}

enum TVAccountSection: CaseIterable, Identifiable {
  case library
  case playback
  case subtitles
  case privacy
  case about
  case account

  var id: Self { self }

  var title: String {
    switch self {
    case .library: String(localized: "Library", bundle: .putioCore)
    case .playback: String(localized: "Playback", bundle: .putioCore)
    case .subtitles: String(localized: "Subtitles", bundle: .putioCore)
    case .privacy: String(localized: "Privacy", bundle: .putioCore)
    case .about: String(localized: "About", bundle: .putioCore)
    case .account: String(localized: "Account", bundle: .putioCore)
    }
  }

  /// There is deliberately no playback-type or buffer row on tvOS; the
  /// system player owns both.
  func rows(for account: PutioAccountSnapshot, offersAutoplay: Bool = false) -> [TVAccountRow] {
    switch self {
    case .library:
      (account.trashEnabled ? [.manageTrash] : [])
        + [.trash, .defaultSort, .history, .showHome]
    case .playback:
      offersAutoplay ? [.resume, .autoplay, .proxy] : [.resume, .proxy]
    case .subtitles:
      account.hideSubtitles ? [.showSubtitles] : [.showSubtitles, .subtitleSelection]
    case .privacy:
      [.privacy]
    case .about:
      [.appInfo, .licenses]
    case .account:
      [.manageAccount, .signOut]
    }
  }
}

enum TVAccountRow: Hashable, Identifiable {
  case manageTrash
  case trash
  case defaultSort
  case history
  case showHome
  case resume
  case autoplay
  case proxy
  case showSubtitles
  case subtitleSelection
  case privacy
  case appInfo
  case licenses
  case manageAccount
  case signOut

  var id: Self { self }

  var title: String {
    switch self {
    case .manageTrash: String(localized: "Manage your trash", bundle: .putioCore)
    case .trash: String(localized: "Move deleted files to trash", bundle: .putioCore)
    case .defaultSort: String(localized: "Default sort order", bundle: .putioCore)
    case .history: String(localized: "Keep account history", bundle: .putioCore)
    case .showHome: String(localized: "Show Home", bundle: .putioCore)
    case .resume: String(localized: "Resume where you left off", bundle: .putioCore)
    case .autoplay: String(localized: "Autoplay next video", bundle: .putioCore)
    case .proxy: String(localized: "Choose your proxy", bundle: .putioCore)
    case .showSubtitles: String(localized: "Show subtitles", bundle: .putioCore)
    case .subtitleSelection: String(localized: "Pick matching subtitles", bundle: .putioCore)
    case .privacy: PutioPrivacyControls.title
    case .appInfo: String(localized: "App info", bundle: .putioCore)
    case .licenses: String(localized: "Licenses", bundle: .putioCore)
    case .manageAccount: String(localized: "Manage account on the web", bundle: .putioCore)
    case .signOut: String(localized: "Sign out", bundle: .putioCore)
    }
  }

  var identifier: String {
    switch self {
    case .manageTrash: "account.manage-trash"
    case .trash: "account.trash"
    case .defaultSort: "account.default-sort"
    case .history: "account.history"
    case .showHome: "account.show-home"
    case .resume: "account.resume"
    case .autoplay: "account.autoplay"
    case .proxy: "account.proxy"
    case .showSubtitles: "account.show-subtitles"
    case .subtitleSelection: "account.subtitle-selection"
    case .privacy: "account.privacy"
    case .appInfo: "account.app-info"
    case .licenses: "account.licenses"
    case .manageAccount: "account.manage-account"
    case .signOut: "auth.sign-out"
    }
  }

  var icon: TVAccountIcon {
    switch self {
    case .manageTrash, .trash: .putio(.trash)
    case .defaultSort: .putio(.sortAscending)
    case .history: .putio(.clockCounterClockwise)
    case .showHome: .system("house")
    case .resume: .putio(.playCircle)
    case .autoplay: .putio(.skipForward)
    case .proxy: .putio(.globe)
    case .showSubtitles: .putio(.closedCaptioning)
    case .subtitleSelection: .putio(.listChecks)
    case .privacy: .putio(.shieldCheck)
    case .appInfo: .putio(.info)
    case .licenses: .putio(.fileText)
    case .manageAccount: .putio(.arrowSquareOut)
    case .signOut: .putio(.userCircleMinus)
    }
  }

  /// The value a two-state row shows; `nil` for every other row. "Pick
  /// matching subtitles" is the inverse of `dont_autoselect_subtitles`.
  func isOn(
    in account: PutioAccountSnapshot, showsHome: Bool = true, autoplay: Bool = false
  ) -> Bool? {
    switch self {
    case .trash: account.trashEnabled
    case .history: account.historyEnabled
    case .showHome: showsHome
    case .resume: account.rememberVideoTime
    case .autoplay: autoplay
    case .showSubtitles: !account.hideSubtitles
    case .subtitleSelection: !account.dontAutoSelectSubtitles
    case .manageTrash, .defaultSort, .proxy, .privacy, .appInfo, .licenses, .manageAccount,
      .signOut:
      nil
    }
  }

  /// What choosing `isOn` asks for; turning off trash, history, or resume
  /// loses data, so those ask first.
  func change(to isOn: Bool) -> TVAccountChange? {
    switch self {
    case .trash: isOn ? .save(.trash(true)) : .confirm(.trashOff)
    case .history: isOn ? .save(.history(true)) : .confirm(.historyOff)
    case .resume: isOn ? .save(.resumePlayback(true)) : .confirm(.resumeOff)
    case .showHome: .showHome(isOn)
    case .autoplay: .autoplay(isOn)
    case .showSubtitles: .save(.showSubtitles(isOn))
    case .subtitleSelection: .save(.dontAutoSelectSubtitles(!isOn))
    case .manageTrash, .defaultSort, .proxy, .privacy, .appInfo, .licenses, .manageAccount,
      .signOut:
      nil
    }
  }
}

enum TVAccountIcon: Equatable {
  case putio(PutioIcon)
  case system(String)

  var image: Image {
    switch self {
    case .putio(let icon): Image(putioIcon: icon)
    case .system(let name): Image(systemName: name)
    }
  }
}

extension PutioAppInfo {
  @MainActor static func currentTV(channel: PutioReleaseChannel = .appStore) -> PutioAppInfo {
    PutioAppInfo(
      channel: channel, device: UIDevice.current.model, systemName: "tvOS",
      systemVersion: UIDevice.current.systemVersion)
  }
}

/// The preferences model's state as the screen shows it.
struct TVAccountStatus: Equatable {
  var message: String?
  var retryTitle: String?
  var isSaving = false
  var isRefreshing = false
  var canSave = true

  static let idle = TVAccountStatus()

  @MainActor init(model: PutioAccountPreferencesModel) {
    message = model.statusMessage
    retryTitle = model.isStale || model.failure != nil ? model.retryTitle : nil
    isSaving = model.isSaving
    isRefreshing = model.isRefreshing
    canSave = model.canSave
  }

  init(
    message: String? = nil, retryTitle: String? = nil, isSaving: Bool = false,
    isRefreshing: Bool = false, canSave: Bool = true
  ) {
    self.message = message
    self.retryTitle = retryTitle
    self.isSaving = isSaving
    self.isRefreshing = isRefreshing
    self.canSave = canSave
  }
}

struct TVAccountView: View {
  let runtime: PutioRuntime
  let showHome: PutioShowHomePreference

  @State private var model: PutioAccountPreferencesModel
  @State private var proxy: PutioProxyChooserModel
  @State private var appConfig: PutioAppConfigModel
  @State private var hasAppeared = false
  @State private var channel = PutioReleaseChannel.appStore
  @State private var toast: PutioToast?

  init(runtime: PutioRuntime, showHome: PutioShowHomePreference) {
    self.runtime = runtime
    self.showHome = showHome
    let model = PutioAccountPreferencesModel(actions: .init(runtime: runtime))
    _model = State(initialValue: model)
    _proxy = State(
      initialValue: PutioProxyChooserModel(
        actions: PutioProxyChooserActions(runtime: runtime), preferences: model))
    _appConfig = State(initialValue: PutioAppConfigModel(actions: .init(runtime: runtime)))
  }

  var body: some View {
    Group {
      if let account = model.account,
        model.settingsState != .failed || model.isStale
      {
        TVAccountScreen(
          account: account,
          appInfo: .currentTV(channel: channel),
          status: TVAccountStatus(model: model),
          showsHome: showHome.isShown,
          autoplay: appConfig.offersAutoplay(suggestsNextVideo: account.suggestNextVideo)
            ? appConfig.autoplayNextVideo : nil,
          proxy: TVProxyMenuState(model: proxy),
          toast: $toast,
          save: { mutation in
            Task { report(await model.save(mutation)) }
          },
          selectProxy: { name in
            Task { report(await proxy.select(name)) }
          },
          retryProxy: { Task { await proxy.loadRoutes() } },
          setShowsHome: { showHome.set($0) },
          setAutoplay: { enabled in
            Task { report(await appConfig.setAutoplayNextVideo(enabled)) }
          },
          retry: { Task { await model.retry() } },
          signOut: {
            let accountID = account.id
            await runtime.session.signOut()
            PutioShowHomePreference.clear(accountID: accountID)
          }
        )
      } else if model.settingsState == .failed {
        TVAccountLoadFailure { Task { await model.loadSettings() } }
      } else {
        PutioLoadingStateView()
      }
    }
    .onAppear {
      if hasAppeared, !model.isBusy {
        Task { await Self.refreshAfterReturning(model: model) }
      }
      hasAppeared = true
    }
    .task { await model.loadSettingsIfNeeded() }
    .task { await appConfig.loadIfNeeded() }
    .task { await proxy.loadIfNeeded() }
    .task { channel = await PutioReleaseChannel.current() }
  }

  private func report(_ outcome: PutioSettingSaveOutcome) {
    if outcome == .failed || outcome == .unavailable {
      toast = PutioToast(TVAccountScreen.saveFailedMessage, icon: .warning)
    }
  }

  /// Back from Trash: restores and deletions change the trash size. The
  /// model's refresh reports a failure with its retry.
  static func refreshAfterReturning(model: PutioAccountPreferencesModel) async {
    await model.retryRefresh()
  }
}

/// "Couldn't load your settings." with its retry, in place of the list.
struct TVAccountLoadFailure: View {
  let retry: () -> Void

  var body: some View {
    PutioEmptyStateView(
      kaomoji: .uneasy,
      title: String(localized: "Couldn’t load your settings.", bundle: .putioCore),
      message: String(
        localized: "Check your internet connection and try again.", bundle: .putioCore),
      actionTitle: String(localized: "Try again", bundle: .putioCore),
      action: retry
    )
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .tvOverscanPadding()
    .background(PutioTheme.Colors.background.ignoresSafeArea())
    .accessibilityIdentifier("account.settings-failed")
  }
}

struct TVAccountScreen: View {
  let account: PutioAccountSnapshot
  var appInfo = PutioAppInfo.currentTV()
  var status = TVAccountStatus.idle
  var locale: Locale = .current
  var showsHome = true
  /// Autoplay's value, or `nil` while put.io doesn't offer it for this account.
  var autoplay: Bool?
  var proxy: TVProxyMenuState?
  /// The row the panel explains before focus lands, for a fixed rendering.
  var initialRow: TVAccountRow?
  var toast: Binding<PutioToast?> = .constant(nil)
  var save: (PutioAccountPreferenceMutation) -> Void = { _ in }
  var selectProxy: (String) -> Void = { _ in }
  var retryProxy: () -> Void = {}
  var setShowsHome: (Bool) -> Void = { _ in }
  var setAutoplay: (Bool) -> Void = { _ in }
  var retry: () -> Void = {}
  let signOut: () async -> Void

  @State private var confirmation: TVAccountConfirmation?
  @State private var panelRow: TVAccountRow?
  @FocusState private var focusedRow: TVAccountRow?

  static var saveFailedMessage: String {
    String(localized: "Couldn’t save this setting", bundle: .putioCore)
  }

  var body: some View {
    HStack(alignment: .top, spacing: TVAccountLayout.columnGap) {
      TVRowList {
        TVAccountProfile(account: account, locale: locale)
        if let notice = PutioInactiveAccountNotice(account: account) {
          TVInactiveAccountNotice(notice: notice, identifier: "account.status-notice")
        }
        statusSection
        ForEach(TVAccountSection.allCases) { section in
          TVSectionHeader(title: section.title)
          ForEach(section.rows(for: account, offersAutoplay: autoplay != nil)) { row in
            rowView(row)
              .focused($focusedRow, equals: row)
          }
        }
      }
      .frame(width: TVAccountLayout.listWidth)
      .defaultFocus($focusedRow, Self.firstRow(for: account))
      TVAccountPanel(content: panel(for: shownRow))
        .frame(width: TVAccountLayout.panelWidth)
        .frame(maxHeight: .infinity, alignment: .top)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    .tvOverscanPadding()
    .background(PutioTheme.Colors.background.ignoresSafeArea())
    .onChange(of: focusedRow) { _, row in
      if let row { panelRow = row }
    }
    .alert(
      confirmation?.words.title ?? "",
      isPresented: Binding(
        get: { confirmation != nil }, set: { if !$0 { confirmation = nil } }),
      presenting: confirmation
    ) { pending in
      Button(pending.words.confirmTitle, role: .destructive) { confirm(pending) }
        .accessibilityIdentifier(pending.confirmIdentifier)
      Button(String(localized: "Cancel", bundle: .putioCore), role: .cancel) {}
    } message: { pending in
      Text(pending.words.message)
    }
    .putioToast(toast)
  }

  private var shownRow: TVAccountRow {
    panelRow ?? initialRow ?? Self.firstRow(for: account)
  }

  static func firstRow(for account: PutioAccountSnapshot) -> TVAccountRow {
    account.trashEnabled ? .manageTrash : .trash
  }

  private func confirm(_ pending: TVAccountConfirmation) {
    switch pending {
    case .trashOff: save(.trash(false))
    case .historyOff: save(.history(false))
    case .resumeOff: save(.resumePlayback(false))
    case .signOut: Task { await signOut() }
    }
  }

  @ViewBuilder
  private var statusSection: some View {
    if status.message != nil || status.retryTitle != nil || status.isSaving {
      VStack(alignment: .leading, spacing: PutioTheme.TV.Spacing.small) {
        if let message = status.message {
          Text(message)
            .putioFont(PutioTheme.TV.Typography.caption)
            .foregroundStyle(PutioTheme.TV.Colors.textSecondary)
            .accessibilityIdentifier("account.settings-failure")
        }
        if let retryTitle = status.retryTitle {
          PutioButton(retryTitle, tier: .secondary, action: retry)
            .disabled(status.isSaving || status.isRefreshing)
            .accessibilityIdentifier("account.settings-retry")
        }
        if status.isSaving {
          ProgressView(PutioAccountPreferencesModel.savingTitle)
            .accessibilityIdentifier("account.saving")
        }
      }
      .padding(.horizontal, PutioTheme.TV.Spacing.medium)
      .focusSection()
    }
  }

  @ViewBuilder
  private func rowView(_ row: TVAccountRow) -> some View {
    switch row {
    case .manageTrash:
      NavigationLink(value: TVRoute.trash) {
        TVAccountRowLabel(row: row, value: trashSize, valueIsNumeric: true, opens: true)
      }
      .accessibilityIdentifier(row.identifier)
    case .proxy:
      let value = PutioProxyChoices.title(for: account.routeName)
      TVProxyMenu(
        state: proxy ?? TVProxyMenuState(selection: account.routeName),
        select: selectProxy, retry: retryProxy
      ) {
        TVAccountRowLabel(row: row, value: value, opens: true)
          .onFocusedChange { if $0 { panelRow = row } }
      }
      .disabled(!status.canSave)
      .accessibilityIdentifier(row.identifier)
      .accessibilityValue(value)
    case .privacy:
      NavigationLink(value: TVRoute.privacy) {
        TVAccountRowLabel(row: row, value: privacySummary, opens: true)
      }
      .accessibilityIdentifier(row.identifier)
    case .licenses:
      NavigationLink(value: TVRoute.licenses) {
        TVAccountRowLabel(row: row, opens: true)
      }
      .accessibilityIdentifier(row.identifier)
    case .appInfo, .manageAccount:
      Button {
      } label: {
        TVAccountRowLabel(row: row, opens: true)
      }
      .accessibilityIdentifier(row.identifier)
    case .defaultSort:
      TVDefaultSortMenu(current: account.defaultSort, save: { save(.defaultSort($0)) }) {
        TVAccountRowLabel(row: row, value: sortValue)
          .onFocusedChange { if $0 { panelRow = row } }
      }
      .disabled(!status.canSave)
      .accessibilityIdentifier(row.identifier)
      .accessibilityValue(sortValue)
    case .signOut:
      Button {
        confirmation = .signOut
      } label: {
        Text(row.title)
          .putioFont(PutioTheme.TV.Typography.body)
          .foregroundStyle(PutioTheme.Colors.destructive)
          .tvRowPadding()
      }
      .accessibilityIdentifier(row.identifier)
    case .trash, .history, .showHome, .resume, .autoplay, .showSubtitles, .subtitleSelection:
      let isOn = row.isOn(in: account, showsHome: showsHome, autoplay: autoplay ?? false) ?? false
      Button {
        switch row.change(to: !isOn) {
        case .save(let mutation): save(mutation)
        case .confirm(let pending): confirmation = pending
        case .showHome(let shown): setShowsHome(shown)
        case .autoplay(let enabled): setAutoplay(enabled)
        case nil: break
        }
      } label: {
        TVAccountRowLabel(row: row, value: Self.onOff(isOn))
      }
      .disabled(row.savesToAccount && !status.canSave)
      .accessibilityIdentifier(row.identifier)
      .accessibilityValue(Self.onOff(isOn))
    }
  }

  private var trashSize: String {
    PutioFileRowModel.sizeText(bytes: account.trashSizeBytes, locale: locale)
  }

  private var sortValue: String {
    (account.defaultSort ?? .nameAscending).menuLabel
  }

  private var privacySummary: String {
    account.productAnalyticsEnabled
      ? String(localized: "Analytics on", bundle: .putioCore)
      : String(localized: "Analytics off", bundle: .putioCore)
  }

  static func onOff(_ isOn: Bool) -> String {
    isOn
      ? String(localized: "On", bundle: .putioCore)
      : String(localized: "Off", bundle: .putioCore)
  }

  private func panel(for row: TVAccountRow) -> TVAccountPanelContent {
    var content = TVAccountPanelContent(row: row)
    switch row {
    case .manageTrash:
      content.description = String(
        localized:
          "Deleted items stay 14 days, then they’re gone for good. Trash counts toward your storage.",
        bundle: .putioCore)
      content.highlight = String(localized: "\(trashSize) in trash", bundle: .putioCore)
    case .trash:
      content.description = String(
        localized:
          "On: deleted files wait in trash for 14 days. Off: deleting removes files right away.",
        bundle: .putioCore)
    case .showHome:
      content.description = PutioShowHomePreference.offDescription
    case .resume:
      content.description = String(
        localized:
          "Saves your place in every video and picks up from there on any device.",
        bundle: .putioCore)
    case .proxy:
      content.description = PutioProxyChoices.summary
    case .subtitleSelection:
      content.description = String(
        localized: "Turns on subtitles in your language when a video has them.",
        bundle: .putioCore)
    case .appInfo:
      content.fields = appInfo.fields
      content.qr = TVAccountPanelQR(
        caption: String(localized: "Need help? Scan to contact support.", bundle: .putioCore),
        text: appInfo.supportText)
    case .manageAccount:
      content.description = String(
        localized: "Plan, billing, security and sessions live on the web. Scan with your phone.",
        bundle: .putioCore)
      content.qr = TVAccountPanelQR(text: TVAccountLayout.accountURL.absoluteString)
    case .signOut:
      content.description = String(
        localized: "Signs this Apple TV out. Your files and settings stay on your account.",
        bundle: .putioCore)
    case .privacy:
      content.description = PutioPrivacyControls.summary(for: account)
    case .licenses:
      content.description = PutioLicenseManifest.summary
    case .defaultSort, .history, .autoplay, .showSubtitles:
      break
    }
    return content
  }
}

extension TVAccountRow {
  /// Show Home and autoplay are kept apart from the account's settings, so
  /// a stale account doesn't block them.
  var savesToAccount: Bool {
    switch self {
    case .showHome, .autoplay: false
    default: true
    }
  }
}

enum TVAccountLayout {
  static let listWidth: CGFloat = 1064
  static let panelWidth: CGFloat = 640
  static let columnGap: CGFloat = 56
  static let avatarSize: CGFloat = 72
  static let meterHeight: CGFloat = 6
  static let panelIconTile: CGFloat = 96
  static let panelIconSize: CGFloat = 44
  static let rowIconSize: CGFloat = 32
  static let qrSize: CGFloat = 220
  static let accountURL = URL(string: "https://app.put.io/account")!
  static let nameFont = PutioFontRole(
    fontName: "GTAmerica-Md", size: 36, lineHeight: 1.25, textStyle: .headline)
  static let panelTitleFont = PutioFontRole(
    fontName: "GTAmerica-Md", size: 40, lineHeight: 1.2, textStyle: .headline)
  static let highlightFont = PutioFontRole(
    fontName: "GTAmerica-Md", size: 40, lineHeight: 1.2, textStyle: .headline)
}

/// The account's avatar, name, email, and storage meter, with a warning once
/// storage is almost full.
struct TVAccountProfile: View {
  let account: PutioAccountSnapshot
  let locale: Locale

  var body: some View {
    HStack(alignment: .center, spacing: PutioTheme.TV.Spacing.medium) {
      TVAvatar(url: account.avatarURL, username: account.username)
      VStack(alignment: .leading, spacing: PutioTheme.TV.Spacing.xs) {
        Text(account.username)
          .putioFont(TVAccountLayout.nameFont)
          .foregroundStyle(PutioTheme.TV.Colors.textPrimary)
          .accessibilityIdentifier("account.username")
        HStack(alignment: .firstTextBaseline) {
          Text(account.email)
            .putioFont(PutioTheme.TV.Typography.small)
            .foregroundStyle(PutioTheme.TV.Colors.textSecondary)
            .lineLimit(1)
          Spacer(minLength: PutioTheme.TV.Spacing.small)
          Text(account.storage.usageSummary(locale: locale))
            .putioFont(PutioTabularFontRole(base: PutioTheme.TV.Typography.small))
            .foregroundStyle(PutioTheme.TV.Colors.textSecondary)
            .accessibilityIdentifier("account.storage")
        }
        TVStorageBar(fraction: account.storage.usedFraction, isWarning: isWarning)
        if isWarning {
          Label {
            Text(
              account.storage.isFull
                ? PutioAccountSnapshot.Storage.fullMessage
                : PutioAccountSnapshot.Storage.almostFullMessage)
          } icon: {
            Image(putioIcon: .warningCircle)
              .resizable()
              .scaledToFit()
              .frame(width: TVAccountLayout.rowIconSize, height: TVAccountLayout.rowIconSize)
          }
          .putioFont(PutioTheme.TV.Typography.small)
          .foregroundStyle(PutioTheme.Colors.destructive)
          .accessibilityIdentifier("account.storage-warning")
        }
      }
    }
    .padding(.horizontal, PutioTheme.TV.Spacing.medium)
    .padding(.bottom, PutioTheme.TV.Spacing.small)
  }

  private var isWarning: Bool {
    account.storage.isFull || account.storage.isAlmostFull
  }
}

private struct TVStorageBar: View {
  let fraction: Double
  let isWarning: Bool

  var body: some View {
    GeometryReader { proxy in
      ZStack(alignment: .leading) {
        Capsule().fill(PutioTheme.Colors.surfaceActive)
        Capsule()
          .fill(isWarning ? PutioTheme.Colors.destructive : PutioTheme.Colors.accent)
          .frame(width: max(TVAccountLayout.meterHeight, proxy.size.width * min(1, fraction)))
      }
    }
    .frame(height: TVAccountLayout.meterHeight)
    .accessibilityHidden(true)
  }
}

/// An icon, the row's title, and its value on the right.
struct TVAccountRowLabel: View {
  let row: TVAccountRow
  var value: String?
  var valueIsNumeric = false
  var opens = false

  var body: some View {
    HStack(spacing: PutioTheme.TV.Spacing.small) {
      row.icon.image
        .resizable()
        .scaledToFit()
        .frame(width: TVAccountLayout.rowIconSize, height: TVAccountLayout.rowIconSize)
        .foregroundStyle(.putioRowSecondary)
        .accessibilityHidden(true)
      Text(row.title)
        .putioFont(PutioTheme.TV.Typography.body)
        .foregroundStyle(.putioRowPrimary)
        .lineLimit(1)
      Spacer(minLength: PutioTheme.TV.Spacing.small)
      if let value {
        Group {
          if valueIsNumeric {
            Text(value).putioFont(PutioTabularFontRole(base: PutioTheme.TV.Typography.body))
          } else {
            Text(value).putioFont(PutioTheme.TV.Typography.body)
          }
        }
        .foregroundStyle(.putioRowSecondary)
        .lineLimit(1)
        .truncationMode(.middle)
      }
      if opens { TVDisclosure() }
    }
    .tvRowPadding()
  }
}

/// The default sort as the system menu: the sort field, its order, and the
/// video watch-status orders.
struct TVDefaultSortMenu<Content: View>: View {
  let current: PutioFolderSort?
  let save: (PutioFolderSort) -> Void
  @ViewBuilder let label: Content

  var body: some View {
    let choices = PutioFolderSortChoices(current: current ?? .nameAscending)
    Menu {
      Section(String(localized: "Sort by", bundle: .putioCore)) {
        ForEach(PutioFolderSortChoices.fields, id: \.self) { field in
          option(field.menuTitle, checked: choices.checkedField == field) {
            save(choices.selecting(field))
          }
        }
      }
      Section(String(localized: "Order", bundle: .putioCore)) {
        ForEach(choices.orders, id: \.self) { sort in
          option(sort.orderTitle, checked: choices.isChecked(sort)) { save(sort) }
        }
      }
      Section(PutioFolderSortKey.watchStatus.menuTitle) {
        ForEach(PutioFolderSortChoices.videoOrders, id: \.self) { sort in
          option(sort.orderTitle, checked: choices.isChecked(sort)) { save(sort) }
        }
      }
    } label: {
      label
    }
    .menuStyle(.button)
  }

  @ViewBuilder
  private func option(_ title: String, checked: Bool, action: @escaping () -> Void)
    -> some View
  {
    Button(action: action) {
      if checked {
        Label(title, systemImage: "checkmark")
      } else {
        Text(title)
      }
    }
  }
}

struct TVAccountPanelQR: Equatable {
  var caption: String?
  let text: String
}

struct TVAccountPanelContent: Equatable {
  let row: TVAccountRow
  var title: String?
  var description: String?
  var highlight: String?
  var fields: [PutioAppInfo.Field] = []
  var qr: TVAccountPanelQR?
}

/// The panel beside the list that explains the focused row.
struct TVAccountPanel: View {
  let content: TVAccountPanelContent

  var body: some View {
    VStack(alignment: .leading, spacing: PutioTheme.TV.Spacing.medium) {
      HStack(spacing: PutioTheme.TV.Spacing.small) {
        ZStack {
          RoundedRectangle(cornerRadius: PutioTheme.TV.radius * 2, style: .continuous)
            .fill(PutioTheme.Colors.surfaceActive)
          content.row.icon.image
            .resizable()
            .scaledToFit()
            .frame(width: TVAccountLayout.panelIconSize, height: TVAccountLayout.panelIconSize)
            .foregroundStyle(PutioTheme.Colors.accent)
        }
        .frame(width: TVAccountLayout.panelIconTile, height: TVAccountLayout.panelIconTile)
        .accessibilityHidden(true)
        Text(content.title ?? content.row.title)
          .putioFont(TVAccountLayout.panelTitleFont)
          .foregroundStyle(PutioTheme.TV.Colors.textPrimary)
          .accessibilityIdentifier("account.panel.\(content.row.identifier)")
      }
      if let description = content.description {
        Text(description)
          .putioFont(PutioTheme.TV.Typography.caption)
          .foregroundStyle(PutioTheme.TV.Colors.textSecondary)
          .fixedSize(horizontal: false, vertical: true)
      }
      if let highlight = content.highlight {
        Text(highlight)
          .putioFont(PutioTabularFontRole(base: TVAccountLayout.highlightFont))
          .foregroundStyle(PutioTheme.TV.Colors.textPrimary)
      }
      if !content.fields.isEmpty {
        Grid(alignment: .leading, horizontalSpacing: PutioTheme.TV.Spacing.medium) {
          ForEach(content.fields, id: \.id) { field in
            GridRow {
              Text(field.title)
                .foregroundStyle(PutioTheme.TV.Colors.textSecondary)
              Text(field.value)
                .foregroundStyle(PutioTheme.TV.Colors.textPrimary)
            }
            .putioFont(PutioTheme.TV.Typography.small)
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("account.app-info.\(field.id)")
          }
        }
      }
      if let qr = content.qr {
        if let caption = qr.caption {
          Text(caption)
            .putioFont(PutioTheme.TV.Typography.small)
            .foregroundStyle(PutioTheme.TV.Colors.textSecondary)
        }
        PutioQRCodeView(qr.text, size: TVAccountLayout.qrSize)
          .accessibilityIdentifier("account.panel-qr")
      }
      Spacer(minLength: 0)
    }
    .padding(PutioTheme.TV.Spacing.medium)
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    .background(
      PutioTheme.Colors.surface,
      in: RoundedRectangle(cornerRadius: PutioTheme.TV.radius * 3, style: .continuous)
    )
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("account.panel")
  }
}

/// A label-left, value-right row, the 10-foot settings pattern.
struct TVValueRow: View {
  let title: String
  let value: String
  var caption: String?
  var opens = false

  var body: some View {
    HStack(spacing: PutioTheme.TV.Spacing.small) {
      VStack(alignment: .leading, spacing: PutioTheme.TV.Spacing.xs) {
        Text(title)
          .putioFont(TVValueRow.titleFont)
          .foregroundStyle(.putioRowPrimary)
        if let caption {
          Text(caption)
            .putioFont(PutioTheme.TV.Typography.caption)
            .foregroundStyle(.putioRowSecondary)
        }
      }
      Spacer(minLength: PutioTheme.TV.Spacing.small)
      Text(value)
        .putioFont(PutioTheme.TV.Typography.body)
        .foregroundStyle(.putioRowSecondary)
        .lineLimit(1)
        .truncationMode(.middle)
      if opens { TVDisclosure() }
    }
    .tvRowPadding()
  }

  /// The kit's form-row title face, so every settings title reads alike.
  static let titleFont = PutioFontRole(
    fontName: PutioTheme.Components.Button.label.fontName,
    size: PutioTheme.TV.Typography.body.size,
    lineHeight: PutioTheme.TV.Typography.body.lineHeight,
    textStyle: PutioTheme.TV.Typography.body.textStyle
  )
}

/// The account avatar, or the username's initial while it loads or when the
/// account has none.
struct TVAvatar: View {
  let url: URL?
  let username: String

  var body: some View {
    AsyncImage(url: url) { phase in
      if let image = phase.image {
        image.resizable().scaledToFill()
      } else {
        initial
      }
    }
    .frame(width: TVAccountLayout.avatarSize, height: TVAccountLayout.avatarSize)
    .clipShape(Circle())
    .accessibilityHidden(true)
  }

  private var initial: some View {
    ZStack {
      PutioTheme.Colors.surfaceActive
      Text(username.first.map { String($0).uppercased() } ?? "")
        .putioFont(TVAccountLayout.nameFont)
        .foregroundStyle(PutioTheme.TV.Colors.textPrimary)
    }
  }
}

/// What the proxy menu offers: put.io's routes once they load, else the
/// load's failure with a retry.
struct TVProxyMenuState: Equatable {
  var selection: String
  var choices: PutioProxyChoices?
  var isLoading = false
  var failure: String?
  var canSelect = true

  @MainActor init(model: PutioProxyChooserModel) {
    selection = model.selection
    choices = model.choices
    isLoading = model.isLoadingRoutes
    failure = model.loadFailure
    canSelect = model.canSelect
  }

  init(
    selection: String, choices: PutioProxyChoices? = nil, isLoading: Bool = false,
    failure: String? = nil, canSelect: Bool = true
  ) {
    self.selection = selection
    self.choices = choices
    self.isLoading = isLoading
    self.failure = failure
    self.canSelect = canSelect
  }
}

/// "Choose your proxy" as the system menu, Direct first.
struct TVProxyMenu<Content: View>: View {
  let state: TVProxyMenuState
  let select: (String) -> Void
  let retry: () -> Void
  @ViewBuilder let label: Content

  var body: some View {
    Menu {
      if let choices = state.choices {
        ForEach(choices.names, id: \.self) { name in
          Button {
            select(name)
          } label: {
            if name == state.selection {
              Label(PutioProxyChoices.title(for: name), systemImage: "checkmark")
            } else {
              Text(PutioProxyChoices.title(for: name))
            }
          }
          .disabled(!state.canSelect)
          .accessibilityIdentifier("proxy.route.\(name)")
        }
      } else if let failure = state.failure {
        Section(String(localized: "Couldn’t load proxies", bundle: .putioCore)) {
          Button(String(localized: "Try again", bundle: .putioCore), action: retry)
            .accessibilityIdentifier("proxy.retry")
            .accessibilityHint(failure)
        }
      } else {
        Text(String(localized: "Loading proxies…", bundle: .putioCore))
          .accessibilityIdentifier("proxy.loading")
      }
    } label: {
      label
    }
    .menuStyle(.button)
  }
}

/// Reports the system focus of the control this label sits in. A `Menu`
/// takes no part in `@FocusState`, so its label reads focus from the
/// environment instead.
private struct TVFocusedChange: ViewModifier {
  let action: (Bool) -> Void
  @Environment(\.isFocused) private var isFocused

  func body(content: Content) -> some View {
    content.onChange(of: isFocused, initial: true) { _, focused in action(focused) }
  }
}

extension View {
  fileprivate func onFocusedChange(_ action: @escaping (Bool) -> Void) -> some View {
    modifier(TVFocusedChange(action: action))
  }
}
