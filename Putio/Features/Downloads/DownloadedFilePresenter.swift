import UIKit
import AVKit
import RealmSwift
import PutioSDK

protocol DownloadedFilePresenter {}

extension DownloadedFilePresenter where Self: UIViewController {
    func presentDownloadedFile(_ download: Download) {
        switch download.fileType {
        case .video:
            guard let url = VideoDownloadManager.sharedInstance.getLocalFileURL(for: download.id) else {
                return presentFileNotReachableMessage(for: download)
            }

            MediaPlaybackManager.sharedInstance.play(MediaPlayerItem(download: download, url: url), sourceViewController: self)

        case .audio:
            guard let url = AudioDownloadManager.sharedInstance.getLocalFileURL(for: download.id) else {
                return presentFileNotReachableMessage(for: download)
            }

            MediaPlaybackManager.sharedInstance.play(MediaPlayerItem(download: download, url: url), sourceViewController: self)
        }
    }

    func presentFileNotReachableMessage(for download: Download) {
        let alert = UIAlertController(
            title: "File Unavailable",
            message: "We couldn't read this file from the disk. It may be corrupted during the download or auto deleted by the operating system to cleanup disk space.",
            preferredStyle: .alert
        )

        alert.addAction(UIAlertAction(title: "Re-download", style: .default, handler: { (_) in
            self.restartDownload(download)
        }))

        alert.addAction(UIAlertAction(title: "Close", style: .cancel, handler: nil))

        present(alert, animated: true) {
            self.updateDownloadStateAsNotReachable(download)
        }
    }

    func updateDownloadStateAsNotReachable(_ download: Download) {
        let realm = try! Realm()

        try! realm.write {
            download.state = .failed
            download.message = "File not reachable"
        }
    }

    func restartDownload(_ download: Download) {
        api.getFile(fileID: download.id) { result in
            switch result {
            case .success:
                switch download.fileType {
                case .video:
                    VideoDownloadManager.sharedInstance.restartDownload(id: download.id)
                case .audio:
                    AudioDownloadManager.sharedInstance.restartDownload(id: download.id)
                }

            case .failure(let error):
                return self.presentRestartDownloadFailureMessage(for: download, with: error)
            }
        }
    }

    func presentRestartDownloadFailureMessage(for download: Download, with error: PutioSDKError) {
        var message: String

        switch error.type {
        case .httpError(let statusCode, _):
            message = statusCode == 404 ? "The original version of this file has been deleted from your put.io account." : error.localizedDescription
        default:
            message = error.localizedDescription
        }

        let alert = UIAlertController(
            title: "Something went wrong",
            message: message,
            preferredStyle: .alert
        )

        alert.addAction(UIAlertAction(title: "Delete Download", style: .destructive, handler: { _ in
            if download.fileType == .video {
                VideoDownloadManager.sharedInstance.deleteDownload(id: download.id)
            } else {
                AudioDownloadManager.sharedInstance.deleteDownload(id: download.id)
            }
        }))

        alert.addAction(UIAlertAction(title: "Close", style: .cancel, handler: nil))

        present(alert, animated: true)
    }
}
