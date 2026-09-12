import PutioCore
import SwiftUI
import UIKit

/// Two-factor, signed-in apps, and device linking. The 2FA row reads the
/// account snapshot; flipping it opens the change sheet and the snapshot
/// only moves once put.io acknowledges the code. Every screen below owns its
/// model in `@State`: an account refresh re-renders the parent, and a model
/// built in the parent's body would reset mid-flow.
@MainActor
struct AccountSecurityView: View {
  let actions: PutioAccountSecurityActions
  @State private var pendingChange: PutioTwoFactorChangeModel?
  @State private var isRefreshing = false
  @State private var refreshWarning: String?

  init(runtime: PutioRuntime) {
    actions = PutioAccountSecurityActions(runtime: runtime)
  }

  var body: some View {
    let account = actions.account()
    let isStale = actions.isStale()
    let twoFactorEnabled = account?.twoFactorEnabled ?? false
    Form {
      if isStale || refreshWarning != nil {
        Section {
          Text(refreshWarning ?? PutioAccountSecurityPresentation.refreshWarning)
            .foregroundStyle(PutioTheme.Colors.textSecondary)
          Button(isRefreshing ? "Refreshing…" : "Refresh account") {
            Task { await refreshAccount() }
          }
          .disabled(isRefreshing)
          .accessibilityIdentifier("security.refresh")
        }
        .listRowBackground(PutioTheme.Colors.surface)
      }
      Section {
        Toggle(
          "Two-factor authentication",
          isOn: Binding(
            get: { twoFactorEnabled },
            set: { enable in
              guard enable != twoFactorEnabled, pendingChange == nil else { return }
              pendingChange = PutioTwoFactorChangeModel(enabling: enable, actions: actions)
            })
        )
        .disabled(account == nil || isStale || isRefreshing)
        .accessibilityIdentifier("security.two-factor")
        if twoFactorEnabled {
          NavigationLink("Recovery codes") {
            RecoveryCodesView(actions: actions)
          }
          .accessibilityIdentifier("security.recovery-codes")
        }
      } header: {
        Text("Sign-in")
      } footer: {
        Text(
          twoFactorEnabled
            ? "Signing in asks for a code from your authenticator app. Recovery codes get you in without it."
            : "Protect your account with a code from an authenticator app at sign-in.")
      }
      .listRowBackground(PutioTheme.Colors.surface)
      Section("Devices") {
        NavigationLink("Where you're signed in") {
          AuthorizedAppsView(actions: actions)
        }
        .accessibilityIdentifier("security.apps")
        NavigationLink("Link a device") {
          LinkDeviceView(actions: actions)
        }
        .accessibilityIdentifier("security.link-device")
      }
      .listRowBackground(PutioTheme.Colors.surface)
    }
    .navigationTitle("Security")
    .putioFont(PutioTheme.Typography.body)
    .putioContentBackground()
    .sheet(item: $pendingChange) { change in
      TwoFactorChangeSheet(model: change) { accountRefreshed in
        pendingChange = nil
        refreshWarning = accountRefreshed ? nil : PutioAccountSecurityPresentation.refreshWarning
      }
    }
  }

  private func refreshAccount() async {
    guard !isRefreshing else { return }
    isRefreshing = true
    defer { isRefreshing = false }
    if await actions.refreshAccount() { refreshWarning = nil }
  }
}

extension PutioTwoFactorChangeModel: Identifiable {
  var id: ObjectIdentifier { ObjectIdentifier(self) }
}

/// Enrollment walks secret → code → recovery codes; disabling is code only.
/// Dismissal is blocked while a code is in flight so the outcome is seen.
private struct TwoFactorChangeSheet: View {
  let model: PutioTwoFactorChangeModel
  let onFinish: (Bool) -> Void
  @Environment(\.dismiss) private var dismiss

