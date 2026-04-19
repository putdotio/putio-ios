import UIKit
import AVKit
import PutioSDK

extension FilesViewController {
    func openInVLC(_ file: PutioFile) {
        guard let vlcURL = URL(string: "vlc://") else {
            return InternalFailurePresenter.logAndPresent(on: self, logMessage: "Unable to construct VLC URL scheme")
        }

        if UIApplication.shared.canOpenURL(vlcURL) {
            let loadingAlert = UIAlertController(
                title: NSLocalizedString("Processing...", comment: ""),
                message: "",
                preferredStyle: .alert
            )
            present(loadingAlert, animated: true)

            api.getFile(fileID: file.id) { result in
                loadingAlert.dismiss(animated: true) {
                    switch result {
                    case .success(let file):
                        let streamURLString = file.type == .video
                            ? file.streamURL
                            : file.getAudioStreamURL(token: api.config.token).absoluteString

                        guard let destinationURL = URL(string: "vlc://\(streamURLString)") else {
                            return InternalFailurePresenter.logAndPresent(
                                on: self,
                                logMessage: "Unable to construct VLC destination URL for file \(file.id)"
                            )
                        }

                        UIApplication.shared.open(destinationURL, options: [:], completionHandler: nil)

                    case .failure(let error):
                        let errorAlert = UIAlertController(
                            title: NSLocalizedString("Oops, an error occurred :(", comment: ""),
                            message: error.message,
                            preferredStyle: .alert
                        )

                        errorAlert.addAction(UIAlertAction(title: NSLocalizedString("Close", comment: ""), style: .cancel))
                        self.present(errorAlert, animated: true)
                    }
                }
            }
        } else {
            guard let appStoreURL = URL(string: "https://apps.apple.com/app/vlc-for-mobile/id650377962") else {
                return InternalFailurePresenter.logAndPresent(on: self, logMessage: "Unable to construct VLC App Store URL")
            }

            UIApplication.shared.open(appStoreURL, options: [:], completionHandler: nil)
        }
    }
}

extension FilesViewController: AVPlayerViewControllerDelegate {
    func playerViewControllerDidStartPictureInPicture(_ playerViewController: AVPlayerViewController) {
        guard let videoPlayerViewController = playerViewController as? VideoPlayerViewController else {
            return InternalFailurePresenter.log("PiP start received for unexpected player controller")
        }

        videoPlayerViewController.handlePictureInPictureDidStart()
    }

    func playerViewController(_ playerViewController: AVPlayerViewController, restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completionHandler: @escaping (Bool) -> Void) {
        guard let videoPlayerViewController = playerViewController as? VideoPlayerViewController else {
            InternalFailurePresenter.log("PiP restore received for unexpected player controller")
            completionHandler(false)
            return
        }

        present(videoPlayerViewController, animated: true) {
            videoPlayerViewController.handlePictureInPictureDidStop()
            completionHandler(true)
        }
    }
}

extension FilesViewController: MoveFilesViewControllerDelegate {
    func moveFilesCompleted(movedTo: PutioFile) {
        stopEditing()
        fetchData()
    }

    func moveFilesCancelled() {
        stopEditing()
        fetchData()
    }
}

extension FilesViewController: VideoConversionViewControllerDelegate {
    func videoConversionFinished(for file: PutioFile, intention: VideoConversionIntention) {
        switch intention {
        case .download:
            VideoDownloadManager.sharedInstance.createDownload(from: file)
        case .play:
            presentFile(file)
        }
    }

    func videoConversionControllerDismissedBeforeFinish() {}
}
