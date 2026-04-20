import Foundation
import UIKit
import PutioSDK
import RealmSwift

extension SettingsViewModel {
    private func presentLoadingAlert(title: String = NSLocalizedString("Saving...", comment: "")) -> UIAlertController {
        let alert = UIAlertController(title: title, message: nil, preferredStyle: .alert)
        tableViewController?.present(alert, animated: true)
        return alert
    }

    func presentRemoteMutationError(_ error: PutioErrorLocalizableInput) {
        let localizedError = api.localizeError(error: error)
        let errorAlert = UIAlertController(
            title: localizedError.message,
            message: localizedError.recoverySuggestion.description,
            preferredStyle: .alert
        )
        errorAlert.addAction(UIAlertAction(title: NSLocalizedString("OK", comment: ""), style: .cancel))
        update()
        tableViewController?.present(errorAlert, animated: true)
    }

    func presentSettingsRefreshError(_ error: PutioErrorLocalizableInput) {
        let localizedError = api.localizeError(error: error)
        let errorAlert = UIAlertController(
            title: localizedError.message,
            message: localizedError.recoverySuggestion.description,
            preferredStyle: .alert
        )
        errorAlert.addAction(UIAlertAction(title: NSLocalizedString("OK", comment: ""), style: .cancel))
        tableViewController?.present(errorAlert, animated: true)
    }

    func presentPersistenceFailure() {
        update()
        InternalFailurePresenter.present(
            on: tableViewController,
            title: NSLocalizedString("Settings updated", comment: ""),
            message: NSLocalizedString("The change was saved on put.io, but the app could not refresh local data. Please reopen Account settings.", comment: "")
        )
    }

    private func performRemoteMutation(
        title: String = NSLocalizedString("Saving...", comment: ""),
        mutation: (@escaping (Result<Void, PutioSDKError>) -> Void) -> Void,
        onSuccess: @escaping (Realm) -> Void
    ) {
        let loadingAlert = presentLoadingAlert(title: title)

        mutation { result in
            loadingAlert.dismiss(animated: true) {
                switch result {
                case .success:
                    guard let realm = PutioRealm.open(context: "SettingsViewModel.performRemoteMutation") else {
                        return self.presentPersistenceFailure()
                    }
                    let didWrite = PutioRealm.write(realm, context: "SettingsViewModel.performRemoteMutation.write") {
                        onSuccess(realm)
                    }
                    guard didWrite else {
                        return self.presentPersistenceFailure()
                    }
                    self.reloadPersistedState()
                    self.update()

                case .failure(let error):
                    self.presentRemoteMutationError(error)
                }
            }
        }
    }

    func saveSetting(key: String, realmKey: String, value: Any) {
        performRemoteMutation(
            mutation: { completion in
                api.saveAccountSettings(body: [key: value]) { result in
                    switch result {
                    case .success:
                        completion(.success(()))
                    case .failure(let error):
                        completion(.failure(error))
                    }
                }
            },
            onSuccess: { _ in
                self.settings[realmKey] = value
            }
        )
    }

    func saveConfig(key: String, realmKey: String, value: Any) {
        performRemoteMutation(
            mutation: { completion in
                api.put("/config/\(key)", body: ["value": value]) { result in
                    switch result {
                    case .success:
                        completion(.success(()))
                    case .failure(let error):
                        completion(.failure(error))
                    }
                }
            },
            onSuccess: { _ in
                self.config[realmKey] = value
            }
        )
    }

    func toggleOptimisticUsage() {
        saveSetting(key: "show_optimistic_usage", realmKey: "showOptimisticUsage", value: !settings.showOptimisticUsage)
    }

    func saveTrashEnabled(isEnabled: Bool) {
        let nextValue = isEnabled
        let currentValue = settings.trashEnabled

        guard nextValue != currentValue else {
            return update()
        }

        saveSetting(key: "trash_enabled", realmKey: "trashEnabled", value: nextValue)
    }

    func toggleTrashEnabled() {
        if settings.trashEnabled {
            let alert = UIAlertController(
                title: NSLocalizedString("Are you sure?", comment: ""),
                message: NSLocalizedString("Disabling trash will empty your trash first.", comment: ""),
                preferredStyle: .alert
            )
            alert.addAction(UIAlertAction(title: NSLocalizedString("Cancel", comment: ""), style: .cancel) { _ in self.update() })
            alert.addAction(UIAlertAction(title: NSLocalizedString("Disable Trash", comment: ""), style: .default) { _ in
                self.saveTrashEnabled(isEnabled: false)
            })

            tableViewController?.present(alert, animated: true)
        } else {
            saveTrashEnabled(isEnabled: true)
        }
    }

    func saveHistoryEnabled(isEnabled: Bool) {
        saveSetting(key: "history_enabled", realmKey: "historyEnabled", value: isEnabled)
    }

    func toggleHistoryEnabled() {
        if settings.historyEnabled {
            let alert = UIAlertController(
                title: NSLocalizedString("Are you sure?", comment: ""),
                message: NSLocalizedString("Disabling history will also clear your current activities.", comment: ""),
                preferredStyle: .alert
            )
            alert.addAction(UIAlertAction(title: NSLocalizedString("Cancel", comment: ""), style: .cancel) { _ in self.update() })
            alert.addAction(UIAlertAction(title: NSLocalizedString("Disable History", comment: ""), style: .default) { _ in
                self.saveHistoryEnabled(isEnabled: false)
            })

            tableViewController?.present(alert, animated: true)
        } else {
            saveHistoryEnabled(isEnabled: true)
        }
    }

    func presentSortSettings() {
        let actionSheet = UIAlertController(
            title: NSLocalizedString("Default sort option for files", comment: ""),
            message: nil,
            preferredStyle: .alert
        )

        SettingsModel.sortByKeys.forEach { sortByKey in
            let isSelected = sortByKey.key == selectedSortByKey.key
            var title = sortByKey.label
            let nextSortBy = sortByKey.key
            var nextSortDirection = selectedSortByDirection.key

            if isSelected {
                title = "\(sortByKey.label) \(selectedSortByDirection.label)"
                nextSortDirection = nextSortDirection == "ASC" ? "DESC" : "ASC"
            }

            actionSheet.addAction(UIAlertAction(title: title, style: .default) { _ in
                self.saveSortSettings("\(nextSortBy)_\(nextSortDirection)")
            })
        }

        actionSheet.addAction(UIAlertAction(title: NSLocalizedString("Cancel", comment: ""), style: .cancel))
        tableViewController?.present(actionSheet, animated: true)
    }

    func saveSortSettings(_ sortBy: String) {
        saveSetting(key: "sort_by", realmKey: "sortBy", value: sortBy)
    }

    func resetSortSettings() {
        let loadingAlert = presentLoadingAlert(title: NSLocalizedString("Resetting...", comment: ""))

        api.resetFileSpecificSortSettings { _ in
            loadingAlert.dismiss(animated: true)
        }
    }

    func presentLogoutAlert() {
        let alert = UIAlertController(title: NSLocalizedString("Are you sure?", comment: ""), message: "", preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: NSLocalizedString("Cancel", comment: ""), style: .cancel))
        alert.addAction(UIAlertAction(title: NSLocalizedString("Log out", comment: ""), style: .default) { _ in
            guard let appDelegate = UIApplication.shared.delegate as? AppDelegate else { return }
            appDelegate.logout()
        })

        tableViewController?.present(alert, animated: true)
    }
}
