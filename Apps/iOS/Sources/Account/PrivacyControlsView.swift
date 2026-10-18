import PutioCore
import SwiftUI

/// The account-wide privacy choices every put.io app shares
/// (putdotio/support#95): strictly necessary processing is disclosed, never
/// toggled; diagnostics are on by default and product analytics is opt-in.
/// Each control carries its description in its row, followed by the policy
/// links (putdotio/support#135).
@MainActor
struct PrivacyControlsView: View {
  @State private var model: PutioAccountPreferencesModel

  init(runtime: PutioRuntime) {
    _model = State(initialValue: PutioAccountPreferencesModel(actions: .init(runtime: runtime)))
  }

  var body: some View {
    Form {
      if model.isStale {
        Section {
          Text(
            model.failure ?? "Account settings could not be confirmed. Refresh to continue."
          )
          .foregroundStyle(PutioTheme.Colors.textSecondary)
          Button(model.isRefreshing ? "Refreshing…" : "Refresh account") {
            Task { await model.retryRefresh() }
          }
          .disabled(model.isBusy)
          .accessibilityIdentifier("privacy.refresh")
        }
        .listRowBackground(PutioTheme.Colors.surface)
      } else if let failure = model.failure {
        Section {
          Text(failure).foregroundStyle(PutioTheme.Colors.textSecondary)
          if model.failedMutation != nil {
            Button("Try again") { Task { await model.retrySave() } }
              .disabled(model.isBusy)
              .accessibilityIdentifier("privacy.retry-save")
          }
        }
        .listRowBackground(PutioTheme.Colors.surface)
      }
      if model.account != nil {
        Group {
          Section {
            LabeledContent {
              Text("Always on")
            } label: {
              controlLabel(PutioPrivacyControls.strictlyNecessary)
            }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("privacy.strictly-necessary")
            Toggle(isOn: binding(\.diagnosticsEnabled, save: { .diagnostics($0) })) {
              controlLabel(PutioPrivacyControls.diagnostics)
            }
            .disabled(!model.canSave)
            .accessibilityIdentifier("privacy.diagnostics")
            Toggle(
              isOn: binding(\.productAnalyticsEnabled, save: { .productAnalytics($0) })
            ) {
              controlLabel(PutioPrivacyControls.productAnalytics)
            }
            .disabled(!model.canSave)
            .accessibilityIdentifier("privacy.product-analytics")
          }
          Section {
            Link("Privacy policy", destination: PutioPrivacyControls.privacyPolicyURL)
              .accessibilityIdentifier("privacy.policy")
            Link("Services we use", destination: PutioPrivacyControls.servicesWeUseURL)
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
    .putioFont(PutioTheme.Typography.body)
    .putioContentBackground()
  }

  /// The description sits inside the row, so the control's accessibility label
  /// carries it and VoiceOver reads it with the switch, not as nearby text.
  private func controlLabel(_ control: PutioPrivacyControls.Control) -> some View {
    VStack(alignment: .leading, spacing: PutioTheme.Spacing.space1) {
      Text(control.title)
      Text(control.description)
        .putioFont(PutioTheme.Typography.caption)
        .foregroundStyle(PutioTheme.Colors.textSecondary)
    }
    .padding(.vertical, PutioTheme.Spacing.space1)
    .accessibilityElement(children: .combine)
  }

  private func binding(
    _ value: KeyPath<PutioAccountSnapshot, Bool>,
    save mutation: @escaping (Bool) -> PutioAccountPreferenceMutation
  ) -> Binding<Bool> {
    Binding(
      get: { model.account?[keyPath: value] ?? false },
      set: { enabled in Task { await model.save(mutation(enabled)) } })
  }
}