  var body: some View {
    NavigationStack {
      Form {
        switch model.step {
        case .loadingSecret:
          if let failure = model.secretFailure {
            Section {
              Text(failure).foregroundStyle(PutioTheme.Colors.textSecondary)
              Button("Try again") { Task { await model.loadSecret() } }
                .accessibilityIdentifier("security.two-factor-retry-secret")
            }
            .listRowBackground(PutioTheme.Colors.surface)
          } else {
            ProgressView("Preparing your secret")
              .listRowBackground(PutioTheme.Colors.surface)
          }
        case .secret(let secret):
          Section {
            Text(Self.grouped(secret))
              .font(.system(.body, design: .monospaced))
              .textSelection(.enabled)
              .accessibilityLabel("Secret")
              .accessibilityValue(secret)
              .accessibilityIdentifier("security.two-factor-secret")
            Button("Copy secret") { UIPasteboard.general.string = secret }
              .accessibilityIdentifier("security.two-factor-copy")
            Button("Next") { model.continueToCode() }
              .accessibilityIdentifier("security.two-factor-next")
          } header: {
            Text("Step 1 of 3")
          } footer: {
            Text("Add this secret to your authenticator app, then enter the code it shows.")
          }
          .listRowBackground(PutioTheme.Colors.surface)
        case .code:
          codeSection
        case .recoveryCodes(let codes):
          Section {
            ForEach(Array(codes.enumerated()), id: \.offset) { index, code in
              RecoveryCodeRow(code: code)
                .accessibilityIdentifier("security.recovery-code.\(index)")
            }
            Button("Copy all") {
              UIPasteboard.general.string = codes.filter { !$0.isUsed }.map(\.code)
                .joined(separator: "\n")
            }
            .accessibilityIdentifier("security.two-factor-copy-codes")
            Button("I have saved my recovery codes") { model.finish() }
              .accessibilityIdentifier("security.two-factor-done")
          } header: {
            Text("Step 3 of 3")
          } footer: {
            Text(
              "Two-factor authentication is on. Keep these codes somewhere safe; each one signs you in once if you lose your authenticator."
            )
          }
          .listRowBackground(PutioTheme.Colors.surface)
        case .finished:
          EmptyView()
        }
      }
      .navigationTitle(model.enabling ? "Enable two-factor" : "Disable two-factor")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          if model.recoveryCodesFailure != nil {
            // Enrollment already committed; this is a deliberate exit, not a
            // cancellation, and the codes stay reachable from Security.
            Button("Close") { model.finishWithoutRecoveryCodes() }
              .disabled(model.isLoadingRecoveryCodes)
              .accessibilityIdentifier("security.two-factor-close")
          } else if !showsRecoveryCodes {
            Button("Cancel") { dismiss() }
              .disabled(model.isSubmitting || model.isLoadingRecoveryCodes)
              .accessibilityIdentifier("security.two-factor-cancel")
          }
        }
      }
      .putioFont(PutioTheme.Typography.body)
      .putioContentBackground()
    }
    // The codes are shown once; leaving is only through the acknowledgement.
    .interactiveDismissDisabled(
      model.isSubmitting || model.isLoadingRecoveryCodes || showsRecoveryCodes
        || model.recoveryCodesFailure != nil
    )
    .task { await model.loadSecret() }
    .onChange(of: model.step) { _, step in
      if case .finished(let accountRefreshed) = step { onFinish(accountRefreshed) }
    }
  }

  private var showsRecoveryCodes: Bool {
    if case .recoveryCodes = model.step { return true }
    return false
  }

  @ViewBuilder
  private var codeSection: some View {
    Section {
      TextField("Authenticator code", text: Bindable(model).code)
        .keyboardType(.numberPad)
        .textContentType(.oneTimeCode)
        .font(.system(.body, design: .monospaced))
        .disabled(model.isSubmitting)
        .accessibilityIdentifier("security.two-factor-code")
      if let failure = model.codeFailure {
        Text(failure)
          .foregroundStyle(PutioTheme.Colors.destructive)
          .accessibilityIdentifier("security.two-factor-failure")
      }
      if let failure = model.recoveryCodesFailure {
        Text(
          "Two-factor authentication is on. \(failure) They also stay available under Security."
        )
        .foregroundStyle(PutioTheme.Colors.textSecondary)
        Button("Load recovery codes") { Task { await model.retryRecoveryCodes() } }
          .disabled(model.isLoadingRecoveryCodes)
          .accessibilityIdentifier("security.two-factor-retry-codes")
      } else {
        Button {
          Task { await model.submit() }
        } label: {
          if model.isSubmitting || model.isLoadingRecoveryCodes {
            ProgressView()
          } else {
            Text(model.enabling ? "Enable" : "Disable")
          }
        }
        .disabled(!model.canSubmit)
        .accessibilityIdentifier("security.two-factor-submit")
      }
    } header: {
      Text(model.enabling ? "Step 2 of 3" : "Confirm")
    } footer: {
      Text(
        model.enabling
          ? "Enter the six-digit code your authenticator app shows for put.io."
          : "Enter the current code from your authenticator app to turn two-factor authentication off."
      )
    }
    .listRowBackground(PutioTheme.Colors.surface)
  }

  private static func grouped(_ secret: String) -> String {
    stride(from: 0, to: secret.count, by: 4).map { start in
      let lower = secret.index(secret.startIndex, offsetBy: start)
      let upper = secret.index(lower, offsetBy: 4, limitedBy: secret.endIndex) ?? secret.endIndex
      return String(secret[lower..<upper])
    }.joined(separator: " ")
  }
}

