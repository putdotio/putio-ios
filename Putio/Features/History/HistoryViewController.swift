import UIKit
import AVKit
import StatefulViewController
import PutioAPI

class HistoryViewController: UIViewController, FilePresenter, StatefulViewController {
    var viewModel: HistoryViewModel = HistoryViewModel()

    @IBOutlet weak var clearAllButton: UIBarButtonItem!
    @IBOutlet weak var tableView: UITableView!

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
        tableView.separatorColor = UIColor.Putio.background
        tableView.backgroundColor = UIColor.Putio.background
    }

    func configureStateMachine() {
        let loaderView = LoaderView.instantiateFromInterfaceBuilder()
        stateMachine.addView(loaderView, forState: "loading")

        let emptyView = EmptyStateView.instantiateFromInterfaceBuilder()
        emptyView.configure(heading: "Your history is empty", description: "There will be information when things start happening.")
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
            title: "Are you sure?",
            message: nil,
            preferredStyle: .actionSheet
        )

        let confirmButton = UIAlertAction(title: "Clear", style: .destructive, handler: { (_) in
            self.viewModel.removeAllEvents()
        })

        let cancelButton = UIAlertAction(title: "Cancel", style: .cancel, handler: nil)

        actionSheet.addAction(confirmButton)
        actionSheet.addAction(cancelButton)
        actionSheet.popoverPresentationController?.barButtonItem = navigationItem.rightBarButtonItem

        present(actionSheet, animated: true, completion: nil)
    }

    // MARK: Swipe Actions
    func contextualDeleteAction(forRowAtIndexPath indexPath: IndexPath) -> UIContextualAction {
        let event = viewModel.sections[indexPath.section].events[indexPath.row]

        let action = UIContextualAction(style: .destructive, title: "Delete") { (_, _, handler) in
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
        clearAllButton.isEnabled = false

        switch viewModel.state {
        case .loading:
            stateMachine.transitionToState(.view("loading"), animated: false, completion: nil)

        case .empty:
            tableView.refreshControl?.endRefreshing()
            stateMachine.transitionToState(.view("empty"), animated: false, completion: nil)

        case .loaded:
            clearAllButton.isEnabled = true
            tableView.refreshControl?.endRefreshing()
            tableView.reloadData()
            stateMachine.transitionToState(.none)

        case .failure(let error):
            tableView.refreshControl?.endRefreshing()
            switch error.type {
            case .networkError:
                clearAllButton.isEnabled = false
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
        let cell = tableView.dequeueReusableCell(withIdentifier: "historyReuse", for: indexPath) as! HistoryTableViewCell
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
        (playerViewController as! VideoPlayerViewController).handlePictureInPictureDidStart()
    }

    func playerViewController(_ playerViewController: AVPlayerViewController, restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completionHandler: @escaping (Bool) -> Void) {
        present(playerViewController, animated: true) {
            (playerViewController as! VideoPlayerViewController).handlePictureInPictureDidStop()
            completionHandler(true)
        }
    }
}
