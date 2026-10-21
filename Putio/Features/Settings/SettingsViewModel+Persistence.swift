import Foundation
import UIKit
import PutioSDK
import RealmSwift

extension SettingsViewModel {
    func presentDownloadConcurrencyLimit() {
        let alert = UIAlertController(
            title: NSLocalizedString("Simultaneous downloads", comment: ""),
            message: NSLocalizedString("Choose how many offline downloads can run at once.", comment: ""),
            preferredStyle: .alert
        )
        DownloadConcurrencyPreference.allowedLimits.forEach { limit in
            alert.addAction(UIAlertAction(
                title: String(format: NSLocalizedString("%d at a time", comment: ""), limit),
                style: .default
            ) { _ in
                DownloadConcurrencyPreference.setLimit(limit)
                ProductAnalytics.capture(.settingsChanged(.downloadConcurrency, .changed))
                DownloadQueueController.sharedInstance.concurrencyLimitDidChange()
                self.update()
            })
        }
        alert.addAction(UIAlertAction(title: NSLocalizedString("Cancel", comment: ""), style: .cancel))
        presenter?.present(alert, animated: true)
    }

    private func presentLoadingAlert(title: String = NSLocalizedString("Saving...", comment: "")) -> UIAlertController {
        let alert = UIAlertController(title: title, message: nil, preferredStyle: .alert)
        presenter?.present(alert, animated: true)
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
        presenter?.present(errorAlert, animated: true)
    }

    func presentSettingsRefreshError(_ error: PutioErrorLocalizableInput) {
        let localizedError = api.localizeError(error: error)
        let errorAlert = UIAlertController(
            title: localizedError.message,
            message: localizedError.recoverySuggestion.description,
            preferredStyle: .alert
        )
        errorAlert.addAction(UIAlertAction(title: NSLocalizedString("OK", comment: ""), style: .cancel))
        presenter?.present(errorAlert, animated: true)
    }

    func presentSaveSettingFailure(_ error: PutioErrorLocalizableInput) {
        let localizedError = api.localizeError(error: error)
        let errorAlert = UIAlertController(
            title: NSLocalizedString("Couldn't save setting", comment: ""),
            message: "\(localizedError.message)\n\(localizedError.recoverySuggestion.description)",
            preferredStyle: .alert
        )
        errorAlert.addAction(UIAlertAction(title: NSLocalizedString("OK", comment: ""), style: .cancel))
        update()
        presenter?.present(errorAlert, animated: true)
    }

    func presentPersistenceFailure() {
        update()
        InternalFailurePresenter.present(
            on: presenter,
            title: NSLocalizedString("Settings updated", comment: ""),
            message: NSLocalizedString("The change was saved on put.io, but the app could not refresh local data. Please reopen Account settings.", comment: "")
        )
    }

