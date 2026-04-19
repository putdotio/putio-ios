import UIKit
import AVKit
import PutioSDK

protocol FilePresenter: VideoConversionPresenter {}

extension FilePresenter where Self: UIViewController {
    func presentFile(_ file: PutioFile) {
        switch file.type {
        case .folder:
            toFolder(file: file)

        case .video:
            if ChromecastManager.sharedInstance.isActive() {
                return toChromecast(file: file)
            }

            if file.needConvert {
                return presentVideoConversionView(for: file, intention: .play)
            }

            toVideo(file: file)

        case .audio:
            toAudio(file: file)

        case .image:
            toImage(file: file)

        case .pdf:
            toPDF(file: file)

        default:
            let alertController = UIAlertController(
                title: NSLocalizedString("Unsupported File", comment: ""),
                message: NSLocalizedString("We're unable to show this kind of file in the app yet.", comment: ""),
                preferredStyle: .alert
            )
            alertController.addAction(UIAlertAction(title: NSLocalizedString("Close", comment: ""), style: .cancel, handler: nil))
            present(alertController, animated: true, completion: nil)
        }
    }

    private func toFolder(file: PutioFile) {
        let filesVC = storyboard?.instantiateViewController(withIdentifier: "Files") as! FilesViewController
        filesVC.viewModel.file = file
        filesVC.navigationItem.title = file.name

        // Share the same bar button items so UIKit doesn't cross-fade during push
        if let selfVC = self as? FilesViewController {
            filesVC.fileActionsButton = selfVC.fileActionsButton
            filesVC.chromecastButton = selfVC.chromecastButton
            filesVC.navigationItem.rightBarButtonItems = navigationItem.rightBarButtonItems
        }

        navigationController?.pushViewController(filesVC, animated: true)
    }

    private func toVideo(file: PutioFile) {
        MediaPlaybackManager.sharedInstance.play(MediaPlayerItem(file: file), sourceViewController: self)
    }

    private func toAudio(file: PutioFile) {
        MediaPlaybackManager.sharedInstance.play(MediaPlayerItem(file: file), sourceViewController: self)
    }

    private func toImage(file: PutioFile) {
        let imageVC = UIStoryboard(name: "Image", bundle: nil).instantiateViewController(withIdentifier: "ImageVC") as! ImageViewController
        imageVC.file = file
        navigationController?.pushViewController(imageVC, animated: true)
    }

    private func toPDF(file: PutioFile) {
        let pdfVC = UIStoryboard(name: "PDF", bundle: nil).instantiateViewController(withIdentifier: "PDFVC") as! PDFViewController
        pdfVC.file = file
        navigationController?.pushViewController(pdfVC, animated: true)
    }

    private func toChromecast(file: PutioFile) {
        return ChromecastManager.sharedInstance.castVideo(fileID: file.id, completion: { (_, error) in
            if let error = error {
                return self.handleChromecastError(for: file, error: error)
            }
        })
    }

    private func handleChromecastError(for file: PutioFile, error: ChromecastManager.CastError) {
        switch error.reason {
        case .fileNeedsConvert:
            presentVideoConversionView(for: file, intention: .play)
        default:
            let alertController = UIAlertController(
                title: NSLocalizedString("Casting Error", comment: ""),
                message: NSLocalizedString("An error occurred while trying to cast this file. Please try again.", comment: ""),
                preferredStyle: .alert
            )
            alertController.addAction(UIAlertAction(title: NSLocalizedString("Close", comment: ""), style: .destructive, handler: nil))
            present(alertController, animated: true, completion: nil)
        }
    }
}
