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

struct VideoPlaybackPositionEntry: Codable {
    let position: Int
    let updatedAt: Date
    let lastConfirmedRemotePosition: Int?
    let lastConfirmedRemoteAt: Date?

    var hasPendingRemoteConfirmation: Bool {
        guard let lastConfirmedRemotePosition,
              let lastConfirmedRemoteAt else {
            return true
        }

        return position != lastConfirmedRemotePosition || updatedAt > lastConfirmedRemoteAt
    }
}

final class VideoPlaybackPositionStore {
    static let shared = VideoPlaybackPositionStore()

    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private let userDefaults: UserDefaults
    private static let keyPrefix = "putio.video-playback-position."

    init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
    }

    func entry(for fileID: Int) -> VideoPlaybackPositionEntry? {
        guard let data = userDefaults.data(forKey: key(for: fileID)) else { return nil }
        return try? decoder.decode(VideoPlaybackPositionEntry.self, from: data)
    }

    @discardableResult
    func saveLocalPosition(for fileID: Int, position: Int, at updatedAt: Date = Date()) -> VideoPlaybackPositionEntry {
        let existingEntry = entry(for: fileID)
        let entry = VideoPlaybackPositionEntry(
            position: position,
            updatedAt: updatedAt,
            lastConfirmedRemotePosition: existingEntry?.lastConfirmedRemotePosition,
            lastConfirmedRemoteAt: existingEntry?.lastConfirmedRemoteAt
        )

        persist(entry, for: fileID)
        return entry
    }

    func saveRemoteSnapshot(for fileID: Int, position: Int, observedAt: Date = Date()) {
        persist(
            VideoPlaybackPositionEntry(
                position: position,
                updatedAt: observedAt,
                lastConfirmedRemotePosition: position,
                lastConfirmedRemoteAt: observedAt
            ),
            for: fileID
        )
    }

    func clearAllPositions() {
        for key in userDefaults.dictionaryRepresentation().keys where key.hasPrefix(Self.keyPrefix) {
            userDefaults.removeObject(forKey: key)
        }
    }

    private func persist(_ entry: VideoPlaybackPositionEntry, for fileID: Int) {
        guard let data = try? encoder.encode(entry) else { return }
        userDefaults.set(data, forKey: key(for: fileID))
    }

    private func key(for fileID: Int) -> String {
        return "\(Self.keyPrefix)\(fileID)"
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
