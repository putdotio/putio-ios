import UIKit
import RealmSwift
import StatefulViewController
import Sentry

class DownloadsViewController: UIViewController, DownloadedFilePresenter, StatefulViewController {
    @IBOutlet weak var tableView: UITableView!
    var notificationToken: NotificationToken?
    var tutorialButton: UIButton?
    var selectButton: UIBarButtonItem?
    var editingToolbar: UIToolbar?
    var bulkDeleteButton: UIBarButtonItem?
    var selectionState = DownloadsSelectionState()
    var isDeletingSelectedDownloads = false
    var deleteDownload: (Int, Download.FileType) -> Bool = { id, fileType in
        switch fileType {
        case .video:
            return VideoDownloadManager.sharedInstance.deleteDownload(id: id)
        case .audio:
            return AudioDownloadManager.sharedInstance.deleteDownload(id: id)
        }
    }

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

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        updateTableInsets()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        if tableView.isEditing {
            updateSelectionUI()
        } else {
            navigationItem.title = NSLocalizedString("Downloads", comment: "")
        }
        PutioRealm.enrichPlaceholderDownloads()
    }

    func configureAppearance() {
        tableView.accessibilityIdentifier = "putio-downloads-table"
        tableView.backgroundColor = UIColor.Putio.Surface.appBg
        tableView.contentInsetAdjustmentBehavior = .automatic
        tableView.tableHeaderView = UIView(
            frame: CGRect(x: 0, y: 0, width: 0, height: CGFloat.leastNormalMagnitude)
        )
        tableView.allowsMultipleSelectionDuringEditing = true

        configureEditingToolbar()
        configureNavigationBarButtons()
    }

    func configureNavigationBarButtons() {
        let button = UIButton(type: .system)
        var configuration = UIButton.Configuration.plain()
        configuration.baseForegroundColor = UIColor.Putio.Yellow.textSecondary
        configuration.contentInsets = NSDirectionalEdgeInsets(top: 8, leading: 8, bottom: 8, trailing: 8)
        button.configuration = configuration
        button.accessibilityLabel = NSLocalizedString("Downloads tutorial", comment: "")
        button.addTarget(self, action: #selector(tutorialButtonTapped), for: .touchUpInside)
        button.setImage(PutioIcon.info.image(pointSize: 20), for: .normal)

        tutorialButton = button
        selectButton = UIBarButtonItem(
            title: NSLocalizedString("Select", comment: ""),
            style: .plain,
            target: self,
            action: #selector(startSelectingDownloads)
        )
        selectButton?.accessibilityLabel = NSLocalizedString("Select completed downloads", comment: "")
        navigationItem.rightBarButtonItems = [
            UIBarButtonItem(customView: button),
            selectButton
        ].compactMap { $0 }
        updateSelectionAvailability()
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

        notificationToken = downloads.observe { change in
            let downloadCount = self.downloads?.count ?? 0

            if downloadCount == 0 && !PutioRealm.needsDownloadRecovery {
                self.stateMachine.transitionToState(.view("empty"))
            } else if downloadCount > 0 {
                self.stateMachine.transitionToState(.none)
            }
            self.reconcileSelectionAfterDownloadsChange()
            self.updateSelectionAvailability()

            switch change {
            case .initial:
                self.tableView.reloadData()
            case .update(_, let deletions, let insertions, let modifications):
                self.tableView.beginUpdates()
                self.tableView.insertRows(
                    at: insertions.map { IndexPath(row: $0, section: 0) },
                    with: .automatic
                )
                self.tableView.deleteRows(
                    at: deletions.map { IndexPath(row: $0, section: 0) },
                    with: .automatic
                )
                self.tableView.endUpdates()
                for index in modifications {
                    let indexPath = IndexPath(row: index, section: 0)
                    if let cell = self.tableView.cellForRow(at: indexPath) as? DownloadsTableViewCell {
                        guard let download = self.downloads?[index] else { continue }
                        cell.configure(with: download.id)
                        self.configureSelectionAccessibility(for: cell, download: download)
                    }
                }
            case .error(let error):
                SentrySDK.capture(error: error)
            }

            self.restoreSelectedRows()
        }
    }

    deinit {
        notificationToken?.invalidate()
    }

    @objc func tutorialButtonTapped() {
        performSegue(withIdentifier: "toDownloadsTutorial", sender: nil)
    }
}

extension DownloadsViewController: DownloadsEmptyStateViewDelegate {
    func downloadTutorialButtonTapped() {
        performSegue(withIdentifier: "toDownloadsTutorial", sender: nil)
    }
}

// MARK: - Recovery View

final class DownloadsRecoveryView: UIView {
    var onRestore: (() -> Void)?

    private let restoreButton: UIButton = {
        let button = UIButton(type: .system)
        var configuration = UIButton.Configuration.filled()
        configuration.title = NSLocalizedString("Restore Downloads", comment: "")
        configuration.baseForegroundColor = .black
        configuration.baseBackgroundColor = UIColor.Putio.Yellow.solid
        configuration.cornerStyle = .medium
        configuration.contentInsets = NSDirectionalEdgeInsets(top: 14, leading: 32, bottom: 14, trailing: 32)
        configuration.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { incoming in
            var outgoing = incoming
            outgoing.font = BrandTypography.fontIfAvailable(.h4)
                ?? .preferredFont(forTextStyle: .headline)
            return outgoing
        }
        button.configuration = configuration
        return button
    }()

    private let spinner: UIActivityIndicatorView = {
        let spinner = UIActivityIndicatorView(style: .medium)
        spinner.color = UIColor.Putio.Neutral.text
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
        backgroundColor = UIColor.Putio.Surface.appBg
        autoresizingMask = [.flexibleWidth, .flexibleHeight]

        let titleLabel = UILabel()
        titleLabel.text = NSLocalizedString("Restore Your Downloads", comment: "")
        titleLabel.textColor = UIColor.Putio.Neutral.text
        titleLabel.textAlignment = .center
        titleLabel.font = .preferredFont(forTextStyle: .title1)
        titleLabel.adjustsFontForContentSizeCategory = true
        // Upgrades to the brand h2 role (font + tracking + line height) when the
        // licensed faces are present; a no-op that keeps the system font above
        // otherwise. Called after text/colour/alignment so they are preserved.
        titleLabel.applyBrandStyle(.h2)

        let bodyLabel = UILabel()
        bodyLabel.text = NSLocalizedString("Your files are still on this device but need to be restored after an app update.\n\nA stable internet connection is recommended.", comment: "")
        bodyLabel.textColor = UIColor.Putio.Neutral.textSecondary
        bodyLabel.textAlignment = .center
        bodyLabel.numberOfLines = 0
        bodyLabel.font = .preferredFont(forTextStyle: .body)
        bodyLabel.adjustsFontForContentSizeCategory = true
        bodyLabel.applyBrandStyle(.body)

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
        restoreButton.setTitle(NSLocalizedString("Restoring...", comment: ""), for: .normal)
        spinner.startAnimating()
        onRestore?()
    }
}
