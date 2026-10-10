import PutioCore
import SwiftUI

/// The account-wide privacy choices every put.io app shares
/// (putdotio/support#95): strictly necessary processing is disclosed, never
/// toggled; diagnostics are on by default and product analytics is opt-in.
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
            LabeledContent("Strictly necessary", value: "Always on")
              .accessibilityIdentifier("privacy.strictly-necessary")
          } header: {
            Text("Privacy controls")
          } footer: {
            Text(
              "Sign-in, your files, transfers, playback, and these privacy choices. Always on; nothing optional is collected here."
            )
          }
          Section {
            Toggle("Diagnostics", isOn: binding(\.diagnosticsEnabled, save: { .diagnostics($0) }))
              .disabled(!model.canSave)
              .accessibilityIdentifier("privacy.diagnostics")
          } footer: {
            Text(
              "Send crash and playback error reports so we can fix problems. They never include file names or content."
            )
          }
          Section {
            Toggle(
              "Product analytics",
              isOn: binding(\.productAnalyticsEnabled, save: { .productAnalytics($0) })
            )
            .disabled(!model.canSave)
            .accessibilityIdentifier("privacy.product-analytics")
          } footer: {
            VStack(alignment: .leading, spacing: PutioTheme.Spacing.space2) {
              Text("Share which features you use so we can improve the app.")
              Text("These choices apply to every put.io app you sign in to.")
            }
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
    .navigationTitle("Privacy")
    .putioFont(PutioTheme.Typography.body)
    .putioContentBackground()
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
