import Foundation
import PutioSDK

struct MediaPlayerItem {
    enum ConsumptionType: String {
        case online = "ONLINE", offline = "OFFLINE"
    }

    enum FileType {
        case audio, video
    }

    var id: Int
    var name: String
    var url: URL
    var fileType: FileType
    var consumptionType: ConsumptionType
    var startFrom: Int

    init(id: Int, name: String, url: URL, fileType: FileType, consumptionType: ConsumptionType, startFrom: Int = 0) {
        self.id = id
        self.name = name
        self.url = url
        self.fileType = fileType
        self.consumptionType = consumptionType
        self.startFrom = startFrom
    }

    init(download: Download, url: URL) {
        self.id = download.id
        self.name = download.name
        self.url = url
        self.fileType = download.fileType == Download.self.FileType.video ? .video : .audio
        self.consumptionType = .offline
        self.startFrom = download.startFrom
    }

    init(file: PutioFile) {
        self.id = file.id
        self.name = file.name
        self.url = PutioE2EPlaybackAsset.url(for: file)
            ?? (file.type == PutioFileType.video ? file.getHlsStreamURL(token: api.config.token) : file.getAudioStreamURL(token: api.config.token))
        self.fileType = file.type == PutioFileType.video ? .video : .audio
        self.consumptionType = .online
        self.startFrom = file.startFrom
    }

    init(file: PutioNextFile) {
        self.id = file.id
        self.name = file.name
        self.url = file.getStreamURL(token: api.config.token)
        self.fileType = file.type == PutioNextFileType.video ? .video : .audio
        self.consumptionType = .online
        self.startFrom = 0
    }
}

private enum PutioE2EPlaybackAsset {
    static func url(for file: PutioFile) -> URL? {
        #if DEBUG
        guard ProcessInfo.processInfo.environment["PUTIO_E2E_MOCK_API"] == "1" else {
            return nil
        }
        guard file.type == PutioFileType.video else {
            return nil
        }

        return Bundle.main.url(forResource: "downloadsTutorial", withExtension: "mov")
        #else
        return nil
        #endif
    }
}
