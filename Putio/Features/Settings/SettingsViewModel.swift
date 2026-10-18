import Foundation
import RealmSwift
import UIKit
import Intercom
import NotificationCenter
import PutioSDK

class SettingsViewModel {
    typealias SaveAccountSettingsRequest = (PutioAccountSettingsUpdate, @escaping (Result<Void, PutioSDKError>) -> Void) -> Void
    typealias FetchAccountInfoRequest = (@escaping (Result<PutioAccount, PutioSDKError>) -> Void) -> Void

    /// Counts the saves put.io has confirmed from Account and the product
    /// analytics prompt. An account read that started before the latest one
    /// carries older settings, so none of them apply: a Diagnostics opt-out
    /// must not switch Sentry back on, nor an Allow switch PostHog off.
    static var confirmedSaves = 0

    /// Counts the foreground refreshes. Only the latest one answers, and an
    /// Account read that started before it carries older consent, so the
    /// refresh decides product analytics instead.
    static var accountRefreshes = 0

    let saveAccountSettingsRequest: SaveAccountSettingsRequest
    let markProductAnalyticsPromptAnsweredRequest: ProductAnalyticsChoice.Request
    let applyDiagnostics: (Bool) -> Void
    let applyProductAnalytics: (Int, Bool) -> Void
    let fetchAccountInfoRequest: FetchAccountInfoRequest

    private(set) var user = User()
    private(set) var settings = UserSettings()
    private(set) var config = UserConfig()

    var notificationTokens: [NotificationToken] = []

    weak var tableViewController: SettingsTableViewController?
    weak var privacyControlsViewController: PrivacyControlsViewController?

    /// Alerts go to the Privacy controls page while it is on screen, since
    /// Account sits under it in the navigation stack.
    var presenter: UIViewController? {
        if let page = privacyControlsViewController, page.viewIfLoaded?.window != nil {
            return page
        }
        return tableViewController
    }

    var sections: [SettingsModel.Section] = []
    var selectedSortByKey: SettingsModel.SortByKey = SettingsModel.sortByKeys.first!
    var selectedSortByDirection = SettingsModel.SortByDirection(key: "ASC")

    init(
        saveAccountSettingsRequest: @escaping SaveAccountSettingsRequest = { update, completion in
            api.saveAccountSettings(update) { completion($0.map { _ in }) }
        },
        markProductAnalyticsPromptAnsweredRequest: @escaping ProductAnalyticsChoice.Request = ProductAnalyticsChoice.markAnsweredRequest,
        applyDiagnostics: @escaping (Bool) -> Void = { SentryTelemetry.update(diagnosticsEnabled: $0) },
        applyProductAnalytics: @escaping (Int, Bool) -> Void = { ProductAnalytics.update(accountID: $0, productAnalyticsEnabled: $1) },
        fetchAccountInfoRequest: @escaping FetchAccountInfoRequest = { api.getAccountInfo($0) }
    ) {
        self.saveAccountSettingsRequest = saveAccountSettingsRequest
        self.markProductAnalyticsPromptAnsweredRequest = markProductAnalyticsPromptAnsweredRequest
        self.applyDiagnostics = applyDiagnostics
        self.applyProductAnalytics = applyProductAnalytics
        self.fetchAccountInfoRequest = fetchAccountInfoRequest
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
        let noticeSession = AccountNoticeStore.shared.session
        let savesBeforeRead = Self.confirmedSaves
        let refreshesBeforeRead = Self.accountRefreshes

        fetchAccountInfoRequest { result in
            switch result {
            case .success(let account):
                AccountNoticeStore.shared.update(with: account, startedIn: noticeSession)
                guard savesBeforeRead == Self.confirmedSaves else { return }
                self.applyDiagnostics(account.settings.diagnosticsEnabled)
                // Signing out moves the session on, and a signed-out app sends nothing.
                if noticeSession == AccountNoticeStore.shared.session, refreshesBeforeRead == Self.accountRefreshes {
                    self.applyProductAnalytics(account.id, account.settings.productAnalyticsEnabled)
                }
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
                        "dontAutoSelectSubtitles": account.settings.dontAutoSelectSubtitles,
                        "diagnosticsEnabled": account.settings.diagnosticsEnabled,
                        "productAnalyticsEnabled": account.settings.productAnalyticsEnabled
                    ])
                }

                guard didWrite else { return }
                self.reloadPersistedState()
                self.update()

            case .failure(let error):
                self.presentSettingsRefreshError(error)
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
        privacyControlsViewController?.reload()
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
