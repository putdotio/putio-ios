import PutioCore
import SwiftUI
import UIKit

/// What a settings row asks for when the remote selects it.
enum TVAccountChange: Equatable {
  case save(PutioAccountPreferenceMutation)
  /// Turning Trash off deletes everything in it, so it is confirmed first.
  case confirmDisablingTrash
}

enum TVAccountSection: CaseIterable, Identifiable {
  case playback
  case storage
  case about

  var id: Self { self }

  var title: String {
    switch self {
    case .playback: "Playback settings"
    case .storage: "Storage settings"
    case .about: "App and device information"
    }
  }

  /// The shipped TV app's rows. There is deliberately no playback-type or
  /// buffer row on tvOS; the system player owns both.
  func rows(for account: PutioAccountSnapshot) -> [TVAccountRow] {
    switch self {
    case .playback:
      // Subtitle selection only applies while subtitles are shown.
      account.hideSubtitles
        ? [.proxy, .rememberPosition, .showSubtitles]
        : [.proxy, .rememberPosition, .showSubtitles, .subtitleSelection]
    case .storage:
      account.trashEnabled ? [.trash, .manageTrash] : [.trash]
    case .about:
      [.appInfo("version"), .appInfo("channel"), .appInfo("device"), .appInfo("os"), .appInfo("player")]
    }
  }
}

enum TVAccountRow: Hashable, Identifiable {
  case proxy
  case rememberPosition
  case showSubtitles
  case subtitleSelection
  case trash
  case manageTrash
  /// A `PutioAppInfo` field, by its id.
  case appInfo(String)

  var id: Self { self }

  var title: String {
    switch self {
    case .proxy: "Choose your proxy"
    case .rememberPosition: "Remember current place in video files"
    case .showSubtitles: "Show subtitles"
    case .subtitleSelection: "Do not select subtitles by default"
    case .trash: "Move deleted files to trash"
    case .manageTrash: "Manage your trash"
    case .appInfo(let field): field
    }
  }

  var identifier: String {
    switch self {
    case .proxy: "account.proxy"
    case .rememberPosition: "account.remember-position"
    case .showSubtitles: "account.show-subtitles"
    case .subtitleSelection: "account.subtitle-selection"
    case .trash: "account.trash"
    case .manageTrash: "account.manage-trash"
    case .appInfo(let field): "account.app-info.\(field)"
    }
  }

  /// The value a two-state row shows; `nil` for every other row.
  func isOn(in account: PutioAccountSnapshot) -> Bool? {
    switch self {
    case .rememberPosition: account.rememberVideoTime
    case .showSubtitles: !account.hideSubtitles
    case .subtitleSelection: account.dontAutoSelectSubtitles
    case .trash: account.trashEnabled
    case .proxy, .manageTrash, .appInfo: nil
    }
  }

