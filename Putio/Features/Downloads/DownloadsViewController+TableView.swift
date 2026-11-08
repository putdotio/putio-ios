import AVKit
import UIKit

extension DownloadsViewController {
    func download(at indexPath: IndexPath) -> Download? {
        guard let downloads, downloads.indices.contains(indexPath.row) else { return nil }
        return downloads[indexPath.row]
    }

    func contextualDeleteAction(forRowAtIndexPath indexPath: IndexPath) -> UIContextualAction {
        guard let download = download(at: indexPath),
              let cell = tableView.cellForRow(at: indexPath) else {
            InternalFailurePresenter.log("Unable to access download row \(indexPath.row) for delete action", context: "DownloadsViewController.contextualDeleteAction")
            return UIContextualAction(style: .destructive, title: NSLocalizedString("Delete", comment: "")) { _, _, handler in
                handler(false)
            }
        }

        let item = DownloadDeletionItem(id: download.id, name: download.name, fileType: download.fileType)
        let action = UIContextualAction(style: .destructive, title: NSLocalizedString("Delete", comment: "")) { [weak self] _, _, handler in
            guard let self else { return handler(false) }
            self.confirmDeletion(of: item, from: cell, completion: handler)
        }

        action.backgroundColor = UIColor.Putio.Red.solid
        return action
    }
}

extension DownloadsViewController {
    func confirmDeletion(of item: DownloadDeletionItem, from cell: UITableViewCell, completion: @escaping (Bool) -> Void) {
        let actionSheet = UIAlertController(
            title: String(
                format: NSLocalizedString("Are you sure you want to delete %@?", comment: ""),
                item.name
            ),
            message: nil,
            preferredStyle: .actionSheet
        )

        let deleteButton = UIAlertAction(title: NSLocalizedString("Delete", comment: ""), style: .destructive) { [weak self] _ in
            guard let self else { return completion(false) }
            self.deleteConfirmedDownload(item, completion: completion)
        }

        let cancelButton = UIAlertAction(title: NSLocalizedString("Cancel", comment: ""), style: .cancel) { _ in
            completion(false)
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

        present(actionSheet, animated: true)
    }

    func deleteConfirmedDownload(_ item: DownloadDeletionItem, completion: @escaping (Bool) -> Void) {
        guard isStored(item) else { return completion(true) }

        deleteDownload(item.id, item.fileType) { [weak self] didDelete in
            guard let self else { return completion(didDelete) }
            let isGone = didDelete || !self.isStored(item)
            completion(isGone)
            if !isGone {
                self.presentDeletionFailure(for: [item])
            }
        }
    }

    func isStored(_ item: DownloadDeletionItem) -> Bool {
        !storedItems([item]).isEmpty
    }

    func storedItems(_ items: [DownloadDeletionItem]) -> [DownloadDeletionItem] {
        guard !items.isEmpty, let realm = downloads?.realm else { return items }
        realm.refresh()
        return items.filter { realm.object(ofType: Download.self, forPrimaryKey: $0.id) != nil }
    }
}

extension DownloadsViewController: DownloadsTableViewCellDelegate {
    func downloadCellActionButtonTapped(download: Download) {
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

    func downloadCellSelectionAccessibilityActivated(sender: DownloadsTableViewCell) -> Bool {
        guard tableView.isEditing,
              let indexPath = tableView.indexPath(for: sender),
              tableView(tableView, canEditRowAt: indexPath) else {
            return false
        }

        if tableView.indexPathsForSelectedRows?.contains(indexPath) == true {
            tableView.deselectRow(at: indexPath, animated: false)
            tableView(tableView, didDeselectRowAt: indexPath)
        } else {
            guard tableView(tableView, willSelectRowAt: indexPath) != nil else { return false }
            tableView.selectRow(at: indexPath, animated: false, scrollPosition: .none)
            tableView(tableView, didSelectRowAt: indexPath)
        }

        return true
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
        let download = download(at: indexPath) else {
            InternalFailurePresenter.log("Unable to dequeue DownloadsTableViewCell", context: "DownloadsViewController.cellForRow")
            return UITableViewCell()
        }

        cell.configure(with: download.id)
        cell.delegate = self
        configureSelectionAccessibility(for: cell, download: download)
        return cell
    }
}

extension DownloadsViewController: UITableViewDelegate {
    func tableView(_ tableView: UITableView, canEditRowAt indexPath: IndexPath) -> Bool {
        guard tableView.isEditing else { return true }
        return download(at: indexPath)?.state == .completed
    }

    func tableView(_ tableView: UITableView, willSelectRowAt indexPath: IndexPath) -> IndexPath? {
        guard tableView.isEditing else { return indexPath }
        return download(at: indexPath)?.state == .completed ? indexPath : nil
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        guard let download = download(at: indexPath) else { return }

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
        guard tableView.isEditing, let download = download(at: indexPath) else { return }
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
        guard !tableView.isEditing, download(at: indexPath) != nil else { return nil }
        let actions = [contextualDeleteAction(forRowAtIndexPath: indexPath)]
        let configuration = UISwipeActionsConfiguration(actions: actions)
        configuration.performsFirstActionWithFullSwipe = false
        return configuration
    }
}

extension DownloadsViewController: AVPlayerViewControllerDelegate {
    func playerViewControllerDidStartPictureInPicture(_ playerViewController: AVPlayerViewController) {
        guard let videoPlayerViewController = playerViewController as? VideoPlayerViewController else {
            return InternalFailurePresenter.log("PiP start received for unexpected player controller", context: "DownloadsViewController.pipStart")
        }

        videoPlayerViewController.handlePictureInPictureDidStart()
    }

    func playerViewController(
        _ playerViewController: AVPlayerViewController,
        restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completionHandler: @escaping (Bool) -> Void
    ) {
        guard let videoPlayerViewController = playerViewController as? VideoPlayerViewController else {
            InternalFailurePresenter.log("PiP restore received for unexpected player controller", context: "DownloadsViewController.pipRestore")
            completionHandler(false)
            return
        }

        present(videoPlayerViewController, animated: true) {
            videoPlayerViewController.handlePictureInPictureDidStop()
            completionHandler(true)
        }
    }
}
