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
      [.app, .device, .system]
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
  case app
  case device
  case system

  var id: Self { self }

  var title: String {
    switch self {
    case .proxy: "Choose your proxy"
    case .rememberPosition: "Remember current place in video files"
    case .showSubtitles: "Show subtitles"
    case .subtitleSelection: "Do not select subtitles by default"
    case .trash: "Move deleted files to trash"
    case .manageTrash: "Manage your trash"
    case .app: "App"
    case .device: "Device"
    case .system: "Operating system"
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
    case .app: "account.app"
    case .device: "account.device"
    case .system: "account.system"
    }
  }

  /// The value a two-state row shows; `nil` for every other row.
  func isOn(in account: PutioAccountSnapshot) -> Bool? {
    switch self {
    case .rememberPosition: account.rememberVideoTime
    case .showSubtitles: !account.hideSubtitles
    case .subtitleSelection: account.dontAutoSelectSubtitles
    case .trash: account.trashEnabled
    case .proxy, .manageTrash, .app, .device, .system: nil
    }
  }

  /// What choosing `isOn` asks for, or `nil` when the app cannot change the
  /// row. putio-sdk-swift's settings patch (through 4.0.0) cannot write
  /// `use_start_from`, so remember-position is shown but not editable.
  func change(to isOn: Bool) -> TVAccountChange? {
    switch self {
    case .showSubtitles: .save(.showSubtitles(isOn))
    case .subtitleSelection: .save(.dontAutoSelectSubtitles(isOn))
    case .trash: isOn ? .save(.trash(true)) : .confirmDisablingTrash
    case .rememberPosition, .proxy, .manageTrash, .app, .device, .system: nil
    }
  }
}

struct TVAppInfo: Equatable {
  let app: String
  let device: String
  let system: String

  @MainActor static var current: TVAppInfo {
    let bundle = Bundle.main
    let identifier = bundle.bundleIdentifier ?? "io.put.tvos"
    let version = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
    let build = bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String
    let device = UIDevice.current
    return TVAppInfo(
      app: "\(identifier)@\(version ?? "0")+\(build ?? "0")",
      device: "\(device.name) - \(device.model)",
      system: "\(device.systemName) \(device.systemVersion)"
    )
  }
}

/// The preferences model's state as the screen shows it.
struct TVAccountStatus: Equatable {
  var failure: String?
  var canRetrySave = false
  var isStale = false
  var isSaving = false
  var isRefreshing = false
  var canSave = true

  static let idle = TVAccountStatus()

  @MainActor init(model: PutioAccountPreferencesModel) {
    failure = model.failure
    canRetrySave = model.failedMutation != nil
    isStale = model.isStale
    isSaving = model.isSaving
    isRefreshing = model.isRefreshing
    canSave = model.canSave
  }

