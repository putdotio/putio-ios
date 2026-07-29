import AVKit
import UIKit

extension DownloadsViewController {
    func contextualDeleteAction(forRowAtIndexPath indexPath: IndexPath) -> UIContextualAction {
        guard let download = downloads?[indexPath.row],
              let cell = tableView.cellForRow(at: indexPath) else {
            InternalFailurePresenter.log("Unable to access download row \(indexPath.row) for delete action")
            return UIContextualAction(style: .destructive, title: NSLocalizedString("Delete", comment: "")) { _, _, handler in
                handler(false)
            }
        }

        let action = UIContextualAction(style: .destructive, title: NSLocalizedString("Delete", comment: "")) { _, _, handler in
            let actionSheet = UIAlertController(
                title: String(
                    format: NSLocalizedString("Are you sure you want to delete %@?", comment: ""),
                    download.name
                ),
                message: nil,
                preferredStyle: .actionSheet
            )

            let deleteButton = UIAlertAction(title: NSLocalizedString("Delete", comment: ""), style: .destructive) { _ in
                let didDelete = self.deleteDownload(download.id, download.fileType)
                handler(didDelete)

                if !didDelete {
                    self.presentDeletionFailure(for: [DownloadDeletionItem(
                        id: download.id,
                        name: download.name,
                        fileType: download.fileType
                    )])
                }
            }

            let cancelButton = UIAlertAction(title: NSLocalizedString("Cancel", comment: ""), style: .cancel) { _ in
                handler(false)
            }

            actionSheet.addAction(deleteButton)
            actionSheet.addAction(cancelButton)
            actionSheet.popoverPresentationController?.sourceView = cell
            actionSheet.popoverPresentationController?.sourceRect = CGRect(
                x: cell.frame.width + 65,
                y: 0,
                width: 80,
                height: cell.frame.height
            )

            self.present(actionSheet, animated: true)
        }

        action.backgroundColor = UIColor.Putio.Red.solid
        return action
    }
}

extension DownloadsViewController: DownloadsTableViewCellDelegate {
    func downloadCellActionButtonTapped(download: Download, sender: DownloadsTableViewCell) {
        switch download.state {
        case .queued, .starting, .active:
            if download.fileType == .audio {
                return AudioDownloadManager.sharedInstance.cancelDownload(id: download.id)
            }

            return VideoDownloadManager.sharedInstance.cancelDownload(id: download.id)

        case .stopped, .failed:
            restartDownload(download)

        case .completed:
            presentDownloadedFile(download)
        }
    }
}

extension DownloadsViewController: UITableViewDataSource {
    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        return downloads?.count ?? 0
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        guard let cell = tableView.dequeueReusableCell(
            withIdentifier: "downloadsReuse",
            for: indexPath
        ) as? DownloadsTableViewCell,
        let download = downloads?[indexPath.row] else {
            InternalFailurePresenter.log("Unable to dequeue DownloadsTableViewCell")
            return UITableViewCell()
        }

        cell.configure(with: download.id)
        cell.delegate = self
        configureSelectionAccessibility(for: cell, download: download)
        return cell
    }
}

extension DownloadsViewController: UITableViewDelegate {
    func tableView(_ tableView: UITableView, willSelectRowAt indexPath: IndexPath) -> IndexPath? {
        guard tableView.isEditing else { return indexPath }
        guard let download = downloads?[indexPath.row], download.state == .completed else {
            return nil
        }
        return indexPath
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        guard let download = downloads?[indexPath.row] else { return }

        if tableView.isEditing {
            selectionState.select(download.id, isCompleted: download.state == .completed)
            updateSelectionUI()
            if let cell = tableView.cellForRow(at: indexPath) as? DownloadsTableViewCell {
                configureSelectionAccessibility(for: cell, download: download)
            }
            return
        }

        tableView.deselectRow(at: indexPath, animated: false)
        guard download.state == .completed else { return }
        presentDownloadedFile(download)
    }

    func tableView(_ tableView: UITableView, didDeselectRowAt indexPath: IndexPath) {
        guard tableView.isEditing, let download = downloads?[indexPath.row] else { return }
        selectionState.deselect(download.id)
        updateSelectionUI()
        if let cell = tableView.cellForRow(at: indexPath) as? DownloadsTableViewCell {
            configureSelectionAccessibility(for: cell, download: download)
        }
    }

    func tableView(
        _ tableView: UITableView,
        trailingSwipeActionsConfigurationForRowAt indexPath: IndexPath
    ) -> UISwipeActionsConfiguration? {
        guard !tableView.isEditing else { return nil }
        let actions = [contextualDeleteAction(forRowAtIndexPath: indexPath)]
        let configuration = UISwipeActionsConfiguration(actions: actions)
        configuration.performsFirstActionWithFullSwipe = false
        return configuration
    }
}

extension DownloadsViewController: AVPlayerViewControllerDelegate {
    func playerViewControllerDidStartPictureInPicture(_ playerViewController: AVPlayerViewController) {
        guard let videoPlayerViewController = playerViewController as? VideoPlayerViewController else {
            return InternalFailurePresenter.log("PiP start received for unexpected player controller")
        }

        videoPlayerViewController.handlePictureInPictureDidStart()
    }

    func playerViewController(
        _ playerViewController: AVPlayerViewController,
        restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completionHandler: @escaping (Bool) -> Void
    ) {
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
