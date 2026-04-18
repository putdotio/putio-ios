import Foundation
import RealmSwift
import PutioSDK

class Download: Object {
    @objc enum State: Int {
        case queued, starting, active, completed, failed, stopped
    }

    @objc enum FileType: Int {
        case video, audio
    }

    @objc dynamic var id: Int = 0
    @objc dynamic var name: String = ""
    @objc dynamic var size: Int64 = 0
    @objc dynamic var progress: String = "0"
    @objc dynamic var stateRaw: Int = State.queued.rawValue
    @objc dynamic var createdAt: Date?
    @objc dynamic var completedAt: Date?
    @objc dynamic var startFrom: Int = 0
    @objc dynamic var message: String = ""
    @objc dynamic var fileTypeRaw: Int = FileType.video.rawValue

    // TO BE DEPRECATED
    @objc dynamic var url: String = ""
    @objc dynamic var path: String = ""

    convenience init?(file: PutioFile, url: String) {
        self.init()
        self.id = file.id
        self.name = file.name
        self.size = file.hasMp4 ? file.mp4Size : file.size
        self.completedAt = nil
        self.createdAt = Date()

        // TO BE DEPRECATED
        self.url = url

        switch file.type {
        case .audio:
            self.fileType = .audio
        default:
            self.fileType = .video
        }
    }

    var state: State {
        get { State(rawValue: stateRaw) ?? .queued }
        set { stateRaw = newValue.rawValue }
    }

    var fileType: FileType {
        get { FileType(rawValue: fileTypeRaw) ?? .video }
        set { fileTypeRaw = newValue.rawValue }
    }

    override static func primaryKey() -> String? {
        return "id"
    }
}
