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
            title: NSLocalizedString("Information", comment: ""),
            items: [
                SettingsModel.SectionItem(
                    title: NSLocalizedString("Username", comment: ""),
                    type: .text,
                    icon: "iconUser",
                    value: user.username,
                    action: nil,
                    visible: true
                ),
                SettingsModel.SectionItem(
                    title: NSLocalizedString("Email address", comment: ""),
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
            title: NSLocalizedString("Storage", comment: ""),
            items: [
                SettingsModel.SectionItem(
                    title: NSLocalizedString("Usage", comment: ""),
                    type: .button,
                    icon: "iconServer",
                    value: storageUsageText(),
                    action: { self.toggleOptimisticUsage() },
                    visible: true
                ),
                SettingsModel.SectionItem(
                    title: NSLocalizedString("Move deleted files to trash", comment: ""),
                    type: .toggle,
                    icon: "iconRecycle",
                    value: settings.trashEnabled,
                    action: { self.toggleTrashEnabled() },
                    visible: true
                ),
                SettingsModel.SectionItem(
                    title: NSLocalizedString("Manage your trash", comment: ""),
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
            title: NSLocalizedString("Files", comment: ""),
            items: [
                SettingsModel.SectionItem(
                    title: NSLocalizedString("Default sort option for files", comment: ""),
                    type: .button,
                    icon: "iconAlignLeft",
                    value: "\(selectedSortByKey.label) \(selectedSortByDirection.label)",
                    action: { self.presentSortSettings() },
                    visible: true
                ),
                SettingsModel.SectionItem(
                    title: NSLocalizedString("Reset all sort settings", comment: ""),
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
            title: NSLocalizedString("Media playback", comment: ""),
            items: [
                SettingsModel.SectionItem(
                    title: NSLocalizedString("Choose your proxy", comment: ""),
                    type: .link,
                    icon: "iconRoute",
                    value: settings.routeName == "default" ? NSLocalizedString("Amsterdam", comment: "") : settings.routeName,
                    action: { self.tableViewController?.performSegue(withIdentifier: "toRoutes", sender: nil) },
                    visible: true
                ),
                SettingsModel.SectionItem(
                    title: NSLocalizedString("Chromecast video playback type", comment: ""),
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
                    title: NSLocalizedString("Show subtitles", comment: ""),
                    type: .toggle,
                    icon: "iconFile",
                    value: !settings.hideSubtitles,
                    action: {
                        self.saveSetting(key: "hide_subtitles", realmKey: "hideSubtitles", value: !self.settings.hideSubtitles)
                    },
                    visible: true
                ),
                SettingsModel.SectionItem(
                    title: NSLocalizedString("Do not select subtitles by default", comment: ""),
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
            title: NSLocalizedString("Security", comment: ""),
            items: [
                SettingsModel.SectionItem(
                    title: NSLocalizedString("Two-factor authentication", comment: ""),
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
                    title: NSLocalizedString("View your two-factor recovery codes", comment: ""),
                    type: .link,
                    icon: "iconFile",
                    value: "",
                    action: {
                        self.tableViewController?.toTwoFactorRecoveryCodes(action: .regenerateCodes)
                    },
                    visible: settings.twoFactorEnabled
                ),
                SettingsModel.SectionItem(
                    title: NSLocalizedString("Where you are logged in", comment: ""),
                    type: .link,
                    icon: "iconGlobe",
                    value: "",
                    action: { self.tableViewController?.performSegue(withIdentifier: "toAuthApps", sender: nil) },
                    visible: true
                ),
                SettingsModel.SectionItem(
                    title: NSLocalizedString("Link your account", comment: ""),
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
            title: NSLocalizedString("Privacy and safety", comment: ""),
            items: [
                SettingsModel.SectionItem(
                    title: NSLocalizedString("Keep populating history", comment: ""),
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
            title: NSLocalizedString("Support", comment: ""),
            items: [
                SettingsModel.SectionItem(
                    title: NSLocalizedString("About", comment: ""),
                    type: .link,
                    icon: "iconInfo",
                    value: "\(Bundle.main.versionNumber)+\(Bundle.main.buildNumber)",
                    action: { self.tableViewController?.performSegue(withIdentifier: "toAbout", sender: nil) },
                    visible: true
                ),
                SettingsModel.SectionItem(
                    title: NSLocalizedString("Rate put.io on App Store", comment: ""),
                    type: .button,
                    icon: "iconStar",
                    value: "",
                    action: { AppStoreReviewManager.sharedInstance.requestReviewManually() },
                    visible: true
                ),
                SettingsModel.SectionItem(
                    title: NSLocalizedString("Contact us", comment: ""),
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
            title: NSLocalizedString("Danger Zone", comment: ""),
            items: [
                SettingsModel.SectionItem(
                    title: NSLocalizedString("Clear your data", comment: ""),
                    type: .link,
                    icon: "iconRemoveFolder",
                    value: "",
                    action: { self.tableViewController?.performSegue(withIdentifier: "toClearData", sender: nil) },
                    visible: true
                ),
                SettingsModel.SectionItem(
                    title: NSLocalizedString("Destroy your account", comment: ""),
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
                    title: NSLocalizedString("Log out", comment: ""),
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
            return String(
                format: NSLocalizedString("%@ free of %@", comment: ""),
                disk.available.bytesToHumanReadable(),
                disk.size.bytesToHumanReadable()
            )
        }

        return String(
            format: NSLocalizedString("%@ of %@ used", comment: ""),
            disk.used.bytesToHumanReadable(),
            disk.size.bytesToHumanReadable()
        )
    }
}
