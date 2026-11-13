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
  @State private var confirmAlert: PutioConfirmAlert?

  init(
    actions: PutioAccountSecurityActions,
    onCleared: @escaping @MainActor (Set<PutioAccountDataCategory>, Bool) -> Void
  ) {
    _model = State(initialValue: PutioClearDataModel(actions: actions, onCleared: onCleared))
  }

  var body: some View {
    List {
      Group {
        PutioSettingsSection(Self.intro) {
          ForEach(PutioAccountDataCategory.allCases, id: \.self) { category in
            PutioCheckRow(
              category.title, icon: category.icon,
              isChecked: model.selection.contains(category)
            ) {
              model.toggle(category)
            }
            .accessibilityIdentifier("danger.clear.\(category.rawValue)")
          }
        }
        .disabled(model.isClearing)
        Section {
          PutioDestructiveRow(
            String(localized: "Clear"), alignment: .center, isBusy: model.isClearing,
            action: confirm
          )
          .disabled(!model.canClear)
          .accessibilityIdentifier("danger.clear")
        } footer: {
          outcome
        }
        if model.refreshWarning != nil {
          Section {
            Button(String(localized: "Refresh account")) {
              Task { await model.refreshAccount() }
            }
            .disabled(model.isClearing)
            .accessibilityIdentifier("danger.clear-refresh")
          }
        }
      }
      .listRowBackground(PutioTheme.Colors.surface)
    }
    .navigationTitle(String(localized: "Clear your data"))
    .navigationBarTitleDisplayMode(.inline)
    .putioFont(PutioTheme.Typography.body)
    .putioContentBackground()
    .putioConfirmAlert($confirmAlert)
  }

  @ViewBuilder private var outcome: some View {
    Group {
      if let failure = model.failure {
        Text(failure)
          .foregroundStyle(PutioTheme.Colors.destructive)
          .accessibilityIdentifier("danger.clear-failure")
      } else if let warning = model.refreshWarning {
        Text(warning)
          .foregroundStyle(PutioTheme.Colors.textSecondary)
      } else if model.didClear {
        Text(String(localized: "Done. The selected data has been cleared."))
          .foregroundStyle(PutioTheme.Colors.textSecondary)
          .accessibilityIdentifier("danger.clear-success")
      }
    }
    .putioFont(PutioTheme.Typography.caption)
  }

  private func confirm() {
    let model = model
    let categories = model.orderedSelection.map(\.title).formatted(.list(type: .and))
    confirmAlert = PutioConfirmAlert(
      title: String(localized: "Clear the selected data?"),
      message: String(
        localized:
          "This permanently deletes \(categories) from your put.io account. It can’t be undone."),
      confirmTitle: String(localized: "Clear")
    ) {
      Task { await model.clear() }
    }
  }

  private static var intro: String {
    UIDevice.current.userInterfaceIdiom == .pad
      ? String(
        localized:
          "These permanently delete data from your put.io account, on every device. To free up space on this iPad, delete downloads in Downloads instead."
      )
      : String(
        localized:
          "These permanently delete data from your put.io account, on every device. To free up space on this iPhone, delete downloads in Downloads instead."
      )
  }
}

extension PutioAccountDataCategory {
  fileprivate var icon: PutioIcon {
    switch self {
    case .files: .folder
    case .finishedTransfers: .checkCircle
    case .activeTransfers: .cloudArrowDown
    case .rssFeeds: .rss
    case .rssLogs: .listBullets
    case .history: .clockCounterClockwise
    case .trash: .trash
    case .friends: .users
    }
  }
}

struct DestroyAccountView: View {
  @Environment(\.openURL) private var openURL

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
  }
}
