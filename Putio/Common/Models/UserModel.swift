import Foundation
import RealmSwift
import PutioAPI

class User: Object {
    @objc dynamic var id: Int = 0
    @objc dynamic var username: String = ""
    @objc dynamic var mail: String = ""

    @objc dynamic var downloadToken: String = ""
    @objc dynamic var disk: UserDisk?
    @objc dynamic var trashSize: Int64 = 0
    @objc dynamic var settings: UserSettings?
    @objc dynamic var features: UserFeatures?

    convenience init?(account: PutioAccount) {
        self.init()
        self.id = account.id
        self.username = account.username
        self.mail = account.mail
        self.downloadToken = account.downloadToken
        self.disk = UserDisk(disk: account.disk)
        self.trashSize = account.trashSize
        self.settings = UserSettings(settings: account.settings)
        self.features = UserFeatures(features: account.features)
    }

    override static func primaryKey() -> String? {
        return "id"
    }
}

class UserDisk: Object {
    @objc dynamic var available: Int64 = 0
    @objc dynamic var size: Int64 = 0
    @objc dynamic var used: Int64 = 0

    convenience init?(disk: PutioAccount.Disk) {
        self.init()
        self.available = disk.available
        self.size = disk.size
        self.used = disk.used
    }
}

class UserSettings: Object {
    @objc dynamic var routeName: String = ""
    @objc dynamic var suggestNextVideo: Bool = false
    @objc dynamic var rememberVideoTime: Bool = false
    @objc dynamic var historyEnabled: Bool = true
    @objc dynamic var trashEnabled: Bool = true
    @objc dynamic var sortBy: String = ""
    @objc dynamic var showOptimisticUsage: Bool = false
    @objc dynamic var twoFactorEnabled: Bool = false

    convenience init?(settings: PutioAccount.Settings) {
        self.init()
        self.sortBy = settings.sortBy
        self.routeName = settings.routeName
        self.suggestNextVideo = settings.suggestNextVideo
        self.rememberVideoTime = settings.rememberVideoTime
        self.historyEnabled = settings.historyEnabled
        self.trashEnabled = settings.trashEnabled
        self.showOptimisticUsage = settings.showOptimisticUsage
        self.twoFactorEnabled = settings.twoFactorEnabled
    }
}

class UserFeatures: Object {
    @objc dynamic var downloadVideosAsMp4: Bool = false
    @objc dynamic var debugChromecast: Bool = false
    @objc dynamic var playHLSOnChromecast: Bool = false

    convenience init?(features: [String: Any]) {
        self.init()

        if let debugChromecast = features["ios_debug_chromecast"] {
            self.debugChromecast = debugChromecast as! Bool
        } else {
            self.debugChromecast = false
        }

        if let playHLSOnChromecast = features["ios_play_hls_on_chromecast"] {
            self.playHLSOnChromecast = playHLSOnChromecast as! Bool
        } else {
            self.playHLSOnChromecast = false
        }
    }
}