  /// What choosing `isOn` asks for, or `nil` when the app cannot change the
  /// row. putio-sdk-swift's settings patch cannot write
  /// `use_start_from`, so remember-position is shown but not editable.
  func change(to isOn: Bool) -> TVAccountChange? {
    switch self {
    case .showSubtitles: .save(.showSubtitles(isOn))
    case .subtitleSelection: .save(.dontAutoSelectSubtitles(isOn))
    case .trash: isOn ? .save(.trash(true)) : .confirmDisablingTrash
    case .rememberPosition, .proxy, .manageTrash, .appInfo: nil
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

  @State private var model: PutioAccountPreferencesModel
  @State private var hasAppeared = false

  init(runtime: PutioRuntime) {
    self.runtime = runtime
    _model = State(initialValue: PutioAccountPreferencesModel(actions: .init(runtime: runtime)))
  }

  var body: some View {
    Group {
      if let account = model.account {
        TVAccountScreen(
          account: account,
          status: TVAccountStatus(model: model),
          save: { mutation in Task { await model.save(mutation) } },
          retry: { Task { await model.retry() } },
          signOut: { await runtime.session.signOut() }
        )
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
  }

  /// Back from Trash: restores and deletions change the trash size. The
  /// model's refresh reports a failure with its retry.
  static func refreshAfterReturning(model: PutioAccountPreferencesModel) async {
    await model.retryRefresh()
  }
}

struct TVAccountScreen: View {
  let account: PutioAccountSnapshot
  var appInfo = PutioAppInfo.currentTV()
  var status = TVAccountStatus.idle
  var locale: Locale = .current
  var save: (PutioAccountPreferenceMutation) -> Void = { _ in }
  var retry: () -> Void = {}
  let signOut: () async -> Void

  @State private var confirmsSignOut = false
  @State private var confirmsDisablingTrash = false
  @FocusState private var focusedRow: TVAccountRow?

  var body: some View {
    VStack(alignment: .leading, spacing: PutioTheme.TV.Spacing.medium) {
      header
      if let notice = PutioInactiveAccountNotice(account: account) {
        TVInactiveAccountNotice(notice: notice, identifier: "account.status-notice")
      }
      TVRowList {
        statusSection
        ForEach(TVAccountSection.allCases) { section in
          TVSectionHeader(title: section.title)
          ForEach(section.rows(for: account)) { row in
            rowView(row)
              .focused($focusedRow, equals: row)
          }
        }
      }
      .defaultFocus($focusedRow, .proxy)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    .tvOverscanPadding()
    .background(PutioTheme.Colors.background.ignoresSafeArea())
    .confirmationDialog(
      signOutConfirmation.title, isPresented: $confirmsSignOut, titleVisibility: .visible
    ) {
      Button(signOutConfirmation.confirmTitle, role: .destructive) {
        Task { await signOut() }
      }
      .accessibilityIdentifier("auth.sign-out-confirm")
      Button("Cancel", role: .cancel) {}
    } message: {
      Text(signOutConfirmation.message)
    }
    .alert(trashOffConfirmation.title, isPresented: $confirmsDisablingTrash) {
      Button(trashOffConfirmation.confirmTitle, role: .destructive) { save(.trash(false)) }
        .accessibilityIdentifier("account.trash-disable-confirm")
      Button("Cancel", role: .cancel) {}
    } message: {
      Text(trashOffConfirmation.message)
    }
  }

  private let signOutConfirmation = PutioAccountConfirmations.signOut(device: .appleTV)
  private let trashOffConfirmation = PutioAccountConfirmations.trashOff

  private var header: some View {
    HStack(alignment: .center, spacing: PutioTheme.TV.Spacing.medium) {
      TVAvatar(url: account.avatarURL, username: account.username)
      VStack(alignment: .leading, spacing: PutioTheme.TV.Spacing.xs) {
        Text(account.username)
          .putioFont(PutioTheme.TV.Typography.label)
          .foregroundStyle(PutioTheme.TV.Colors.textPrimary)
          .accessibilityIdentifier("account.username")
        Text(account.storage.usageSummary(locale: locale))
          .putioFont(PutioTheme.TV.Typography.numeric)
          .foregroundStyle(PutioTheme.TV.Colors.textSecondary)
          .accessibilityIdentifier("account.storage")
        ProgressView(value: account.storage.usedFraction)
          .tint(PutioTheme.Colors.accent)
          .frame(maxWidth: TVAccountLayout.storageWidth)
          .accessibilityLabel("Storage used")
      }
      Spacer(minLength: PutioTheme.TV.Spacing.medium)
      PutioButton("Log out", tier: .secondary) {
        confirmsSignOut = true
      }
      .accessibilityIdentifier("auth.sign-out")
    }
    .focusSection()
  }

  @ViewBuilder
  private var statusSection: some View {
    if status.message != nil || status.retryTitle != nil || status.isSaving {
      VStack(alignment: .leading, spacing: PutioTheme.TV.Spacing.small) {
        if let message = status.message {
          Text(message)
            .putioFont(PutioTheme.TV.Typography.body)
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
    }
  }

  @ViewBuilder
  private func rowView(_ row: TVAccountRow) -> some View {
    switch row {
    case .proxy:
      NavigationLink(value: TVRoute.proxy) {
        TVValueRow(
          title: row.title, value: PutioProxyChoices.title(for: account.routeName), opens: true)
      }
      .disabled(!status.canSave)
      .accessibilityIdentifier(row.identifier)
    case .manageTrash:
      NavigationLink(value: TVRoute.trash) {
        TVValueRow(
          title: row.title,
          value: PutioFileRowModel.sizeText(bytes: account.trashSizeBytes, locale: locale),
          opens: true)
      }
      .accessibilityIdentifier(row.identifier)
    case .showSubtitles, .subtitleSelection, .trash:
      let isOn = row.isOn(in: account) ?? false
      // Selecting the row cycles its value; there is no toggle on tvOS.
      Button {
        switch row.change(to: !isOn) {
        case .save(let mutation): save(mutation)
        case .confirmDisablingTrash: confirmsDisablingTrash = true
        case nil: break
        }
      } label: {
        TVValueRow(title: row.title, value: Self.onOff(isOn))
      }
      .disabled(!status.canSave)
      .accessibilityIdentifier(row.identifier)
      .accessibilityValue(Self.onOff(isOn))
    case .rememberPosition:
      TVValueRow(
        title: row.title, value: Self.onOff(account.rememberVideoTime),
        caption: "Change this setting on app.put.io."
      )
      .accessibilityElement(children: .combine)
      .accessibilityIdentifier(row.identifier)
    case .appInfo(let id):
      if let field = appInfo.fields.first(where: { $0.id == id }) {
        TVValueRow(title: field.title, value: field.value)
          .accessibilityElement(children: .combine)
          .accessibilityIdentifier(row.identifier)
      }
    }
  }

  static func onOff(_ isOn: Bool) -> String { isOn ? "On" : "Off" }
}

enum TVAccountLayout {
  static let avatarSize = PutioTheme.TV.Spacing.xl
  static let storageWidth = PutioTheme.TV.Spacing.xxl
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

  // The kit's form-row title face, so every settings title reads alike.
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
    .clipShape(RoundedRectangle(cornerRadius: PutioTheme.TV.radius, style: .continuous))
    .accessibilityHidden(true)
  }

  private var initial: some View {
    ZStack {
      PutioTheme.Colors.surface
      Text(username.first.map { String($0).uppercased() } ?? "")
        .putioFont(PutioTheme.TV.Typography.heading)
        .foregroundStyle(PutioTheme.Colors.accent)
    }
  }
}

// MARK: - Proxy chooser

/// The full-screen chooser behind "Choose your proxy". It closes once put.io
/// confirms the selected route.
struct TVProxyChooserView: View {
  @Environment(\.dismiss) private var dismiss
  @State private var model: PutioProxyChooserModel

  init(runtime: PutioRuntime) {
    _model = State(
      initialValue: PutioProxyChooserModel(
        actions: PutioProxyChooserActions(runtime: runtime),
        preferences: PutioAccountPreferencesModel(actions: .init(runtime: runtime))))
  }

  var body: some View {
    TVProxyChooserScreen(
      selection: model.selection,
      choices: model.choices,
      isLoading: model.isBusy,
      failure: model.failure,
      canSelect: model.canSelect,
      select: { name in Task { await model.select(name) } },
      retry: { Task { await model.retry() } }
    )
    .task { await model.loadIfNeeded() }
    .onChange(of: model.isRequestConfirmed) { _, confirmed in
      if confirmed { dismiss() }
    }
  }
}

struct TVProxyChooserScreen: View {
  let selection: String
  let choices: PutioProxyChoices?
  var isLoading = false
  var failure: String?
  var canSelect = true
  var select: (String) -> Void = { _ in }
  var retry: () -> Void = {}

  @FocusState private var focusedRoute: String?

  var body: some View {
    VStack(alignment: .leading, spacing: PutioTheme.TV.Spacing.medium) {
      TVScreenHeader(title: "Choose your proxy") {
        if isLoading { ProgressView() }
      }
      if let choices {
        TVRowList {
          if let failure { failureSection(failure) }
          ForEach(choices.names, id: \.self) { name in
            Button {
              select(name)
            } label: {
              TVChoiceLabel(
                title: PutioProxyChoices.title(for: name), isSelected: name == selection
              )
              .tvRowPadding()
            }
            .disabled(!canSelect)
            .focused($focusedRoute, equals: name)
            .accessibilityIdentifier("proxy.route.\(name)")
            .accessibilityAddTraits(name == selection ? .isSelected : [])
          }
        }
        .defaultFocus($focusedRoute, selection)
      } else if let failure {
        PutioErrorStateView(
          title: "Could not load proxies", message: failure, retryTitle: "Try again",
          retryIdentifier: "proxy.retry", retry: retry
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
      } else {
        PutioLoadingStateView(title: "Loading proxies")
          .frame(maxWidth: .infinity, maxHeight: .infinity)
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    .tvOverscanPadding()
    .background(PutioTheme.Colors.background.ignoresSafeArea())
  }

  private func failureSection(_ failure: String) -> some View {
    VStack(alignment: .leading, spacing: PutioTheme.TV.Spacing.small) {
      Text(failure)
        .putioFont(PutioTheme.TV.Typography.body)
        .foregroundStyle(PutioTheme.TV.Colors.textSecondary)
        .accessibilityIdentifier("proxy.failure")
      PutioButton("Try again", tier: .secondary, action: retry)
        .disabled(isLoading)
        .accessibilityIdentifier("proxy.retry")
    }
    .padding(.horizontal, PutioTheme.TV.Spacing.medium)
  }
}

/// A chooser option: a check on the selected one, an empty slot otherwise.
struct TVChoiceLabel: View {
  let title: String
  let isSelected: Bool

  @Environment(\.putioTVRowState) private var rowState

  var body: some View {
    HStack(spacing: PutioTheme.TV.Spacing.small) {
      Image(putioIcon: .checkCircle)
        .resizable()
        .scaledToFit()
        .frame(width: TVRowLayout.iconSize, height: TVRowLayout.iconSize)
        .foregroundStyle(
          rowState == .focused ? PutioTVRowFocus.foreground : PutioTheme.Colors.accent
        )
        .opacity(isSelected ? 1 : 0)
        .accessibilityHidden(true)
      Text(title)
        .putioFont(PutioTheme.TV.Typography.body)
        .foregroundStyle(.putioRowPrimary)
    }
  }
}
