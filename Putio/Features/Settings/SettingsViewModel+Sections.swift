import Foundation
import UIKit
import Intercom

extension SettingsViewModel {
    func buildSections() -> [SettingsModel.Section] {
        [
            informationSection(),
            storageSection(),
            filesSection(),
            mediaPlaybackSection(),
            securitySection(),
            privacySection(),
            supportSection(),
            dangerZoneSection(),
            logoutSection()
        ]
    }

    private func informationSection() -> SettingsModel.Section {
        SettingsModel.Section(
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
    }

    private func storageSection() -> SettingsModel.Section {
        SettingsModel.Section(
            title: "Storage",
            items: [
                SettingsModel.SectionItem(
                    title: "Usage",
                    type: .button,
                    icon: "iconServer",
                    value: storageUsageText(),
                    action: { self.toggleOptimisticUsage() },
                    visible: true
                ),
                SettingsModel.SectionItem(
                    title: "Move deleted files to trash",
                    type: .toggle,
                    icon: "iconRecycle",
                    value: settings.trashEnabled,
                    action: { self.toggleTrashEnabled() },
                    visible: true
                ),
                SettingsModel.SectionItem(
                    title: "Manage your trash",
                    type: .link,
                    icon: "iconTrash",
                    value: user.trashSize > 0 ? user.trashSize.bytesToHumanReadable() : "",
                    action: { self.tableViewController?.performSegue(withIdentifier: "toTrash", sender: nil) },
                    visible: settings.trashEnabled
                )
            ]
        )
    }

    private func filesSection() -> SettingsModel.Section {
        SettingsModel.Section(
            title: "Files",
            items: [
                SettingsModel.SectionItem(
                    title: "Default sort option for files",
                    type: .button,
                    icon: "iconAlignLeft",
                    value: "\(selectedSortByKey.label) \(selectedSortByDirection.label)",
                    action: { self.presentSortSettings() },
                    visible: true
                ),
                SettingsModel.SectionItem(
                    title: "Reset all sort settings",
                    type: .button,
                    icon: "iconRefresh",
                    value: "",
                    action: { self.resetSortSettings() },
                    visible: true
                )
            ]
        )
    }

    private func mediaPlaybackSection() -> SettingsModel.Section {
        SettingsModel.Section(
            title: "Media playback",
            items: [
                SettingsModel.SectionItem(
                    title: "Choose your proxy",
                    type: .link,
                    icon: "iconRoute",
                    value: settings.routeName == "default" ? "Amsterdam" : settings.routeName,
                    action: { self.tableViewController?.performSegue(withIdentifier: "toRoutes", sender: nil) },
                    visible: true
                ),
                SettingsModel.SectionItem(
                    title: "Chromecast video playback type",
                    type: .link,
                    icon: "iconVideo",
                    value: config.chromecastPlaybackType.uppercased(with: .autoupdatingCurrent),
                    action: {
                        let value = self.config.chromecastPlaybackType == "hls" ? "mp4" : "hls"
                        self.saveConfig(key: "chromecast_playback_type", realmKey: "chromecastPlaybackType", value: value)
                    },
                    visible: true
                ),
                SettingsModel.SectionItem(
                    title: "Show subtitles",
                    type: .toggle,
                    icon: "iconFile",
                    value: !settings.hideSubtitles,
                    action: {
                        self.saveSetting(key: "hide_subtitles", realmKey: "hideSubtitles", value: !self.settings.hideSubtitles)
                    },
                    visible: true
                ),
                SettingsModel.SectionItem(
                    title: "Do not select subtitles by default",
                    type: .toggle,
                    icon: "iconFile",
                    value: settings.dontAutoSelectSubtitles,
                    action: {
                        self.saveSetting(
                            key: "dont_autoselect_subtitles",
                            realmKey: "dontAutoSelectSubtitles",
                            value: !self.settings.dontAutoSelectSubtitles
                        )
                    },
                    visible: !settings.hideSubtitles
                )
            ]
        )
    }

    private func securitySection() -> SettingsModel.Section {
        SettingsModel.Section(
            title: "Security",
            items: [
                SettingsModel.SectionItem(
                    title: "Two-factor authentication",
                    type: .toggle,
                    icon: "iconLock",
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
                    icon: "iconFile",
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
                    action: { self.tableViewController?.performSegue(withIdentifier: "toAuthApps", sender: nil) },
                    visible: true
                ),
                SettingsModel.SectionItem(
                    title: "Link your account",
                    type: .link,
                    icon: "iconTV",
                    value: "",
                    action: { self.tableViewController?.performSegue(withIdentifier: "toLinkDevice", sender: nil) },
                    visible: true
                )
            ]
        )
    }

    private func privacySection() -> SettingsModel.Section {
        SettingsModel.Section(
            title: "Privacy and safety",
            items: [
                SettingsModel.SectionItem(
                    title: "Keep populating history",
                    type: .toggle,
                    icon: "iconHistory",
                    value: settings.historyEnabled,
                    action: { self.toggleHistoryEnabled() },
                    visible: true
                )
            ]
        )
    }

    private func supportSection() -> SettingsModel.Section {
        SettingsModel.Section(
            title: "Support",
            items: [
                SettingsModel.SectionItem(
                    title: "About",
                    type: .link,
                    icon: "iconInfo",
                    value: "\(Bundle.main.versionNumber)+\(Bundle.main.buildNumber)",
                    action: { self.tableViewController?.performSegue(withIdentifier: "toAbout", sender: nil) },
                    visible: true
                ),
                SettingsModel.SectionItem(
                    title: "Change app icon",
                    type: .button,
                    icon: "iconImage",
                    value: "",
                    action: { self.tableViewController?.performSegue(withIdentifier: "toAppIconSettings", sender: nil) },
                    visible: true
                ),
                SettingsModel.SectionItem(
                    title: "Rate put.io on App Store",
                    type: .button,
                    icon: "iconStar",
                    value: "",
                    action: { AppStoreReviewManager.sharedInstance.requestReviewManually() },
                    visible: true
                ),
                SettingsModel.SectionItem(
                    title: "Contact us",
                    type: .button,
                    icon: Intercom.unreadConversationCount() > 0 ? "iconChatBadge" : "iconChat",
                    value: "",
                    action: { Intercom.present() },
                    visible: true
                )
            ]
        )
    }

    private func dangerZoneSection() -> SettingsModel.Section {
        SettingsModel.Section(
            title: "Danger Zone",
            items: [
                SettingsModel.SectionItem(
                    title: "Clear your data",
                    type: .link,
                    icon: "iconRemoveFolder",
                    value: "",
                    action: { self.tableViewController?.performSegue(withIdentifier: "toClearData", sender: nil) },
                    visible: true
                ),
                SettingsModel.SectionItem(
                    title: "Destroy your account",
                    type: .link,
                    icon: "iconX",
                    value: "",
                    action: { self.tableViewController?.performSegue(withIdentifier: "toDestroyAccount", sender: nil) },
                    visible: true
                )
            ]
        )
    }

    private func logoutSection() -> SettingsModel.Section {
        SettingsModel.Section(
            title: "",
            items: [
                SettingsModel.SectionItem(
                    title: "Log out",
                    type: .button,
                    icon: "iconLogout",
                    value: "",
                    action: { self.presentLogoutAlert() },
                    visible: true
                )
            ]
        )
    }

    private func storageUsageText() -> String {
        let disk = user.disk ?? UserDisk()
        if settings.showOptimisticUsage {
            return "\(disk.available.bytesToHumanReadable()) free of \(disk.size.bytesToHumanReadable())"
        }

        return "\(disk.used.bytesToHumanReadable()) of \(disk.size.bytesToHumanReadable()) used"
    }
}
