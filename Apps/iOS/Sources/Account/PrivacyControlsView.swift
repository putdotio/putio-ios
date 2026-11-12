import PutioCore
import SwiftUI

@MainActor
struct PrivacyControlsView: View {
  @Environment(\.openURL) private var openURL
  @State private var model: PutioAccountPreferencesModel
  @State private var saveFailures = PutioSettingSaveFailures()

  init(runtime: PutioRuntime) {
    _model = State(initialValue: PutioAccountPreferencesModel(actions: .init(runtime: runtime)))
  }

  var body: some View {
    List {
      if model.isStale {
        Section {
          Text(
            model.failure
              ?? String(localized: "Account settings could not be confirmed. Refresh to continue.")
          )
          .foregroundStyle(PutioTheme.Colors.textSecondary)
          Button(model.isRefreshing ? "Refreshing…" : "Refresh account") {
            Task { await model.retryRefresh() }
          }
          .disabled(model.isBusy)
          .accessibilityIdentifier("privacy.refresh")
        }
        .listRowBackground(PutioTheme.Colors.surface)
      }
      if model.account != nil {
        Group {
          PutioSettingsSection(footer: PutioPrivacyControls.groupFooter) {
            PutioValueRow(
              PutioPrivacyControls.strictlyNecessary.title,
              subtitle: PutioPrivacyControls.strictlyNecessary.description,
              icon: .shieldCheck,
              value: String(localized: "Always on")
            )
            .accessibilityIdentifier("privacy.strictly-necessary")
            PutioToggleRow(
              title: PutioPrivacyControls.diagnostics.title,
              subtitle: PutioPrivacyControls.diagnostics.description,
              icon: .bug,
              isOn: binding(\.diagnosticsEnabled, save: { .diagnostics($0) })
            )
            .disabled(!model.canSave)
            .accessibilityIdentifier("privacy.diagnostics")
            PutioToggleRow(
              title: PutioPrivacyControls.productAnalytics.title,
              subtitle: PutioPrivacyControls.productAnalytics.description,
              icon: .chartLine,
              isOn: binding(\.productAnalyticsEnabled, save: { .productAnalytics($0) })
            )
            .disabled(!model.canSave)
            .accessibilityIdentifier("privacy.product-analytics")
          }
          PutioSettingsSection {
            PutioLinkRow(String(localized: "Privacy policy"), icon: .fileText) {
              openURL(PutioPrivacyControls.privacyPolicyURL)
            }
            .accessibilityIdentifier("privacy.policy")
            PutioLinkRow(String(localized: "Services we use"), icon: .list) {
              openURL(PutioPrivacyControls.servicesWeUseURL)
            }
            .accessibilityIdentifier("privacy.services")
          }
        }
        .listRowBackground(PutioTheme.Colors.surface)
      }
      if model.isSaving {
        ProgressView("Saving settings")
          .listRowBackground(PutioTheme.Colors.surface)
          .accessibilityIdentifier("privacy.saving")
      }
    }
    .navigationTitle(PutioPrivacyControls.title)
    .navigationBarTitleDisplayMode(.inline)
    .putioFont(PutioTheme.Typography.body)
    .putioContentBackground()
    .putioSettingSaveFailures(saveFailures)
  }

  private func binding(
    _ value: KeyPath<PutioAccountSnapshot, Bool>,
    save mutation: @escaping (Bool) -> PutioAccountPreferenceMutation
  ) -> Binding<Bool> {
    Binding(
      get: { model.account?[keyPath: value] ?? false },
      set: { enabled in
        Task {
          if await model.save(mutation(enabled)) == .failed { saveFailures.report() }
        }
      })
  }
}
