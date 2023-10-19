import Foundation
import RealmSwift
import PutioAPI

protocol NextMediaFinderDelegate: AnyObject {
    func didFindNextMedia(nextMedia: MediaPlayerItem)
    func didCannotFindNextMedia()
}

class NextMediaFinder {
    let realm = try! Realm()

    weak var delegate: NextMediaFinderDelegate?

    func findNextMedia(for item: MediaPlayerItem) {
        if item.consumptionType == .offline {
            return findNextMediaFromDownloads(for: item)
        }

        return findNextMediaFromAPI(for: item)
    }

    private func getMappedDownloadType(for item: MediaPlayerItem) -> Download.FileType {
        switch item.fileType {
        case .audio:
            return Download.FileType.audio
        case .video:
            return Download.FileType.video
        }
    }

    private func findNextMediaFromDownloads(for item: MediaPlayerItem) {
        let downloads = realm.objects(Download.self)
            .filter("fileType = %@", getMappedDownloadType(for: item).rawValue)
            .sorted(byKeyPath: "createdAt")

        guard let currentItemIndex = downloads.index(where: { $0.id == item.id }) else { return findNextMediaFromAPI(for: item) }

        let nextItemIndex = currentItemIndex + 1
        guard nextItemIndex < downloads.count else { return findNextMediaFromAPI(for: item) }

        let download = downloads[currentItemIndex + 1]

        var media: MediaPlayerItem

        switch download.fileType {
        case .video:
            guard let url = VideoDownloadManager.sharedInstance.getLocalFileURL(for: download.id) else {
                return findNextMediaFromAPI(for: item)
            }

            media = MediaPlayerItem(download: download, url: url)

        case .audio:
            guard let url = AudioDownloadManager.sharedInstance.getLocalFileURL(for: download.id) else {
                return findNextMediaFromAPI(for: item)
            }

            media = MediaPlayerItem(download: download, url: url)
        }

        media.startFrom = 0
        return onNextMediaFound(nextMedia: media)
    }

    private func getMappedAPIFileType(for item: MediaPlayerItem) -> PutioNextFileType {
        switch item.fileType {
        case .audio:
            return PutioNextFileType.audio
        case .video:
            return PutioNextFileType.video
        }
    }

    private func findNextMediaFromAPI(for item: MediaPlayerItem) {
        api.findNextFile(fileID: item.id, fileType: getMappedAPIFileType(for: item)) { result in
            switch result {
            case .success(let nextFile):
                self.onNextMediaFound(nextMedia: MediaPlayerItem(file: nextFile))

            case .failure(let error):
                log.debug(self.getMappedAPIFileType(for: item).rawValue)
                log.warning(error.type)
                self.onNextMediaCannotFound()
            }
        }
    }

    private func onNextMediaFound(nextMedia: MediaPlayerItem) {
        delegate?.didFindNextMedia(nextMedia: nextMedia)
    }

    private func onNextMediaCannotFound() {
        delegate?.didCannotFindNextMedia()
    }
}
