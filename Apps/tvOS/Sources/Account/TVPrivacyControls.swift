import PutioCore
import SwiftUI

/// The account-wide privacy controls, with the policy as a QR code beside
/// them.
struct TVPrivacyControlsView: View {
  @State private var model: PutioAccountPreferencesModel
  @State private var toast: PutioToast?

  init(runtime: PutioRuntime) {
    _model = State(initialValue: PutioAccountPreferencesModel(actions: .init(runtime: runtime)))
  }

  var body: some View {
    Group {
      if let account = model.account {
        TVPrivacyControlsScreen(
          account: account, canSave: model.canSave,
          save: { mutation in
            Task {
              let outcome = await model.save(mutation)
              if outcome == .failed || outcome == .unavailable {
                toast = PutioToast(TVAccountScreen.saveFailedMessage, icon: .warning)
              }
            }
          })
      } else {
        PutioLoadingStateView()
      }
    }
    .putioToast($toast)
  }
}

struct TVPrivacyControlsScreen: View {
  let account: PutioAccountSnapshot
  var canSave = true
  var save: (PutioAccountPreferenceMutation) -> Void = { _ in }

  var body: some View {
    HStack(alignment: .top, spacing: TVAccountLayout.columnGap) {
      VStack(alignment: .leading, spacing: PutioTheme.TV.Spacing.small) {
        VStack(alignment: .leading, spacing: PutioTheme.TV.Spacing.xs) {
          Text(TVAccountSection.account.title)
            .putioFont(PutioTheme.TV.Typography.small)
            .foregroundStyle(PutioTheme.TV.Colors.textSecondary)
          Text(PutioPrivacyControls.title)
            .putioFont(PutioTheme.TV.Typography.heading)
            .foregroundStyle(PutioTheme.TV.Colors.textPrimary)
            .accessibilityAddTraits(.isHeader)
        }
        .padding(.horizontal, PutioTheme.TV.Spacing.medium)
        TVRowList {
          TVPrivacyRow(
            control: PutioPrivacyControls.strictlyNecessary,
            value: String(localized: "Always on", bundle: .putioCore)
          )
          .tvRowPadding()
          .accessibilityElement(children: .combine)
          .accessibilityIdentifier("privacy.strictly-necessary")
          toggle(
            PutioPrivacyControls.diagnostics, isOn: account.diagnosticsEnabled,
            identifier: "privacy.diagnostics", save: { .diagnostics($0) })
          toggle(
            PutioPrivacyControls.productAnalytics, isOn: account.productAnalyticsEnabled,
            identifier: "privacy.product-analytics", save: { .productAnalytics($0) })
          Text(PutioPrivacyControls.groupFooter)
            .putioFont(PutioTheme.TV.Typography.caption)
            .foregroundStyle(PutioTheme.TV.Colors.textSecondary)
            .padding(.horizontal, PutioTheme.TV.Spacing.medium)
            .fixedSize(horizontal: false, vertical: true)
        }
      }
      .frame(width: TVAccountLayout.listWidth)
      TVPrivacyPolicyPanel()
        .frame(width: TVAccountLayout.panelWidth)
        .frame(maxHeight: .infinity, alignment: .top)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    .tvOverscanPadding()
    .background(PutioTheme.Colors.background.ignoresSafeArea())
  }

  private func toggle(
    _ control: PutioPrivacyControls.Control, isOn: Bool, identifier: String,
    save mutation: @escaping (Bool) -> PutioAccountPreferenceMutation
  ) -> some View {
    Button {
      save(mutation(!isOn))
    } label: {
      TVPrivacyRow(control: control, value: TVAccountScreen.onOff(isOn))
        .tvRowPadding()
    }
    .disabled(!canSave)
    .accessibilityIdentifier(identifier)
    .accessibilityValue(TVAccountScreen.onOff(isOn))
  }
}

private struct TVPrivacyRow: View {
  let control: PutioPrivacyControls.Control
  let value: String

  var body: some View {
    HStack(alignment: .top, spacing: PutioTheme.TV.Spacing.medium) {
      VStack(alignment: .leading, spacing: PutioTheme.TV.Spacing.xs) {
        Text(control.title)
          .putioFont(TVValueRow.titleFont)
          .foregroundStyle(.putioRowPrimary)
        Text(control.description)
          .putioFont(PutioTheme.TV.Typography.caption)
          .foregroundStyle(.putioRowSecondary)
          .fixedSize(horizontal: false, vertical: true)
      }
      Spacer(minLength: PutioTheme.TV.Spacing.small)
      Text(value)
        .putioFont(PutioTheme.TV.Typography.body)
        .foregroundStyle(.putioRowSecondary)
    }
  }
}

private struct TVPrivacyPolicyPanel: View {
  var body: some View {
    TVAccountPanel(
      content: TVAccountPanelContent(
        row: .privacy,
        title: String(localized: "Privacy policy", bundle: .putioCore),
        description: String(
          localized: "Read the policy and the services we use on the web. Scan with your phone.",
          bundle: .putioCore),
        qr: TVAccountPanelQR(text: PutioPrivacyControls.privacyPolicyURL.absoluteString)))
  }
}

/// Open-source notices for the app and every package it ships, with the
/// focused one's license as a QR code.
struct TVLicensesView: View {
  var notices: [PutioLicenseNotice] =
    PutioLicenseManifest.load(.main)?.notices(appVersion: PutioAppInfo.shortVersion()) ?? []

  @State private var shown: PutioLicenseNotice.ID?
  @FocusState private var focused: PutioLicenseNotice.ID?

  var body: some View {
    HStack(alignment: .top, spacing: TVAccountLayout.columnGap) {
      VStack(alignment: .leading, spacing: PutioTheme.TV.Spacing.small) {
        TVScreenHeader(title: TVAccountRow.licenses.title) {}
          .padding(.horizontal, PutioTheme.TV.Spacing.medium)
        TVRowList {
          Text(PutioLicenseManifest.summary)
            .putioFont(PutioTheme.TV.Typography.caption)
            .foregroundStyle(PutioTheme.TV.Colors.textSecondary)
            .padding(.horizontal, PutioTheme.TV.Spacing.medium)
            .fixedSize(horizontal: false, vertical: true)
          ForEach(notices) { notice in
            Button {
            } label: {
              TVValueRow(title: notice.title, value: notice.license)
            }
            .focused($focused, equals: notice.id)
            .accessibilityIdentifier("licenses.\(notice.id)")
          }
        }
      }
      .frame(width: TVAccountLayout.listWidth)
      if let notice = notices.first(where: { $0.id == shown }) ?? notices.first {
        TVAccountPanel(
          content: TVAccountPanelContent(
            row: .licenses, title: notice.title, description: notice.copyright,
            qr: TVAccountPanelQR(text: (notice.source ?? notice.licenseText).absoluteString))
        )
        .frame(width: TVAccountLayout.panelWidth)
        .frame(maxHeight: .infinity, alignment: .top)
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    .tvOverscanPadding()
    .background(PutioTheme.Colors.background.ignoresSafeArea())
    .onChange(of: focused) { _, id in
      if let id { shown = id }
    }
  }
}
