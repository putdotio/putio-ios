import PutioCore
import SwiftUI

@MainActor
struct FilePreferencesView: View {
  let runtime: PutioRuntime
  let refreshRequests: PutioFolderRefreshRequests
  let trashReconciliation: PutioTrashReconciliation

  @State private var model: PutioFilePreferencesModel
  @State private var confirmation: Confirmation?

  init(
    runtime: PutioRuntime,
    refreshRequests: PutioFolderRefreshRequests,
    trashReconciliation: PutioTrashReconciliation
  ) {
    self.runtime = runtime
    self.refreshRequests = refreshRequests
    self.trashReconciliation = trashReconciliation
    _model = State(
      initialValue: PutioFilePreferencesModel(
        actions: PutioFilePreferencesActions(runtime: runtime)))
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
          .accessibilityIdentifier("settings.refresh")
        }
        .listRowBackground(PutioTheme.Colors.surface)
      }
      if let failure = model.failure, !model.isStale {
        Section {
          Text(failure)
            .foregroundStyle(PutioTheme.Colors.textSecondary)
          if model.failedMutation != nil {
            Button("Try again") { Task { await model.retrySave() } }
              .disabled(isBusy)
              .accessibilityIdentifier("settings.retry-save")
          }
        }
        .listRowBackground(PutioTheme.Colors.surface)
      }
      if let account = model.account {
        Group {
          Section {
            Picker("Default sort", selection: defaultSort) {
              if account.defaultSort == nil {
                Text("Current server setting").tag(nil as PutioFolderSort?)
              }
              ForEach(PutioFolderSort.allCases, id: \.self) { sort in
                Text(sort.title)
                  .tag(Optional(sort))
                  .accessibilityIdentifier("settings.sort.\(sort.rawValue)")
              }
            }
            .pickerStyle(.menu)
            .accessibilityIdentifier("settings.default-sort")
            Button("Reset folder sorts") { confirmation = .resetSort }
              .accessibilityIdentifier("settings.reset-sort")
          } header: {
            Text("Files")
          } footer: {
            Text("Folders use the default sort unless you choose a different order inside them.")
          }
          Section {
            Toggle("Use Trash", isOn: trashEnabled)
              .accessibilityIdentifier("settings.trash")
            NavigationLink("Manage Trash") {
              TrashManagementView(
                runtime: runtime, reconciliation: trashReconciliation,
                onRestored: { destination in
                  PutioRestoredFileReconciliation.apply(
                    destinationID: destination, to: refreshRequests)
                })
            }
            .accessibilityIdentifier("settings.manage-trash")
          } header: {
            Text("Trash")
          } footer: {
            Text("When Trash is off, deleted files cannot be restored.")
          }
          Section {
            Toggle("Save History", isOn: historyEnabled)
              .accessibilityIdentifier("settings.history")
          } header: {
            Text("History")
          } footer: {
            Text("Keep account events in History. Turning this off clears existing history.")
          }
        }
        .disabled(isBusy || model.isStale)
        .listRowBackground(PutioTheme.Colors.surface)
      }
      if model.isSaving {
        ProgressView("Saving settings")
          .listRowBackground(PutioTheme.Colors.surface)
          .accessibilityIdentifier("settings.saving")
      }
    }
    .navigationTitle("File Preferences")
    .putioFont(PutioTheme.Typography.body)
    .putioContentBackground()
    .confirmationDialog(
      confirmation?.title ?? "Update settings?",
      isPresented: Binding(
        get: { confirmation != nil },
        set: { if !$0 { confirmation = nil } }),
      titleVisibility: .visible
    ) {
      switch confirmation {
      case .trash:
        Button("Turn Off Trash", role: .destructive) { save(.trash(false)) }
          .accessibilityIdentifier("settings.trash-disable")
      case .history:
        Button("Turn Off History", role: .destructive) { save(.history(false)) }
          .accessibilityIdentifier("settings.history-disable")
      case .resetSort:
        Button("Reset Folder Sorts", role: .destructive) { save(.resetFolderSorts) }
          .accessibilityIdentifier("settings.reset-sort-confirm")
      case nil:
        EmptyView()
      }
      Button("Cancel", role: .cancel) { confirmation = nil }
    } message: {
      Text(confirmation?.message ?? "")
    }
  }

  private var isBusy: Bool { model.isBusy }

  private var defaultSort: Binding<PutioFolderSort?> {
    Binding(
      get: { model.account?.defaultSort },
      set: { if let sort = $0 { save(.defaultSort(sort)) } })
  }

  private var trashEnabled: Binding<Bool> {
    Binding(
      get: { model.account?.trashEnabled ?? false },
      set: { enabled in
        if enabled { save(.trash(true)) } else { confirmation = .trash }
      })
  }

  private var historyEnabled: Binding<Bool> {
    Binding(
      get: { model.account?.historyEnabled ?? false },
      set: { enabled in
        if enabled { save(.history(true)) } else { confirmation = .history }
      })
  }

  private func save(_ mutation: PutioFilePreferencesMutation) {
    confirmation = nil
    Task { await model.save(mutation) }
  }

  private enum Confirmation {
    case trash, history, resetSort

    var title: String {
      switch self {
      case .trash: "Turn off Trash?"
      case .history: "Turn off History?"
      case .resetSort: "Reset all folder sorts?"
      }
    }

    var message: String {
      switch self {
      case .trash:
        "Every item in Trash will be permanently deleted. Future deletions cannot be restored."
      case .history:
        "Existing history will be cleared and new account events will no longer be saved."
      case .resetSort:
        "Every folder will use your account's default sort."
      }
    }
  }
}
