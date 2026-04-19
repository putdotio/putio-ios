import UIKit
import AVKit
import RealmSwift
import StatefulViewController
import Sentry

class DownloadsViewController: UIViewController, DownloadedFilePresenter, StatefulViewController {
    @IBOutlet weak var tableView: UITableView!
    var notificationToken: NotificationToken?
    var tutorialButton: UIButton?
    lazy var downloads: Results<Download>? = {
        guard let realm = PutioRealm.open(context: "DownloadsViewController.downloads") else {
            InternalFailurePresenter.log("Unable to load downloads collection")
            return nil
        }

        return realm.objects(Download.self).sorted(byKeyPath: "createdAt")
    }()

    override func viewDidLoad() {
        super.viewDidLoad()

        tableView.dataSource = self
        tableView.delegate = self

        configureAppearance()
        configureStateMachine()
        registerDataObserver()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        navigationItem.title = "Downloads"
        PutioRealm.enrichPlaceholderDownloads()
    }

    func configureAppearance() {
        tableView.backgroundColor = UIColor.Putio.background
        tableView.contentInsetAdjustmentBehavior = .automatic
        tableView.tableHeaderView = UIView(frame: CGRect(x: 0, y: 0, width: 0, height: CGFloat.leastNormalMagnitude))

        configureNavigationBarButton()
    }

    func configureNavigationBarButton() {
        let button = UIButton(type: .system)
        var configuration = UIButton.Configuration.plain()
        configuration.baseForegroundColor = UIColor.Putio.yellow
        configuration.contentInsets = NSDirectionalEdgeInsets(top: 8, leading: 8, bottom: 8, trailing: 8)
        button.configuration = configuration
        button.accessibilityLabel = "Downloads tutorial"
        button.addTarget(self, action: #selector(tutorialButtonTapped), for: .touchUpInside)

        if let image = UIImage(named: "iconInfo") {
            button.setImage(image.withRenderingMode(.alwaysTemplate), for: .normal)
        } else {
            button.setImage(UIImage(systemName: "info.circle"), for: .normal)
        }

        tutorialButton = button
        navigationItem.rightBarButtonItem = UIBarButtonItem(customView: button)
    }

    func configureStateMachine() {
        let emptyView = DownloadsEmptyStateView.instantiateFromInterfaceBuilder()
        emptyView.delegate = self
        stateMachine.addView(emptyView, forState: "empty")

        if PutioRealm.needsDownloadRecovery {
            let recoveryView = DownloadsRecoveryView()
            recoveryView.onRestore = { [weak self] in self?.runRecovery() }
            stateMachine.addView(recoveryView, forState: "recovery")
            stateMachine.transitionToState(.view("recovery"), animated: false, completion: nil)
        } else if (downloads?.count ?? 0) == 0 {
            stateMachine.transitionToState(.view("empty"), animated: false, completion: nil)
        }
    }

    func runRecovery() {
        PutioRealm.recoverDownloadsIfNeeded()

        if (downloads?.count ?? 0) == 0 {
            stateMachine.transitionToState(.view("empty"))
        } else {
            stateMachine.transitionToState(.none)
        }
    }

    func registerDataObserver() {
        guard let downloads else {
            stateMachine.transitionToState(.view("empty"))
            return
        }

        notificationToken = downloads.observe({ change in
            let downloadCount = self.downloads?.count ?? 0

            if downloadCount == 0 && !PutioRealm.needsDownloadRecovery {
                self.stateMachine.transitionToState(.view("empty"))
            } else if downloadCount > 0 {
                self.stateMachine.transitionToState(.none)
            }

            switch change {
            case .initial:
                self.tableView.reloadData()
            case .update(_, let deletions, let insertions, let modifications):
                self.tableView.beginUpdates()
                self.tableView.insertRows(at: insertions.map({ IndexPath(row: $0, section: 0) }), with: .automatic)
                self.tableView.deleteRows(at: deletions.map({ IndexPath(row: $0, section: 0) }), with: .automatic)
                self.tableView.endUpdates()
                for index in modifications {
                    let indexPath = IndexPath(row: index, section: 0)
                    if let cell = self.tableView.cellForRow(at: indexPath) as? DownloadsTableViewCell {
                        guard let download = self.downloads?[index] else { continue }
                        cell.configure(with: download.id)
                    }
                }
            case .error(let error):
                SentrySDK.capture(error: error)
            }
        })
    }

    deinit {
        notificationToken?.invalidate()
    }

    @objc func tutorialButtonTapped() {
        performSegue(withIdentifier: "toDownloadsTutorial", sender: nil)
    }

    // MARK: Swipe Actions
    func contextualDeleteAction(forRowAtIndexPath indexPath: IndexPath) -> UIContextualAction {
        guard let download = downloads?[indexPath.row],
              let cell = tableView.cellForRow(at: indexPath) else {
            InternalFailurePresenter.log("Unable to access download row \(indexPath.row) for delete action")
            return UIContextualAction(style: .destructive, title: "Delete") { _, _, handler in
                handler(false)
            }
        }

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
        return downloads?.count ?? 0
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        guard let cell = tableView.dequeueReusableCell(withIdentifier: "downloadsReuse", for: indexPath) as? DownloadsTableViewCell,
              let download = downloads?[indexPath.row] else {
            InternalFailurePresenter.log("Unable to dequeue DownloadsTableViewCell")
            return UITableViewCell()
        }

        cell.configure(with: download.id)
        cell.delegate = self
        return cell
    }
}

extension DownloadsViewController: UITableViewDelegate {
    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        guard let download = downloads?[indexPath.row] else { return }
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

extension DownloadsViewController: DownloadsEmptyStateViewDelegate {
    func downloadTutorialButtonTapped() {
        performSegue(withIdentifier: "toDownloadsTutorial", sender: nil)
    }
}

// MARK: - Recovery View

class DownloadsRecoveryView: UIView {
    var onRestore: (() -> Void)?