private struct RecoveryCodeRow: View {
  let code: PutioTwoFactorRecoveryCode

  var body: some View {
    HStack {
      Text(code.code)
        .font(.system(.body, design: .monospaced))
        .strikethrough(code.isUsed)
        .foregroundStyle(
          code.isUsed ? PutioTheme.Colors.textSecondary : PutioTheme.Colors.textPrimary)
      if code.isUsed {
        Spacer()
        Text("Used")
          .putioFont(PutioTheme.Typography.caption)
          .foregroundStyle(PutioTheme.Colors.textSecondary)
      }
    }
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(code.isUsed ? "Used recovery code" : "Recovery code")
    .accessibilityValue(code.code)
  }
}

struct RecoveryCodesView: View {
  @State private var model: PutioRecoveryCodesModel
  @State private var confirmsRegenerate = false

  init(actions: PutioAccountSecurityActions) {
    _model = State(initialValue: PutioRecoveryCodesModel(actions: actions))
  }

  var body: some View {
    Form {
      if let codes = model.codes {
        Section {
          ForEach(Array(codes.enumerated()), id: \.offset) { index, code in
            RecoveryCodeRow(code: code)
              .accessibilityIdentifier("security.recovery-code.\(index)")
          }
        } footer: {
          Text("Each unused code signs you in once if you lose your authenticator app.")
        }
        .listRowBackground(PutioTheme.Colors.surface)
        Section {
          Button("Copy all") { UIPasteboard.general.string = model.copyableText }
            .disabled(model.copyableText.isEmpty)
            .accessibilityIdentifier("security.recovery-copy")
          Button("Regenerate codes", role: .destructive) { confirmsRegenerate = true }
            .disabled(model.isBusy)
            .accessibilityIdentifier("security.recovery-regenerate")
          if let failure = model.failure {
            Text(failure).foregroundStyle(PutioTheme.Colors.textSecondary)
            if model.canRetryRegenerate {
              Button("Try again") { Task { await model.regenerate() } }
                .disabled(model.isBusy)
                .accessibilityIdentifier("security.recovery-retry")
            }
          }
          if model.isRegenerating {
            ProgressView("Regenerating codes")
          }
        } footer: {
          Text("Regenerating replaces every code above, including unused ones.")
        }
        .listRowBackground(PutioTheme.Colors.surface)
      } else if let failure = model.failure {
        Section {
          Text(failure).foregroundStyle(PutioTheme.Colors.textSecondary)
          Button("Try again") { Task { await model.retryLoad() } }
            .accessibilityIdentifier("security.recovery-retry")
        }
        .listRowBackground(PutioTheme.Colors.surface)
      } else {
        ProgressView("Loading recovery codes")
          .listRowBackground(PutioTheme.Colors.surface)
      }
    }
    .navigationTitle("Recovery codes")
    .putioFont(PutioTheme.Typography.body)
    .putioContentBackground()
    .task { await model.load() }
    .confirmationDialog(
      "Regenerate recovery codes?", isPresented: $confirmsRegenerate, titleVisibility: .visible
    ) {
      Button("Regenerate", role: .destructive) { Task { await model.regenerate() } }
        .accessibilityIdentifier("security.recovery-regenerate-confirm")
      Button("Cancel", role: .cancel) {}
    } message: {
      Text("Your current codes stop working.")
    }
  }
}

