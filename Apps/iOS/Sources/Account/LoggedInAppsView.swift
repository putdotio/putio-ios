import PutioCore
import SwiftUI
import UIKit

struct LoggedInAppsView: View {
  @State private var model: PutioAuthorizedAppsModel
  @State private var confirmAlert: PutioConfirmAlert?

  init(actions: PutioAccountSecurityActions) {
    _model = State(initialValue: PutioAuthorizedAppsModel(actions: actions))
  }

  var body: some View {
    List {
      Group {
        switch model.state {
        case .loading:
          Section {
            PutioSettingsLoadingRow(String(localized: "Loading logged-in apps…"))
              .accessibilityIdentifier("security.apps.loading")
          }
        case .failed:
          Section {
            PutioSettingsFailedRows(
              String(localized: "Couldn’t load logged-in apps"),
              identifier: "security.apps.failed",
              retryIdentifier: "security.apps.retry-load"
            ) {
              Task { await model.load() }
            }
          }
        case .loaded(let apps):
          loadedSections(apps)
        }
      }
      .listRowBackground(PutioTheme.Colors.surface)
    }
    .refreshable { if !model.isBusy { await model.load() } }
    .navigationTitle(String(localized: "Logged-in apps"))
    .navigationBarTitleDisplayMode(.inline)
    .putioFont(PutioTheme.Typography.body)
    .putioContentBackground()
    .putioConfirmAlert($confirmAlert)
    .task { await model.load() }
  }

  @ViewBuilder private func loadedSections(_ apps: [PutioAuthorizedApp]) -> some View {
    if let failure = model.refreshFailure {
      Section {
        Text(failure).foregroundStyle(PutioTheme.Colors.textSecondary)
        Button(String(localized: "Try again")) { Task { await model.load() } }
          .disabled(model.isBusy)
          .accessibilityIdentifier("security.apps.retry-load")
      }
    }
    PutioSettingsSection(
      footer: String(
        localized: "Swipe an app to revoke its access. This app keeps its own sign-in.")
    ) {
      ForEach(apps) { app in
        LoggedInAppRow(
          app: app,
          failure: model.revokeFailures[app.id],
          isRevoking: model.revokingID == app.id,
          icon: { await model.icon(for: app) },
          retry: retryAction(for: app)
        )
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
          if !app.isCurrentClient {
            Button(String(localized: "Revoke"), role: .destructive) {
              Task { await model.revoke(id: app.id) }
            }
            .disabled(model.isBusy)
            .accessibilityIdentifier("security.app.revoke.\(app.id)")
          }
        }
        .accessibilityIdentifier("security.app.\(app.id)")
      }
    }
    if model.canSignOutOthers {
      Section {
        PutioDestructiveRow(String(localized: "Sign out of all other apps"), alignment: .center) {
          askToSignOutOthers()
        }
        .disabled(model.isBusy)
        .overlay(alignment: .trailing) {
          if model.isSigningOutOthers {
            ProgressView()
              .tint(PutioTheme.Colors.textSecondary)
          }
        }
        .accessibilityIdentifier("security.apps.sign-out-others")
      }
    }
  }

  private func retryAction(for app: PutioAuthorizedApp) -> (() -> Void)? {
    guard model.revokeFailures[app.id] != nil, !model.isBusy else { return nil }
    return { Task { await model.revoke(id: app.id) } }
  }

  private func askToSignOutOthers() {
    let model = model
    confirmAlert = PutioConfirmAlert(
      title: String(localized: "Sign out of all other apps?"),
      message: LoggedInAppsView.signOutOthersMessage,
      confirmTitle: String(localized: "Sign out")
    ) {
      Task { await model.signOutOthers() }
    }
  }

  static var thisDevice: String {
    UIDevice.current.userInterfaceIdiom == .pad
      ? String(localized: "This iPad") : String(localized: "This iPhone")
  }

  static var signOutOthersMessage: String {
    UIDevice.current.userInterfaceIdiom == .pad
      ? String(
        localized: "This iPad stays signed in. Every other app and device has to sign in again.")
      : String(
        localized: "This iPhone stays signed in. Every other app and device has to sign in again.")
  }
}

private struct LoggedInAppRow: View {
  let app: PutioAuthorizedApp
  let failure: String?
  let isRevoking: Bool
  let icon: @MainActor @Sendable () async -> Data?
  let retry: (() -> Void)?

  var body: some View {
    HStack(spacing: PutioTheme.Spacing.space3) {
      LoggedInAppIcon(app: app, load: icon)
      VStack(alignment: .leading, spacing: PutioTheme.Spacing.space1) {
        Text(app.name)
          .foregroundStyle(PutioTheme.Colors.textPrimary)
        if let detail {
          Text(detail)
            .putioFont(PutioTheme.Typography.caption)
            .foregroundStyle(
              failure == nil ? PutioTheme.Colors.textSecondary : PutioTheme.Colors.destructive)
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .alignmentGuide(.listRowSeparatorLeading) { $0[.leading] }
      if isRevoking {
        ProgressView()
          .tint(PutioTheme.Colors.textSecondary)
      } else if let retry {
        Button(action: retry) {
          PutioIconView(.arrowCounterClockwise, size: Self.retrySize)
            .foregroundStyle(PutioTheme.Colors.textSecondary)
        }
        .buttonStyle(.borderless)
      }
    }
    .accessibilityElement(children: .combine)
    .accessibilityValue(accessibilityValue)
    .accessibilityActions {
      if let retry {
        Button(String(localized: "Try again"), action: retry)
      }
    }
  }

  private static let retrySize = PutioMetricRole(
    value: PutioTheme.Typography.sizeMd, relativeTo: .body)

  private var detail: String? {
    if let failure { return failure }
    if app.isCurrentClient { return LoggedInAppsView.thisDevice }
    guard let lastUsedAt = app.lastUsedAt else { return nil }
    let date = lastUsedAt.formatted(.dateTime.month(.abbreviated).day().year())
    return String(localized: "Used on \(date)")
  }

  private var accessibilityValue: String {
    if app.isCurrentClient { return LoggedInAppsView.thisDevice }
    if isRevoking { return String(localized: "Revoking") }
    return ""
  }
}

private struct LoggedInAppIcon: View {
  let app: PutioAuthorizedApp
  let load: @MainActor @Sendable () async -> Data?
  @State private var image: UIImage?
  @PutioScaledMetric private var size: CGFloat

  init(app: PutioAuthorizedApp, load: @escaping @MainActor @Sendable () async -> Data?) {
    self.app = app
    self.load = load
    _size = PutioScaledMetric(
      PutioMetricRole(
        value: PutioTheme.Spacing.space4 + PutioTheme.Spacing.space1, relativeTo: .body))
  }

  private static let glyphSize = PutioMetricRole(
    value: PutioTheme.Typography.sizeMd, relativeTo: .body)

  var body: some View {
    ZStack {
      if let image {
        Image(uiImage: image)
          .resizable()
          .scaledToFill()
      } else {
        PutioTheme.Colors.surfaceActive
        PutioIconView(.appWindow, size: Self.glyphSize)
          .foregroundStyle(PutioTheme.Colors.textSecondary)
      }
    }
    .frame(width: size, height: size)
    .clipShape(RoundedRectangle(cornerRadius: PutioTheme.Radius.medium, style: .continuous))
    .accessibilityHidden(true)
    .task(id: app.id) {
      image = await load().flatMap(UIImage.init(data:))
    }
  }
}