  init(
    failure: String? = nil, canRetrySave: Bool = false, isStale: Bool = false,
    isSaving: Bool = false, isRefreshing: Bool = false, canSave: Bool = true
  ) {
    self.failure = failure
    self.canRetrySave = canRetrySave
    self.isStale = isStale
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
          retry: {
            Task {
              if model.isStale || model.failedMutation == nil {
                await model.retryRefresh()
              } else {
                await model.retrySave()
              }
            }
          },
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
  var appInfo = TVAppInfo.current
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
      "Log out of put.io?", isPresented: $confirmsSignOut, titleVisibility: .visible
    ) {
      Button("Log out", role: .destructive) {
        Task { await signOut() }
      }
      .accessibilityIdentifier("auth.sign-out-confirm")
      Button("Cancel", role: .cancel) {}
    } message: {
      Text("This Apple TV will need a new activation code to sign in again.")
    }
    .alert("Turn off Trash?", isPresented: $confirmsDisablingTrash) {
      Button("Turn off Trash", role: .destructive) { save(.trash(false)) }
        .accessibilityIdentifier("account.trash-disable-confirm")
      Button("Cancel", role: .cancel) {}
    } message: {
      Text("Every item in Trash will be permanently deleted. Future deletions cannot be restored.")
    }
  }

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
    if status.isStale || status.failure != nil || status.isSaving {
      VStack(alignment: .leading, spacing: PutioTheme.TV.Spacing.small) {
        if let message = statusMessage {
          Text(message)
            .putioFont(PutioTheme.TV.Typography.body)
            .foregroundStyle(PutioTheme.TV.Colors.textSecondary)
            .accessibilityIdentifier("account.settings-failure")
        }
        if status.isStale || status.failure != nil {
          PutioButton(retryTitle, tier: .secondary, action: retry)
            .disabled(status.isSaving || status.isRefreshing)
            .accessibilityIdentifier("account.settings-retry")
        }
        if status.isSaving {
          ProgressView("Saving settings")
            .accessibilityIdentifier("account.saving")
        }
      }
      .padding(.horizontal, PutioTheme.TV.Spacing.medium)
    }
  }

  private var statusMessage: String? {
    if status.isStale {
      return status.failure ?? "Account settings could not be confirmed. Refresh to continue."
    }
    return status.failure
  }

  private var retryTitle: String {
    if status.isRefreshing { return "Refreshing…" }
    return status.isStale || !status.canRetrySave ? "Refresh account" : "Try again"
  }

  @ViewBuilder
  private func rowView(_ row: TVAccountRow) -> some View {
    switch row {
    case .proxy:
      NavigationLink(value: TVRoute.proxy) {
        TVValueRow(title: row.title, value: account.routeName, opens: true)
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
    case .app:
      TVValueRow(title: row.title, value: appInfo.app)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier(row.identifier)
    case .device:
      TVValueRow(title: row.title, value: appInfo.device)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier(row.identifier)
    case .system:
      TVValueRow(title: row.title, value: appInfo.system)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier(row.identifier)
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
          .foregroundStyle(PutioTheme.TV.Colors.textPrimary)
        if let caption {
          Text(caption)
            .putioFont(PutioTheme.TV.Typography.caption)
            .foregroundStyle(PutioTheme.TV.Colors.textSecondary)
        }
      }
      Spacer(minLength: PutioTheme.TV.Spacing.small)
      Text(value)
        .putioFont(PutioTheme.TV.Typography.body)
        .foregroundStyle(PutioTheme.TV.Colors.textSecondary)
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
/// acknowledges the selected route.
struct TVProxyChooserView: View {
  let runtime: PutioRuntime

  @Environment(\.dismiss) private var dismiss
  @State private var model: PutioAccountPreferencesModel
  @State private var routes: [PutioPlaybackRoute]?
  @State private var routeFailure: String?
  @State private var isLoadingRoutes = false
  @State private var routeGeneration = 0
  @State private var requestedRoute: String?

  init(runtime: PutioRuntime) {
    self.runtime = runtime
    _model = State(initialValue: PutioAccountPreferencesModel(actions: .init(runtime: runtime)))
  }

  var body: some View {
    TVProxyChooserScreen(
      currentRoute: model.account?.routeName ?? "",
      routes: routes,
      isLoading: isLoadingRoutes || model.isBusy,
      failure: routeFailure ?? model.failure,
      canSelect: model.canSave && !isLoadingRoutes,
      select: { name in
        requestedRoute = name
        Task { await model.save(.route(name)) }
      },
      retry: { Task { await retry() } }
    )
    .task { if routes == nil { await loadRoutes() } }
    .onChange(of: isAcknowledged) { _, acknowledged in
      if acknowledged { dismiss() }
    }
  }

  /// The requested route is the account's confirmed value.
  private var isAcknowledged: Bool {
    guard let requestedRoute else { return false }
    return model.account?.routeName == requestedRoute && !model.isStale && !model.isBusy
  }

  private func retry() async {
    if routeFailure != nil {
      await loadRoutes()
    } else if model.isStale || model.failedMutation == nil {
      await model.retryRefresh()
    } else {
      await model.retrySave()
    }
  }

  private func loadRoutes() async {
    routeGeneration += 1
    let generation = routeGeneration
    isLoadingRoutes = true
    routeFailure = nil
    defer { if generation == routeGeneration { isLoadingRoutes = false } }
    do {
      let loaded = try await runtime.listPlaybackRoutes()
      try Task.checkCancellation()
      guard generation == routeGeneration else { return }
      routes = loaded
    } catch {
      guard generation == routeGeneration, !Task.isCancelled,
        let failure = PutioBrowserErrorPresentation(error: error)
      else { return }
      routeFailure = failure.message
    }
  }
}

struct TVProxyChooserScreen: View {
  let currentRoute: String
  let routes: [PutioPlaybackRoute]?
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
      if let routes {
        TVRowList {
          if let failure { failureSection(failure) }
          ForEach(options(routes)) { route in
            Button {
              guard route.name != currentRoute else { return }
              select(route.name)
            } label: {
              TVChoiceLabel(
                title: route.description.isEmpty ? route.name : route.description,
                isSelected: route.name == currentRoute
              )
              .tvRowPadding()
            }
            .disabled(!canSelect)
            .focused($focusedRoute, equals: route.name)
            .accessibilityIdentifier("proxy.route.\(route.name)")
            .accessibilityAddTraits(route.name == currentRoute ? .isSelected : [])
          }
        }
        .defaultFocus($focusedRoute, currentRoute)
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

  /// The current route stays choosable even when put.io no longer lists it.
  private func options(_ routes: [PutioPlaybackRoute]) -> [PutioPlaybackRoute] {
    guard !currentRoute.isEmpty, !routes.contains(where: { $0.name == currentRoute }) else {
      return routes
    }
    return [PutioPlaybackRoute(name: currentRoute, description: "")] + routes
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

  var body: some View {
    HStack(spacing: PutioTheme.TV.Spacing.small) {
      Image(putioIcon: .checkCircle)
        .resizable()
        .scaledToFit()
        .frame(width: TVRowLayout.iconSize, height: TVRowLayout.iconSize)
        .foregroundStyle(PutioTheme.Colors.accent)
        .opacity(isSelected ? 1 : 0)
        .accessibilityHidden(true)
      Text(title)
        .putioFont(PutioTheme.TV.Typography.body)
        .foregroundStyle(PutioTheme.TV.Colors.textPrimary)
    }
  }
}