struct AuthorizedAppsView: View {
  @State private var model: PutioAuthorizedAppsModel

  init(actions: PutioAccountSecurityActions) {
    _model = State(initialValue: PutioAuthorizedAppsModel(actions: actions))
  }

  var body: some View {
    Group {
      switch model.state {
      case .loading:
        PutioLoadingStateView(title: "Loading apps")
      case .failed(let message):
        PutioErrorStateView(
          title: "Could not load apps", message: message, retryTitle: "Try again",
          retryIdentifier: "security.apps.retry-load"
        ) {
          Task { await model.load() }
        }
      case .loaded(let apps):
        List {
          if let failure = model.refreshFailure {
            Section {
              Text(failure).foregroundStyle(PutioTheme.Colors.textSecondary)
              Button("Try again") { Task { await model.load() } }
                .disabled(model.revokingID != nil)
                .accessibilityIdentifier("security.apps.retry-load")
            }
            .listRowBackground(PutioTheme.Colors.surface)
          }
          if let failure = model.revokeFailure {
            Section {
              Text(failure).foregroundStyle(PutioTheme.Colors.textSecondary)
              Button("Try again") { Task { await model.retryRevoke() } }
                .disabled(model.revokingID != nil)
                .accessibilityIdentifier("security.apps.retry")
            }
            .listRowBackground(PutioTheme.Colors.surface)
          }
          Section {
            ForEach(apps) { app in
              AuthorizedAppRow(app: app, isRevoking: model.revokingID == app.id)
                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                  if !app.isCurrentClient {
                    Button("Revoke", role: .destructive) { Task { await model.revoke(id: app.id) } }
                      .disabled(model.revokingID != nil)
                      .accessibilityIdentifier("security.app.revoke.\(app.id)")
                  }
                }
                .accessibilityIdentifier("security.app.\(app.id)")
            }
          } footer: {
            Text("Swipe an app to revoke its access. This app keeps its own sign-in.")
          }
          .listRowBackground(PutioTheme.Colors.surface)
        }
        .refreshable { await model.load() }
      }
    }
    .navigationTitle("Where you're signed in")
    .putioFont(PutioTheme.Typography.body)
    .putioContentBackground()
    .task { await model.load() }
  }
}

private struct AuthorizedAppRow: View {
  let app: PutioAuthorizedApp
  let isRevoking: Bool

  var body: some View {
    HStack {
      VStack(alignment: .leading, spacing: PutioTheme.Spacing.space1) {
        Text(app.name).foregroundStyle(PutioTheme.Colors.textPrimary)
        if !app.description.isEmpty {
          Text(app.description)
            .putioFont(PutioTheme.Typography.caption)
            .foregroundStyle(PutioTheme.Colors.textSecondary)
        }
      }
      Spacer()
      if isRevoking {
        ProgressView()
      } else if app.isCurrentClient {
        Text("This app")
          .putioFont(PutioTheme.Typography.caption)
          .foregroundStyle(PutioTheme.Colors.textSecondary)
      }
    }
    .accessibilityElement(children: .combine)
    .accessibilityValue(app.isCurrentClient ? "This app" : (isRevoking ? "Revoking" : ""))
  }
}

