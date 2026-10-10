import PutioCore
import SwiftUI

struct AccountView: View {
  let runtime: PutioRuntime
  let account: PutioAccountSnapshot
  let refreshRequests: PutioFolderRefreshRequests
  let trashReconciliation: PutioTrashReconciliation
  let cast: PutioCastModel
  let appConfig: PutioAppConfigModel
  @Binding var showsLinkDevice: Bool
  let linkDeviceCode: String?
  let onDataCleared: @MainActor (Set<PutioAccountDataCategory>, Bool) -> Void
  let onAccountDestroyed: @MainActor () -> Void
  @Environment(\.openURL) private var openURL
  @State private var isRefreshingStorage = false
  @State private var confirmsSignOut = false

  var body: some View {
    List {
      Group {
        Section {
          LabeledContent("Username", value: account.username)
          LabeledContent("Email", value: account.email)
        }
        Section {
          NavigationLink("File preferences") {
            FilePreferencesView(
              runtime: runtime,
              refreshRequests: refreshRequests
            )
          }
          .accessibilityIdentifier("account.file-preferences")
          NavigationLink("Playback preferences") {
            PlaybackPreferencesView(runtime: runtime, appConfig: appConfig)
          }
          .accessibilityIdentifier("account.playback-preferences")
          NavigationLink("Chromecast") {
            PutioCastPreferencesView(model: cast)
          }
          .accessibilityIdentifier("account.chromecast")
          NavigationLink("Security") {
            AccountSecurityView(runtime: runtime)
          }
          .accessibilityIdentifier("account.security")
          NavigationLink("Privacy") {
            PrivacyControlsView(runtime: runtime)
          }
          .accessibilityIdentifier("account.privacy")
        }
        Section("Storage") {
          VStack(alignment: .leading, spacing: PutioTheme.Spacing.space2) {
            ProgressView(value: account.storage.usedFraction)
              .tint(PutioTheme.Colors.accent)
              .accessibilityHidden(true)
            Text(account.storage.usageSummary())
              .accessibilityIdentifier("account.storage-used")
          }
          .padding(.vertical, PutioTheme.Spacing.space1)
          if runtime.session.isAccountStorageStale {
            // Stale-storage state outlives the Trash screen that caused it.
            PutioErrorStateView(
              title: PutioTrashErrorPresentation.staleStorage.title,
              message: PutioTrashErrorPresentation.staleStorage.message,
              retryTitle: isRefreshingStorage ? "Updating…" : "Update storage"
            ) {
              // Flip the flag before suspending so a second tap cannot start
              // another refresh, and only the one owner clears it.
              guard !isRefreshingStorage else { return }
              isRefreshingStorage = true
              Task {
                defer { isRefreshingStorage = false }
                _ = await runtime.refreshAccount()
              }
            }
            .disabled(isRefreshingStorage)
            .accessibilityIdentifier("account.storage-retry")
          }
          if account.trashEnabled {
            NavigationLink("Manage your trash") {
              TrashManagementView(
                runtime: runtime,
                reconciliation: trashReconciliation,
                onRestored: reconcileRestoredFile
              )
            }
            .accessibilityIdentifier("account.trash")
          }
        }
        if let reviewURL = PutioAppStoreReview.url() {
          Section("Support") {
            NavigationLink("About") {
              AboutView()
            }
            .accessibilityIdentifier("account.about")
            Link("Rate put.io on App Store", destination: reviewURL)
              .accessibilityIdentifier("account.rate-app")
            Button("Contact us") {
              PutioSupportMessenger.shared.contactSupport { openURL($0) }
            }
            .accessibilityIdentifier("account.contact-support")
          }
        }
        Section("Danger zone") {
          NavigationLink("Clear your data") {
            ClearDataView(actions: .init(runtime: runtime), onCleared: onDataCleared)
          }
          .accessibilityIdentifier("account.clear-data")
          NavigationLink("Destroy your account") {
            DestroyAccountView(actions: .init(runtime: runtime), onDestroyed: onAccountDestroyed)
          }
          .accessibilityIdentifier("account.destroy-account")
        }
        Section {
          Button("Log out", role: .destructive) { confirmsSignOut = true }
            .accessibilityIdentifier("auth.sign-out")
        }
      }
      .listRowBackground(PutioTheme.Colors.surface)
    }
    .navigationTitle("Account")
    .putioFont(PutioTheme.Typography.body)
    .putioContentBackground()
    .alert("Are you sure?", isPresented: $confirmsSignOut) {
      Button("Cancel", role: .cancel) {}
      Button("Log out", role: .destructive) {
        PutioFilesNavigationRestoration().clear(accountID: account.id)
        Task { await runtime.session.signOut() }
      }
      .accessibilityIdentifier("auth.sign-out-confirm")
    }
    .navigationDestination(isPresented: $showsLinkDevice) {
      LinkDeviceView(actions: .init(runtime: runtime), code: linkDeviceCode)
    }
  }

  private func reconcileRestoredFile(destinationID: PutioFileID?) {
    PutioRestoredFileReconciliation.apply(destinationID: destinationID, to: refreshRequests)
  }
}
