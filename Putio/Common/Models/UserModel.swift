import Foundation
import RealmSwift
import PutioSDK
import SwiftyJSON

class User: Object {
    @objc dynamic var id: Int = 0
    @objc dynamic var username: String = ""
    @objc dynamic var mail: String = ""

    @objc dynamic var downloadToken: String = ""
    @objc dynamic var disk: UserDisk?
    @objc dynamic var trashSize: Int64 = 0
    @objc dynamic var settings: UserSettings?

    convenience init?(account: PutioAccount) {
        self.init()
        self.id = account.id
        self.username = account.username
        self.mail = account.mail
        self.downloadToken = account.downloadToken
        self.disk = UserDisk(disk: account.disk)
        self.trashSize = account.trashSize
        self.settings = UserSettings(settings: account.settings)
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
    @objc dynamic var hideSubtitles: Bool = false
    @objc dynamic var dontAutoSelectSubtitles: Bool = false

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
        self.hideSubtitles = settings.hideSubtitles
        self.dontAutoSelectSubtitles = settings.dontAutoSelectSubtitles
    }
}

class UserConfig: Object {
    @objc dynamic var chromecastPlaybackType: String = "hls"

    convenience init?(json: JSON) {
        self.init()

        let chromecastPlaybackType = json["chromecast_playback_type"].stringValue

        if chromecastPlaybackType.isEmpty || (chromecastPlaybackType != "hls" && chromecastPlaybackType != "mp4") {
            self.chromecastPlaybackType = "hls"
        } else {
            self.chromecastPlaybackType = chromecastPlaybackType
        }
    }
}