struct LinkDeviceView: View {
  @State private var model: PutioLinkDeviceModel
  @Environment(\.dismiss) private var dismiss

  init(actions: PutioAccountSecurityActions) {
    _model = State(initialValue: PutioLinkDeviceModel(actions: actions))
  }

  var body: some View {
    Form {
      Section {
        TextField("Device code", text: Bindable(model).code)
          .textInputAutocapitalization(.characters)
          .autocorrectionDisabled()
          .font(.system(.body, design: .monospaced))
          .disabled(model.isLinking)
          .accessibilityIdentifier("security.link-code")
        if let failure = model.failure {
          Text(failure)
            .foregroundStyle(PutioTheme.Colors.destructive)
            .accessibilityIdentifier("security.link-failure")
        }
        Button {
          Task { await model.link() }
        } label: {
          if model.isLinking { ProgressView() } else { Text("Link device") }
        }
        .disabled(!model.canLink)
        .accessibilityIdentifier("security.link-submit")
      } footer: {
        Text("Enter the code shown on a TV or another put.io app to sign it in with your account.")
      }
      .listRowBackground(PutioTheme.Colors.surface)
    }
    .navigationTitle("Link a device")
    .putioFont(PutioTheme.Typography.body)
    .putioContentBackground()
    .alert(
      "Connected",
      isPresented: Binding(
        get: { model.linkedApp != nil },
        set: { presented in if !presented { model.acknowledgeLink() } }),
      presenting: model.linkedApp
    ) { _ in
      Button("OK") {
        model.acknowledgeLink()
        dismiss()
      }
      .accessibilityIdentifier("security.link-done")
    } message: { app in
      Text("\(app.name) is now signed in with your account.")
    }
  }
}

struct ClearDataView: View {
  @State private var model: PutioClearDataModel
  @State private var confirms = false

  init(
    actions: PutioAccountSecurityActions,
    onCleared: @escaping @MainActor (Set<PutioAccountDataCategory>, Bool) -> Void
  ) {
    _model = State(initialValue: PutioClearDataModel(actions: actions, onCleared: onCleared))
  }

  var body: some View {
    Form {
      Section {
        ForEach(PutioAccountDataCategory.allCases, id: \.self) { category in
          Toggle(
            category.title,
            isOn: Binding(
              get: { model.selection.contains(category) },
              set: { selected in
                if selected {
                  model.selection.insert(category)
                } else {
                  model.selection.remove(category)
                }
              })
          )
          .disabled(model.isClearing)
          .accessibilityIdentifier("danger.clear.\(category.rawValue)")
        }
      } header: {
        Text("What to clear")
      } footer: {
        Text("Cleared data cannot be recovered.")
      }
      .listRowBackground(PutioTheme.Colors.surface)
      Section {
        if let failure = model.failure {
          Text(failure)
            .foregroundStyle(PutioTheme.Colors.destructive)
            .accessibilityIdentifier("danger.clear-failure")
        }
        if let warning = model.refreshWarning {
          Text(warning).foregroundStyle(PutioTheme.Colors.textSecondary)
          Button("Refresh account") { Task { await model.refreshAccount() } }
            .disabled(model.isClearing)
            .accessibilityIdentifier("danger.clear-refresh")
        } else if model.didClear {
          Text("Done. The selected data has been cleared.")
            .foregroundStyle(PutioTheme.Colors.textSecondary)
            .accessibilityIdentifier("danger.clear-success")
        }
        Button(role: .destructive) {
          confirms = true
        } label: {
          if model.isClearing { ProgressView() } else { Text("Clear selected data") }
        }
        .disabled(!model.canClear)
        .accessibilityIdentifier("danger.clear")
      }
      .listRowBackground(PutioTheme.Colors.surface)
    }
    .navigationTitle("Clear Data")
    .putioFont(PutioTheme.Typography.body)
    .putioContentBackground()
    .confirmationDialog(
      "Clear the selected data?", isPresented: $confirms, titleVisibility: .visible
    ) {
      Button("Clear", role: .destructive) { Task { await model.clear() } }
        .accessibilityIdentifier("danger.clear-confirm")
      Button("Cancel", role: .cancel) {}
    } message: {
      Text("This removes the selected data from your account permanently.")
    }
  }
}

