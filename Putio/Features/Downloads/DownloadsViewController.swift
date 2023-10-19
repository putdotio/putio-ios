import UIKit
import AVKit
import RealmSwift
import StatefulViewController
import Sentry

class DownloadsViewController: UIViewController, DownloadedFilePresenter, StatefulViewController {
    @IBOutlet weak var tableView: UITableView!
    var notificationToken: NotificationToken?
    var downloads: Results<Download> = {
        let realm = try! Realm()
        return realm.objects(Download.self).sorted(byKeyPath: "createdAt")
    }()

    override func viewDidLoad() {
        super.viewDidLoad()

        tableView.dataSource = self
        tableView.delegate = self

        configureStateMachine()
        registerDataObserver()
    }

    func configureStateMachine() {
        let emptyView = DownloadsEmptyStateView.instantiateFromInterfaceBuilder()
        emptyView.delegate = self
        stateMachine.addView(emptyView, forState: "empty")

        if downloads.count == 0 {
            stateMachine.transitionToState(.view("empty"), animated: false, completion: nil)
        }
    }

    func registerDataObserver() {
        notificationToken = downloads.observe({ (change) in
            if self.downloads.count == 0 {
                self.stateMachine.transitionToState(.view("empty"))
            } else {
                self.stateMachine.transitionToState(.none)
            }

            switch change {
            case .initial:
                self.tableView.reloadData()
            case .update(_, let deletions, let insertions, let modifications):
                self.tableView.beginUpdates()
                self.tableView.insertRows(at: insertions.map({ IndexPath(row: $0, section: 0) }), with: .automatic)
                self.tableView.reloadRows(at: modifications.map({ IndexPath(row: $0, section: 0) }), with: .none)
                self.tableView.deleteRows(at: deletions.map({ IndexPath(row: $0, section: 0) }), with: .automatic)
                self.tableView.endUpdates()
            case .error(let error):
                SentrySDK.capture(error: error)
        }})
    }

    deinit {
        notificationToken?.invalidate()
    }

    // MARK: Swipe Actions
    func contextualDeleteAction(forRowAtIndexPath indexPath: IndexPath) -> UIContextualAction {
        let download = downloads[indexPath.row]
        let cell = tableView.cellForRow(at: indexPath)!

        let action = UIContextualAction(style: .destructive, title: "Delete") { (_, _, handler) in
            let actionSheet = UIAlertController(
                title: "Are you sure you want to delete \(download.name)?",
                message: nil,
                preferredStyle: .actionSheet
            )

            let deleteButton = UIAlertAction(title: "Delete", style: .destructive, handler: { (_) in
                if download.fileType == .video {
                    VideoDownloadManager.sharedInstance.deleteDownload(id: download.id)
                } else {
                    AudioDownloadManager.sharedInstance.deleteDownload(id: download.id)
                }

                handler(true)
            })

            let cancelButton = UIAlertAction(title: "Cancel", style: .cancel, handler: { (_) in
                handler(false)
            })

            actionSheet.addAction(deleteButton)
            actionSheet.addAction(cancelButton)
            actionSheet.popoverPresentationController?.sourceView = cell
            actionSheet.popoverPresentationController?.sourceRect = CGRect(x: cell.frame.width + 65, y: 0, width: 80, height: cell.frame.height)

            self.present(actionSheet, animated: true, completion: nil)
        }

        action.backgroundColor = .systemRed

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
        return downloads.count
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "downloadsReuse", for: indexPath) as! DownloadsTableViewCell
        cell.configure(with: downloads[indexPath.row].id)
        cell.delegate = self
        return cell
    }
}

extension DownloadsViewController: UITableViewDelegate {
    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        let download = downloads[indexPath.row]
        tableView.deselectRow(at: indexPath, animated: false)
        guard download.state == .completed else { return }
        presentDownloadedFile(download)
    }

    func tableView(_ tableView: UITableView, trailingSwipeActionsConfigurationForRowAt indexPath: IndexPath) -> UISwipeActionsConfiguration? {
        let actions = [contextualDeleteAction(forRowAtIndexPath: indexPath)]
        let configuration = UISwipeActionsConfiguration(actions: actions)
        configuration.performsFirstActionWithFullSwipe = false
        return configuration
    }
}

extension DownloadsViewController: AVPlayerViewControllerDelegate {
    func playerViewControllerDidStartPictureInPicture(_ playerViewController: AVPlayerViewController) {
        (playerViewController as! VideoPlayerViewController).isPlayingInPictureOnPictureMode = true
    }

    func playerViewController(_ playerViewController: AVPlayerViewController, restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completionHandler: @escaping (Bool) -> Void) {
        present(playerViewController, animated: true) {
            (playerViewController as! VideoPlayerViewController).isPlayingInPictureOnPictureMode = false
            completionHandler(true)
        }
    }
}

extension DownloadsViewController: DownloadsEmptyStateViewDelegate {
    func downloadTutorialButtonTapped() {
        performSegue(withIdentifier: "toDownloadsTutorial", sender: nil)
    }
}
