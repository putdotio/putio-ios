import Foundation
import RealmSwift
import UIKit
import Intercom
import NotificationCenter

class SettingsViewModel {
    var user: User = {
        let realm = try! Realm()
        return realm.objects(User.self).first!
    }()

    var settings: UserSettings = {
        let realm = try! Realm()
        return realm.objects(User.self).first!.settings!
    }()

    var notificationTokens: [NotificationToken] = []

    var tableViewController: SettingsTableViewController?

    var sections: [SettingsModel.Section] = []
    var selectedSortByKey: SettingsModel.SortByKey = SettingsModel.sortByKeys.first!
    var selectedSortByDirection: SettingsModel.SortByDirection = SettingsModel.SortByDirection(key: "ASC")

    init() {
        registerObservers()
        update()
    }

    deinit {
        notificationTokens.forEach { token in
            token.invalidate()
        }
    }

    func registerObservers() {
        let userObserver = user.observe({ (change) in
            switch change {
            case .change:
                self.update()
            default:
                break
            }
        })

        let settingsObserver = settings.observe({ change in
            switch change {
            case .change:
                self.update()
            default:
                break
            }
        })

        notificationTokens = [userObserver, settingsObserver]

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(update),
            name: NSNotification.Name.IntercomUnreadConversationCountDidChange,
            object: nil
        )
    }

    func fetchData() {
        api.getAccountInfo { result in
            switch result {
            case .success(let account):
                let realm = try! Realm()
                try! realm.write {
                    self.user.trashSize = account.trashSize

                    self.user.disk?.setValuesForKeys([
                        "used": account.disk.used,
                        "available": account.disk.available,
                        "size": account.disk.size
                    ])

                    self.user.settings?.setValuesForKeys([
                        "routeName": account.settings.routeName,
                        "historyEnabled": account.settings.historyEnabled,
                        "twoFactorEnabled": account.settings.twoFactorEnabled,
                        "trashEnabled": account.settings.trashEnabled,
                        "showOptimisticUsage": account.settings.showOptimisticUsage
                    ])
                }

            case .failure:
                break
            }
        }
    }

    @objc func update() {
        selectedSortByKey = SettingsModel.sortByKeys.first { $0.key == String(settings.sortBy.split(separator: "_")[0])}!
        selectedSortByDirection = SettingsModel.SortByDirection(key: String(settings.sortBy.split(separator: "_")[1]))

        // MARK: account information
        let accountInformationSection = SettingsModel.Section(
            title: "Information",
            items: [
                SettingsModel.SectionItem(
                    title: "Username",
                    type: .text,
                    icon: "iconUser",
                    value: user.username,
                    action: nil,
                    visible: true
                ),
                SettingsModel.SectionItem(
                    title: "Email address",
                    type: .text,
                    icon: "iconMail",
                    value: user.mail,
                    action: nil,
                    visible: true
                )
            ]
        )

        // MARK: storage
        let storageSection = SettingsModel.Section(
            title: "Storage",
            items: [
                SettingsModel.SectionItem(
                    title: "Usage",
                    type: .button,
                    icon: "iconServer",
                    value: settings.showOptimisticUsage ?
                        "\(user.disk!.available.bytesToHumanReadable()) free of \(user.disk!.size.bytesToHumanReadable())" :
                        "\(user.disk!.used.bytesToHumanReadable()) of \(user.disk!.size.bytesToHumanReadable()) used",
                    action: {
                        self.toggleOptimisticUsage()
                    },
                    visible: true
                ),
                SettingsModel.SectionItem(
                    title: "Move deleted files to trash",
                    type: .toggle,
                    icon: "iconRecycle",
                    value: settings.trashEnabled,
                    action: {
                        self.toggleTrashEnabled()
                    },
                    visible: true
                ),
                SettingsModel.SectionItem(
                    title: "Manage your trash",
                    type: .link,
                    icon: "iconTrash",
                    value: user.trashSize > 0 ? user.trashSize.bytesToHumanReadable() : "",
                    action: {
                        self.tableViewController?.performSegue(withIdentifier: "toTrash", sender: nil)
                    },
                    visible: settings.trashEnabled
                )
            ]
        )

        // MARK: security
        let securitySection = SettingsModel.Section(
            title: "Security",
            items: [
                SettingsModel.SectionItem(
                    title: "Two-factor authentication",
                    type: .toggle,
                    icon: "flaticons-stroke-lock-2",
                    value: settings.twoFactorEnabled,
                    action: {
                        if self.settings.twoFactorEnabled {
                            self.tableViewController?.toDisableTwoFactor()
                        } else {
                            self.tableViewController?.toEnableTwoFactor()
                        }
                    },
                    visible: true
                ),
                SettingsModel.SectionItem(
                    title: "View your two-factor recovery codes",
                    type: .link,
                    icon: "flaticons-stroke-briefcase-1",
                    value: "",
                    action: {
                        self.tableViewController?.toTwoFactorRecoveryCodes(action: .regenerateCodes)
                    },
                    visible: settings.twoFactorEnabled
                ),
                SettingsModel.SectionItem(
                    title: "Where you are logged in",
                    type: .link,
                    icon: "iconGlobe",
                    value: "",
                    action: {
                        self.tableViewController?.performSegue(withIdentifier: "toAuthApps", sender: nil)
                    },
                    visible: true
                ),
                SettingsModel.SectionItem(
                    title: "Link your account",
                    type: .link,
                    icon: "iconTV",
                    value: "",
                    action: {
                        self.tableViewController?.performSegue(withIdentifier: "toLinkDevice", sender: nil)
                    },
                    visible: true
                )
            ]
        )

        // MARK: preferences
        let preferencesSection = SettingsModel.Section(
            title: "Preferences",
            items: [
                SettingsModel.SectionItem(
                    title: "Choose your proxy",
                    type: .link,
                    icon: "iconRoute",
                    value: settings.routeName == "default" ? "Amsterdam" : settings.routeName,
                    action: {
                        self.tableViewController?.performSegue(withIdentifier: "toRoutes", sender: nil)
                    },
                    visible: true
                ),
                SettingsModel.SectionItem(
                    title: "Keep populating history",
                    type: .toggle,
                    icon: "iconHistory",
                    value: settings.historyEnabled,
                    action: {
                        self.toggleHistoryEnabled()
                    },
                    visible: true
                )
            ]
        )

        // MARK: appearance
        let appearanceSection = SettingsModel.Section(
            title: "Appearance",
            items: [
                SettingsModel.SectionItem(
                    title: "Change app icon",
                    type: .button,
                    icon: "flaticons-stroke-iphone-1",
                    value: "",
                    action: {
                        self.tableViewController?.performSegue(withIdentifier: "toAppIconSettings", sender: nil)
                    },
                    visible: true
                ),
                SettingsModel.SectionItem(
                    title: "Default sort option for files",
                    type: .button,
                    icon: "iconAlignLeft",
                    value: "\(selectedSortByKey.label) \(selectedSortByDirection.label)",
                    action: {
                        self.presentSortSettings()
                    },
                    visible: true
                ),
                SettingsModel.SectionItem(
                    title: "Reset all sort settings",
                    type: .button,
                    icon: "iconRefresh",
                    value: "",
                    action: {
                        self.resetSortSettings()
                    },
                    visible: true
                )
            ]
        )

        // MARK: support
        let supportSection = SettingsModel.Section(
            title: "Support",
            items: [
                SettingsModel.SectionItem(
                    title: "About",
                    type: .link,
                    icon: "iconInfo",
                    value: "\(Bundle.main.versionNumber)+\(Bundle.main.buildNumber)",
                    action: {
                        self.tableViewController?.performSegue(withIdentifier: "toAbout", sender: nil)
                    },
                    visible: true
                ),
                SettingsModel.SectionItem(
                    title: "Rate put.io on App Store",
                    type: .button,
                    icon: "iconStar",
                    value: "",
                    action: {
                        AppStoreReviewManager.sharedInstance.requestReviewManually()
                    },
                    visible: true
                ),
                SettingsModel.SectionItem(
                    title: "Contact us",
                    type: .button,
                    icon: Intercom.unreadConversationCount() > 0 ? "iconChatBadge" : "iconChat",
                    value: "",
                    action: {
                        Intercom.present()
                    },
                    visible: true
                )
            ]
        )

        // MARK: danger zone
        let dangerZoneSection = SettingsModel.Section(
            title: "Danger Zone",
            items: [
                SettingsModel.SectionItem(
                    title: "Clear your data",
                    type: .link,
                    icon: "iconRemoveFolder",
                    value: "",
                    action: {
                        self.tableViewController?.performSegue(withIdentifier: "toClearData", sender: nil)
                    },
                    visible: true
                ),
                SettingsModel.SectionItem(
                    title: "Destroy your account",
                    type: .link,
                    icon: "flaticons-stroke-x-2",
                    value: "",
                    action: {
                        self.tableViewController?.performSegue(withIdentifier: "toDestroyAccount", sender: nil)
                    },
                    visible: true
                )
            ]
        )

        // MARK: logout
        let logoutSection = SettingsModel.Section(title: "", items: [
            SettingsModel.SectionItem(
                title: "Log out",
                type: .button,
                icon: "iconLogout",
                value: "",
                action: {
                    self.presentLogoutAlert()
                },
                visible: true
            )
        ])

        // MARK: merge sections
        sections = [
            accountInformationSection,
            securitySection,
            storageSection,
            appearanceSection,
            preferencesSection,
            supportSection,
            dangerZoneSection,
            logoutSection
        ]

        self.tableViewController?.tableView.reloadData()
    }

    func saveSetting(key: String, realmKey: String, value: Any) {
        let loadingAlert = UIAlertController(title: "Saving...", message: nil, preferredStyle: .alert)

        self.tableViewController?.present(loadingAlert, animated: true, completion: {
            api.saveAccountSettings(body: [key: value]) { result in
                loadingAlert.dismiss(animated: true) {
                    switch result {
                    case .success:
                        let realm = try! Realm()
                        try! realm.write {
                            self.settings[realmKey] = value
                        }

                    case .failure(let error):
                        let localizedError = api.localizeError(error: error)

                        let errorAlert = UIAlertController(title: localizedError.message, message: localizedError.recoverySuggestion.description, preferredStyle: .alert)
                        errorAlert.addAction(UIAlertAction(title: "OK", style: .cancel, handler: nil))

                        self.update()
                        self.tableViewController?.present(errorAlert, animated: true, completion: nil)
                    }
                }
            }
        })
    }

    func toggleOptimisticUsage() {
        saveSetting(key: "show_optimistic_usage", realmKey: "showOptimisticUsage", value: !settings.showOptimisticUsage)
    }

    func saveTrashEnabled(isEnabled: Bool) {
        let nextValue = isEnabled
        let currentValue = settings.trashEnabled

        guard nextValue != currentValue else {
            return self.update()
        }

        saveSetting(key: "trash_enabled", realmKey: "trashEnabled", value: nextValue)
    }

    func toggleTrashEnabled() {
        if settings.trashEnabled {
            let alert = UIAlertController(
                title: "Are you sure?",
                message: "Disabling trash will empty your trash first.",
                preferredStyle: .alert
            )
            alert.addAction(UIAlertAction(title: "Cancel", style: .cancel, handler: { (_) in self.update() }))
            alert.addAction(UIAlertAction(title: "Disable Trash", style: .default, handler: { (_) in self.saveTrashEnabled(isEnabled: false) }))

            self.tableViewController?.present(alert, animated: true, completion: nil)
        } else {
            self.saveTrashEnabled(isEnabled: true)
        }
    }

    func saveHistoryEnabled(isEnabled: Bool) {
        saveSetting(key: "history_enabled", realmKey: "historyEnabled", value: isEnabled)
    }

    func toggleHistoryEnabled() {
        if settings.historyEnabled {
            let alert = UIAlertController(
                title: "Are you sure?",
                message: "Disabling history will also clear your current activities.",
                preferredStyle: .alert
            )
            alert.addAction(UIAlertAction(title: "Cancel", style: .cancel, handler: { (_) in self.update() }))
            alert.addAction(UIAlertAction(title: "Disable History", style: .default, handler: { (_) in self.saveHistoryEnabled(isEnabled: false) }))

            self.tableViewController?.present(alert, animated: true, completion: nil)
        } else {
            self.saveHistoryEnabled(isEnabled: true)
        }
    }

    func presentSortSettings() {
        let actionSheet = UIAlertController(
            title: "Default sort option for files",
            message: nil,
            preferredStyle: .alert
        )

        SettingsModel.sortByKeys.forEach { (k) in
            let isSelected = k.key == self.selectedSortByKey.key

            var title = k.label
            let nextSortBy = k.key
            var nextSortDirection = self.selectedSortByDirection.key

            if isSelected {
                title = "\(k.label) \(self.selectedSortByDirection.label)"
                nextSortDirection = nextSortDirection == "ASC" ? "DESC" : "ASC"
            }

            let button = UIAlertAction(title: title, style: .default, handler: { (_) in
                self.saveSortSettings("\(nextSortBy)_\(nextSortDirection)")
            })

            actionSheet.addAction(button)
        }

        actionSheet.addAction(UIAlertAction(title: "Cancel", style: .cancel, handler: nil))

        self.tableViewController?.present(actionSheet, animated: true, completion: nil)
    }

    func saveSortSettings(_ sortBy: String) {
        saveSetting(key: "sort_by", realmKey: "sortBy", value: sortBy)
    }

    func resetSortSettings() {
        let loadingAlert = UIAlertController(
            title: "Resetting...",
            message: "",
            preferredStyle: .alert
        )

        self.tableViewController?.present(loadingAlert, animated: true, completion: nil)

        api.resetFileSpecificSortSettings { _ in
            loadingAlert.dismiss(animated: true, completion: nil)
        }
    }

    func presentLogoutAlert() {
        let alert = UIAlertController(title: "Are you sure?", message: "", preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel, handler: nil))
        alert.addAction(UIAlertAction(title: "Log out", style: .default, handler: { (_) in
            guard let appDelegate = UIApplication.shared.delegate as? AppDelegate else { return }
            appDelegate.logout()
        }))

        self.tableViewController?.present(alert, animated: true, completion: nil)
    }
}
