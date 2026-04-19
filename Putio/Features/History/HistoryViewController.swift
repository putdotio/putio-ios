import UIKit
import AVKit
import StatefulViewController
import PutioSDK

class HistoryViewController: UIViewController, FilePresenter, StatefulViewController {
    var viewModel: HistoryViewModel = HistoryViewModel()

    @IBOutlet weak var clearAllButton: UIBarButtonItem!
    @IBOutlet weak var tableView: UITableView!
    var clearAllCustomButton: UIButton?

    override func viewDidLoad() {
        super.viewDidLoad()

        configureAppearance()
        configureStateMachine()

        tableView.dataSource = self
        tableView.delegate = self
        tableView.refreshControl = UIRefreshControl()
        tableView.refreshControl?.transform = CGAffineTransform(scaleX: 0.75, y: 0.75)
        tableView.refreshControl?.tintColor = UIColor.lightGray
        tableView.refreshControl?.addTarget(self, action: #selector(refresh), for: .valueChanged)

        viewModel.delegate = self

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(onNetworkReachabilityChanged),
            name: NetworkReachability.NOTIFICATION,
            object: nil
        )
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        navigationItem.title = NSLocalizedString("History", comment: "")
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)

        switch viewModel.state {
        case .idle, .empty:
            viewModel.fetchEvents()
        default:
            break
        }
    }

    @objc func onNetworkReachabilityChanged() {
        viewModel.fetchEvents()
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
        configuration.title = NSLocalizedString("Clear", comment: "")
        configuration.baseForegroundColor = UIColor.Putio.yellow
        configuration.contentInsets = NSDirectionalEdgeInsets(top: 6, leading: 12, bottom: 6, trailing: 12)
        configuration.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { incoming in
            var outgoing = incoming
            outgoing.font = UIFont.systemFont(ofSize: 14, weight: .semibold)
            return outgoing
        }
        button.configuration = configuration
        button.addTarget(self, action: #selector(clearAllButtonTapped(_:)), for: .touchUpInside)
        clearAllCustomButton = button
        navigationItem.rightBarButtonItem = UIBarButtonItem(customView: button)
        setClearAllButtonEnabled(false)
    }

    func setClearAllButtonEnabled(_ isEnabled: Bool) {
        clearAllCustomButton?.isEnabled = isEnabled
        clearAllCustomButton?.alpha = isEnabled ? 1 : 0.45
        clearAllCustomButton?.configuration?.baseForegroundColor = isEnabled ? UIColor.Putio.yellow : UIColor.Putio.listSubtitle
    }

    func configureStateMachine() {
        let loaderView = LoaderView.instantiateFromInterfaceBuilder()
        stateMachine.addView(loaderView, forState: "loading")

        let emptyView = EmptyStateView.instantiateFromInterfaceBuilder()
        emptyView.configure(
            heading: NSLocalizedString("Your history is empty", comment: ""),
            description: NSLocalizedString("There will be information when things start happening.", comment: "")
        )
        stateMachine.addView(emptyView, forState: "empty")

        let offlineStatusView = OfflineStatusView.instantiateFromInterfaceBuilder()
        stateMachine.addView(offlineStatusView, forState: "offline")
    }

    // MARK: Actions
    @objc func refresh() {
        viewModel.refetchEvents()
    }

    @IBAction func clearAllButtonTapped(_ sender: Any) {
        let actionSheet = UIAlertController(
            title: NSLocalizedString("Are you sure?", comment: ""),
            message: nil,
            preferredStyle: .actionSheet
        )

        let confirmButton = UIAlertAction(title: NSLocalizedString("Clear", comment: ""), style: .destructive, handler: { (_) in
            self.viewModel.removeAllEvents()
        })

        let cancelButton = UIAlertAction(title: NSLocalizedString("Cancel", comment: ""), style: .cancel, handler: nil)

        actionSheet.addAction(confirmButton)
        actionSheet.addAction(cancelButton)
        actionSheet.popoverPresentationController?.barButtonItem = navigationItem.rightBarButtonItem

        present(actionSheet, animated: true, completion: nil)
    }

    // MARK: Swipe Actions
    func contextualDeleteAction(forRowAtIndexPath indexPath: IndexPath) -> UIContextualAction {
        let event = viewModel.sections[indexPath.section].events[indexPath.row]

        let action = UIContextualAction(style: .destructive, title: NSLocalizedString("Delete", comment: "")) { (_, _, handler) in
            self.viewModel.removeEvent(event) { result in
                switch result {
                case .success:
                    handler(true)
                case .failure:
                    handler(false)
                }
            }
        }

        action.backgroundColor = .systemRed

        return action
    }
}

extension HistoryViewController: HistoryViewModelDelegate {
    func stateChanged() {
        setClearAllButtonEnabled(false)

        switch viewModel.state {
        case .loading:
            stateMachine.transitionToState(.view("loading"), animated: false, completion: nil)

        case .empty:
            tableView.refreshControl?.endRefreshing()
            stateMachine.transitionToState(.view("empty"), animated: false, completion: nil)

        case .loaded:
            setClearAllButtonEnabled(true)
            tableView.refreshControl?.endRefreshing()
            tableView.reloadData()
            stateMachine.transitionToState(.none)

        case .failure(let error):
            tableView.refreshControl?.endRefreshing()
            switch error.type {
            case .networkError:
                setClearAllButtonEnabled(false)
                stateMachine.transitionToState(.view("offline"))

            default:
                stateMachine.transitionToState(.view("error"), animated: false, completion: nil)
            }

        default:
            break
        }
    }
}

extension HistoryViewController: UITableViewDataSource {
    func numberOfSections(in tableView: UITableView) -> Int {
        return viewModel.sections.count
    }

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        return viewModel.sections[section].events.count
    }

    func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        return viewModel.sections[section].title
    }

    func tableView(_ tableView: UITableView, willDisplayHeaderView view: UIView, forSection section: Int) {
        guard let headerView = view as? UITableViewHeaderFooterView else { return }
        headerView.textLabel?.textColor = UIColor.Putio.listSubtitle
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        guard let cell = tableView.dequeueReusableCell(withIdentifier: "historyReuse", for: indexPath) as? HistoryTableViewCell else {
            InternalFailurePresenter.log("Unable to dequeue HistoryTableViewCell")
            return UITableViewCell()
        }

        cell.configure(with: viewModel.sections[indexPath.section].events[indexPath.row])
        return cell
    }
}

extension HistoryViewController: UITableViewDelegate {
    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: false)
        guard let event = (viewModel.sections[indexPath.section].events[indexPath.row] as? PutioFileHistoryEvent) else { return }

        api.getFile(fileID: event.fileID) { result in
            switch result {
            case .success(let file):
                self.presentFile(file)

            case .failure:
                break
            }
        }
    }

    func tableView(_ tableView: UITableView, trailingSwipeActionsConfigurationForRowAt indexPath: IndexPath) -> UISwipeActionsConfiguration? {
        let actions = [contextualDeleteAction(forRowAtIndexPath: indexPath)]
        return UISwipeActionsConfiguration(actions: actions)
    }
}

extension HistoryViewController: AVPlayerViewControllerDelegate {
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