    private let restoreButton: UIButton = {
        let button = UIButton(type: .system)
        var configuration = UIButton.Configuration.filled()
        configuration.title = "Restore Downloads"
        configuration.baseForegroundColor = .black
        configuration.baseBackgroundColor = UIColor.Putio.yellow
        configuration.cornerStyle = .medium
        configuration.contentInsets = NSDirectionalEdgeInsets(top: 14, leading: 32, bottom: 14, trailing: 32)
        configuration.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { incoming in
            var outgoing = incoming
            outgoing.font = .preferredFont(forTextStyle: .headline)
            return outgoing
        }
        button.configuration = configuration
        return button
    }()

    private let spinner: UIActivityIndicatorView = {
        let spinner = UIActivityIndicatorView(style: .medium)
        spinner.color = .white
        spinner.hidesWhenStopped = true
        return spinner
    }()

    override init(frame: CGRect) {
        super.init(frame: frame)
        setup()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }

    private func setup() {
        backgroundColor = UIColor.Putio.background
        autoresizingMask = [.flexibleWidth, .flexibleHeight]

        let titleLabel = UILabel()
        titleLabel.text = "Restore Your Downloads"
        titleLabel.font = .preferredFont(forTextStyle: .title1)
        titleLabel.textColor = .white
        titleLabel.textAlignment = .center

        let bodyLabel = UILabel()
        bodyLabel.text = "Your files are still on this device but need to be restored after an app update.\n\nA stable internet connection is recommended."
        bodyLabel.font = .preferredFont(forTextStyle: .body)
        bodyLabel.textColor = .lightGray
        bodyLabel.textAlignment = .center
        bodyLabel.numberOfLines = 0

        restoreButton.addTarget(self, action: #selector(restoreTapped), for: .touchUpInside)

        let stack = UIStackView(arrangedSubviews: [titleLabel, bodyLabel, restoreButton, spinner])
        stack.axis = .vertical
        stack.alignment = .center
        stack.spacing = 16
        stack.setCustomSpacing(24, after: bodyLabel)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        NSLayoutConstraint.activate([
            stack.centerYAnchor.constraint(equalTo: centerYAnchor, constant: -20),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 32),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -32)
        ])
    }

    @objc private func restoreTapped() {
        restoreButton.isEnabled = false
        restoreButton.setTitle("Restoring...", for: .normal)
        spinner.startAnimating()
        onRestore?()
    }
}
