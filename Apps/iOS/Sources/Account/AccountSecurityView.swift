import PutioCore
import SwiftUI
import UIKit

struct LinkDeviceView: View {
  @State private var model: PutioLinkDeviceModel
  @FocusState private var focused: Bool
  @Environment(\.isPresented) private var isPresented
  @PutioScaledMetric private var fieldHeight: CGFloat

  init(actions: PutioAccountSecurityActions, code: String? = nil) {
    _model = State(initialValue: PutioLinkDeviceModel(actions: actions, code: code))
    _fieldHeight = PutioScaledMetric(PutioLinkDeviceLayout.fieldHeight)
  }

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: PutioTheme.Spacing.space3) {
        VStack(alignment: .leading, spacing: PutioTheme.Spacing.space2) {
          codeField
          note
        }
        PutioBlockButton(
          String(localized: "Link"), isBusy: model.isLinking, isEnabled: model.canLink,
          action: link
        )
        .accessibilityIdentifier("security.link-submit")
      }
      .padding(PutioTheme.Spacing.space3)
    }
    .scrollDismissesKeyboard(.immediately)
    .navigationTitle(String(localized: "Link a device"))
    .navigationBarTitleDisplayMode(.inline)
    .putioContentBackground()
    .onDisappear { if !isPresented { model.cancel() } }
    .putioAlert(
      String(localized: "Connected"),
      isPresented: Binding(
        get: { model.linkedApp != nil },
        set: { presented in if !presented { model.acknowledgeLink() } }),
      message: model.linkedApp.map { app in
        String(localized: "\(app.name) is now signed in with your account.")
      },
      actions: [PutioAlertAction(String(localized: "OK"), tier: .neutral, id: "security.link-done")]
    )
  }

  private var codeField: some View {
    TextField("", text: Bindable(model).code)
      .textInputAutocapitalization(.characters)
      .autocorrectionDisabled()
      .keyboardType(.asciiCapable)
      .submitLabel(.go)
      .onSubmit(link)
      .onChange(of: model.code) { model.codeEdited() }
      .putioFont(PutioLinkDeviceLayout.codeFont)
      .kerning(PutioLinkDeviceLayout.codeTracking)
      .foregroundStyle(PutioTheme.Components.Field.text)
      .tint(PutioTheme.Colors.accent)
      .focused($focused)
      .disabled(model.isLinking)
      .padding(.horizontal, PutioTheme.Spacing.space3)
      .frame(minHeight: fieldHeight)
      .background {
        Capsule()
          .fill(PutioTheme.Colors.surface)
          .onTapGesture { focused = true }
      }
      .accessibilityLabel(String(localized: "Link a device"))
      .accessibilityHint(LinkDeviceView.noteText)
      .accessibilityIdentifier("security.link-code")
  }

  private static var noteText: String {
    String(localized: "Enter the code shown on your device to link it to your put.io account.")
  }

  private func link() {
    guard model.canLink else { return }
    focused = false
    Task { await model.link() }
  }

  @ViewBuilder private var note: some View {
    Group {
      if let failure = model.failure {
        Text(failure)
          .foregroundStyle(PutioTheme.Colors.destructive)
          .accessibilityIdentifier("security.link-failure")
      } else {
        Text(Self.noteText)
          .foregroundStyle(PutioTheme.Colors.textSecondary)
      }
    }
    .putioFont(PutioTheme.Typography.caption)
    .fixedSize(horizontal: false, vertical: true)
    .padding(.horizontal, PutioTheme.Spacing.space3)
  }
}

private enum PutioLinkDeviceLayout {
  static let fieldHeight = PutioMetricRole(value: 52, relativeTo: .body)
  static let codeTracking: CGFloat = 2
  static let codeFont = PutioTabularFontRole(
    base: PutioFontRole(
      fontName: PutioTheme.Typography.mono.fontName,
      size: PutioTheme.Typography.sizeBase,
      lineHeight: PutioTheme.Typography.mono.lineHeight,
      textStyle: .body))
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
    .navigationTitle("Clear your data")
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
  let runtime: PutioRuntime
  let onDestroyed: @MainActor () -> Void
  @Environment(\.openURL) private var openURL
  @Environment(\.scenePhase) private var scenePhase
  @State private var handedOff = false

  var body: some View {
    List {
      PutioSettingsSection(
        String(
          localized:
            "Destroying your account deletes your files and history and cancels your subscription. There is no way back."
        ),
        footer: String(localized: "Opens put.io in your browser to finish.")
      ) {
        PutioDestructiveRow(String(localized: "Destroy account"), alignment: .center) {
          handedOff = true
          openURL(PutioAccountWeb.dangerZoneURL)
        }
        .accessibilityAddTraits(.isLink)
        .accessibilityIdentifier("danger.destroy")
      }
      .listRowBackground(PutioTheme.Colors.surface)
    }
    .navigationTitle(String(localized: "Destroy your account"))
    .navigationBarTitleDisplayMode(.inline)
    .putioFont(PutioTheme.Typography.body)
    .putioContentBackground()
    .onChange(of: scenePhase) { _, phase in
      guard phase == .active, handedOff else { return }
      Task { await purgeIfDestroyed() }
    }
  }

  private func purgeIfDestroyed() async {
    _ = await runtime.refreshAccount()
    if case .signedOut(.sessionExpired) = runtime.session.state { onDestroyed() }
  }
}
