import Foundation
import RealmSwift
import UIKit
import Intercom
import NotificationCenter

class SettingsViewModel {
    private(set) var user = User()
    private(set) var settings = UserSettings()
    private(set) var config = UserConfig()

    var notificationTokens: [NotificationToken] = []

    weak var tableViewController: SettingsTableViewController?

    var sections: [SettingsModel.Section] = []
    var selectedSortByKey: SettingsModel.SortByKey = SettingsModel.sortByKeys.first!
    var selectedSortByDirection = SettingsModel.SortByDirection(key: "ASC")

    init() {
        reloadPersistedState()
        registerObservers()
        update()
    }

    deinit {
        notificationTokens.forEach { token in
            token.invalidate()
        }
        NotificationCenter.default.removeObserver(self)
    }

    func registerObservers() {
        var tokens: [NotificationToken] = []

        if user.realm != nil {
            let userObserver = user.observe { change in
                switch change {
                case .change:
                    self.update()
                default:
                    break
                }
            }
            tokens.append(userObserver)
        }

        if settings.realm != nil {
            let settingsObserver = settings.observe { change in
                switch change {
                case .change:
                    self.update()
                default:
                    break
                }
            }
            tokens.append(settingsObserver)
        }

        if config.realm != nil {
            let configObserver = config.observe { change in
                switch change {
                case .change:
                    self.update()
                default:
                    break
                }
            }
            tokens.append(configObserver)
        }

        notificationTokens = tokens

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
                guard let realm = PutioRealm.open(context: "SettingsViewModel.fetchData") else { return }

                let didWrite = PutioRealm.write(realm, context: "SettingsViewModel.fetchData.write") {
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
                        "showOptimisticUsage": account.settings.showOptimisticUsage,
                        "hideSubtitles": account.settings.hideSubtitles,
                        "dontAutoSelectSubtitles": account.settings.dontAutoSelectSubtitles
                    ])
                }

                guard didWrite else { return }
                self.reloadPersistedState()
                self.update()

            case .failure:
                break
            }
        }
    }

    func reloadPersistedState() {
        guard let realm = PutioRealm.open(context: "SettingsViewModel.reloadPersistedState") else { return }

        if let persistedUser = realm.objects(User.self).first {
            user = persistedUser
        }

        if let persistedSettings = realm.objects(User.self).first?.settings {
            settings = persistedSettings
        }

        if let persistedConfig = realm.objects(UserConfig.self).first {
            config = persistedConfig
        }
    }

    @objc func update() {
        updateSelectedSortState()
        sections = buildSections()
        tableViewController?.tableView.reloadData()
    }

    func updateSelectedSortState() {
        let components = settings.sortBy.split(separator: "_")
        guard components.count == 2 else {
            selectedSortByKey = SettingsModel.sortByKeys.first!
            selectedSortByDirection = SettingsModel.SortByDirection(key: "ASC")
            return
        }

        let nextSortKey = String(components[0])
        let nextSortDirection = String(components[1])

        selectedSortByKey = SettingsModel.sortByKeys.first { $0.key == nextSortKey } ?? SettingsModel.sortByKeys.first!
        selectedSortByDirection = SettingsModel.SortByDirection(key: nextSortDirection)
    }
}