struct DestroyAccountView: View {
  @State private var model: PutioDestroyAccountModel
  @State private var asksPassword = false

  init(actions: PutioAccountSecurityActions, onDestroyed: @escaping @MainActor () -> Void) {
    _model = State(
      initialValue: PutioDestroyAccountModel(actions: actions, onDestroyed: onDestroyed))
  }

  var body: some View {
    Form {
      Section {
        Text(
          "Destroying your account deletes your files, transfers, and history and cancels your subscription. There is no way back."
        )
        .foregroundStyle(PutioTheme.Colors.textSecondary)
        if let failure = model.failure {
          Text(failure)
            .foregroundStyle(PutioTheme.Colors.destructive)
            .accessibilityIdentifier("danger.destroy-failure")
        }
        Button(role: .destructive) {
          asksPassword = true
        } label: {
          if model.isDestroying { ProgressView() } else { Text("Destroy account") }
        }
        .disabled(model.isDestroying)
        .accessibilityIdentifier("danger.destroy")
      }
      .listRowBackground(PutioTheme.Colors.surface)
    }
    .navigationTitle("Destroy Account")
    .putioFont(PutioTheme.Typography.body)
    .putioContentBackground()
    .alert("One last step", isPresented: $asksPassword) {
      SecureField("Password", text: Bindable(model).password)
        .accessibilityIdentifier("danger.destroy-password")
      Button("Destroy Account", role: .destructive) { Task { await model.destroy() } }
        .disabled(!model.canDestroy)
        .accessibilityIdentifier("danger.destroy-confirm")
      Button("Cancel", role: .cancel) { model.password = "" }
    } message: {
      Text("Enter your password to confirm.")
    }
  }
}

struct AboutView: View {
  private static let version: String = {
    let short = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
    let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String
    switch (short, build) {
    case (let short?, let build?): return "\(short) (\(build))"
    case (let short?, nil): return short
    case (nil, let build?): return build
    case (nil, nil): return "Unknown"
    }
  }()

  var body: some View {
    Form {
      Section {
        LabeledContent("Version", value: Self.version)
          .accessibilityIdentifier("about.version")
      }
      .listRowBackground(PutioTheme.Colors.surface)
      Section("put.io") {
        link("About put.io", "https://put.io/about/")
        link("Terms of service", "https://put.io/terms-of-service/")
        link("Privacy policy", "https://put.io/privacy-policy/")
      }
      .listRowBackground(PutioTheme.Colors.surface)
      Section {
        link("putio-sdk-swift", "https://github.com/putdotio/putio-sdk-swift")
        link("Google Cast SDK", "https://developers.google.com/cast/docs/ios_sender")
      } header: {
        Text("Acknowledgements")
      } footer: {
        Text("Libraries this app is built on.")
      }
      .listRowBackground(PutioTheme.Colors.surface)
    }
    .navigationTitle("About")
    .putioFont(PutioTheme.Typography.body)
    .putioContentBackground()
  }

  @ViewBuilder
  private func link(_ title: String, _ url: String) -> some View {
    if let destination = URL(string: url) {
      Link(title, destination: destination)
    }
  }
}