    private func performRemoteMutation(
        title: String = NSLocalizedString("Saving...", comment: ""),
        mutation: (@escaping (Result<Void, PutioSDKError>) -> Void) -> Void,
        onFailure: ((PutioSDKError) -> Void)? = nil,
        onSuccess: @escaping (Realm) -> Void
    ) {
        let loadingAlert = presentLoadingAlert(title: title)

        mutation { result in
            if case .success = result {
                Self.confirmedSaves += 1
            }
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
                    if let onFailure {
                        onFailure(error)
                    } else {
                        self.presentRemoteMutationError(error)
                    }
                }
            }
        }
    }

    func saveAccountSettings(
        _ update: PutioAccountSettingsUpdate,
        changing setting: AnalyticsEvent.Setting,
        to value: AnalyticsEvent.SettingValue,
        onSuccess: @escaping () -> Void
    ) {
        let session = AccountNoticeStore.shared.session
        performRemoteMutation(
            mutation: { completion in
                self.saveAccountSettingsRequest(update) { result in
                    if case .success = result {
                        ProductAnalytics.capture(.settingsChanged(setting, value), startedIn: session)
                    }
                    completion(result)
                }
            },
            onSuccess: { _ in
                onSuccess()
            }
        )
    }

    func saveDiagnosticsEnabled(_ isEnabled: Bool) {
        performRemoteMutation(
            mutation: { completion in
                self.saveAccountSettingsRequest(.patch(PutioAccountSettingsPatch(diagnosticsEnabled: isEnabled))) { result in
                    // Ahead of the Realm write, so Sentry follows put.io even
                    // when the local copy can't be saved.
                    if case .success = result {
                        self.applyDiagnostics(isEnabled)
                    }
                    completion(result)
                }
            },
            onFailure: presentSaveSettingFailure,
            onSuccess: { _ in
                self.settings.diagnosticsEnabled = isEnabled
            }
        )
    }

    func saveProductAnalyticsEnabled(_ isEnabled: Bool) {
        performRemoteMutation(
            mutation: { completion in
                ProductAnalyticsChoice.save(
                    isEnabled,
                    saveSetting: { enabled, settingCompletion in
                        self.saveAccountSettingsRequest(.patch(PutioAccountSettingsPatch(productAnalyticsEnabled: enabled)), settingCompletion)
                    },
                    markAnswered: self.markProductAnalyticsPromptAnsweredRequest,
                    completion: { result in
                        switch result {
                        case .success:
                            completion(.success(()))
                        case .failure(.setting(let error)):
                            completion(.failure(error))
                        case .failure(.answer(let error)):
                            // The setting holds; without the answer the prompt asks once more.
                            InternalFailurePresenter.log("Product analytics saved, but not as the prompt's answer: \(error.localizerType)")
                            completion(.success(()))
                        }
                    }
                )
            },
            onFailure: presentSaveSettingFailure,
            onSuccess: { _ in
                self.settings.productAnalyticsEnabled = isEnabled
            }
        )
    }

    func saveChromecastPlaybackType(_ playbackType: PutioChromecastPlaybackType) {
        let session = AccountNoticeStore.shared.session
        performRemoteMutation(
            mutation: { completion in
                api.setChromecastPlaybackType(playbackType) { result in
                    switch result {
                    case .success:
                        ProductAnalytics.capture(.settingsChanged(.chromecastVideoPlaybackType, .init(playbackType)), startedIn: session)
                        completion(.success(()))
                    case .failure(let error):
                        completion(.failure(error))
                    }
                }
            },
            onSuccess: { _ in
                self.config.chromecastPlaybackType = playbackType.rawValue
            }
        )
    }

    func toggleOptimisticUsage() {
        let value = !settings.showOptimisticUsage
        saveAccountSettings(.patch(PutioAccountSettingsPatch(showOptimisticUsage: value)), changing: .showOptimisticUsage, to: .init(value)) {
            self.settings.showOptimisticUsage = value
        }
    }

    func saveTrashEnabled(isEnabled: Bool) {
        let nextValue = isEnabled
        let currentValue = settings.trashEnabled

        guard nextValue != currentValue else {
            return update()
        }

        saveAccountSettings(.patch(PutioAccountSettingsPatch(trashEnabled: nextValue)), changing: .trashEnabled, to: .init(nextValue)) {
            self.settings.trashEnabled = nextValue
        }
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

            presenter?.present(alert, animated: true)
        } else {
            saveTrashEnabled(isEnabled: true)
        }
    }

    func saveHistoryEnabled(isEnabled: Bool) {
        saveAccountSettings(.patch(PutioAccountSettingsPatch(historyEnabled: isEnabled)), changing: .historyEnabled, to: .init(isEnabled)) {
            self.settings.historyEnabled = isEnabled
        }
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

            presenter?.present(alert, animated: true)
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
        presenter?.present(actionSheet, animated: true)
    }

    func saveSortSettings(_ sortBy: String) {
        saveAccountSettings(.patch(PutioAccountSettingsPatch(sortBy: sortBy)), changing: .sortBy, to: .changed) {
            self.settings.sortBy = sortBy
        }
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

        presenter?.present(alert, animated: true)
    }
}
