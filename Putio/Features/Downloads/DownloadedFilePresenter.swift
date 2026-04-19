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
            title: NSLocalizedString("File Unavailable", comment: ""),
            message: NSLocalizedString("We couldn't read this file from the disk. It may be corrupted during the download or auto deleted by the operating system to cleanup disk space.", comment: ""),
            preferredStyle: .alert
        )

        alert.addAction(UIAlertAction(title: NSLocalizedString("Re-download", comment: ""), style: .default, handler: { (_) in
            self.restartDownload(download)
        }))

        alert.addAction(UIAlertAction(title: NSLocalizedString("Close", comment: ""), style: .cancel, handler: nil))

        present(alert, animated: true) {
            self.updateDownloadStateAsNotReachable(download)
        }
    }

    func updateDownloadStateAsNotReachable(_ download: Download) {
        guard let realm = download.realm ?? PutioRealm.open(context: "DownloadedFilePresenter.updateDownloadStateAsNotReachable") else {
            return InternalFailurePresenter.log("Unable to load Realm while marking download as not reachable")
        }

        _ = PutioRealm.write(realm, context: "DownloadedFilePresenter.updateDownloadStateAsNotReachable.write") {
            download.state = .failed
            download.message = NSLocalizedString("File not reachable", comment: "")
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
            message = statusCode == 404
                ? NSLocalizedString("The original version of this file has been deleted from your put.io account.", comment: "")
                : error.localizedDescription
        default:
            message = error.localizedDescription
        }

        let alert = UIAlertController(
            title: NSLocalizedString("Something went wrong", comment: ""),
            message: message,
            preferredStyle: .alert
        )

        alert.addAction(UIAlertAction(title: NSLocalizedString("Delete Download", comment: ""), style: .destructive, handler: { _ in
            if download.fileType == .video {
                VideoDownloadManager.sharedInstance.deleteDownload(id: download.id)
            } else {
                AudioDownloadManager.sharedInstance.deleteDownload(id: download.id)
            }
        }))

        alert.addAction(UIAlertAction(title: NSLocalizedString("Close", comment: ""), style: .cancel, handler: nil))

        present(alert, animated: true)
    }
}
