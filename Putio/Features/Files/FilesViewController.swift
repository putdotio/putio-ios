import UIKit
import NotificationCenter
import GoogleCast
import StatefulViewController
import PutioSDK
import RealmSwift

class FilesViewController: UIViewController, StatefulViewController, FilePresenter, DownloadedFilePresenter, FolderCreatorPresenter {
    var viewModel = FilesViewModel()
    var allSelected = false
    var fileActionsButton: UIBarButtonItem?
    var chromecastButton: GCKUICastButton?
    var editingToolbar: UIToolbar?

    lazy var downloads: Results<Download>? = {
        guard let realm = PutioRealm.open(context: "FilesViewController.downloads") else {
            InternalFailurePresenter.log("Unable to load downloads collection")
            return nil
        }

        return realm.objects(Download.self).sorted(byKeyPath: "createdAt")
    }()

    lazy var userSettings: UserSettings = {
        guard let realm = PutioRealm.open(context: "FilesViewController.userSettings"),
              let settings = realm.objects(User.self).first?.settings else {
            InternalFailurePresenter.log("Unable to load UserSettings for FilesViewController")
            return UserSettings()
        }

        return settings
    }()

    @IBOutlet weak var tableView: UITableView!

    override func viewDidLoad() {
        super.viewDidLoad()

        tableView.delegate = self
        tableView.dataSource = self

        tableView.refreshControl = UIRefreshControl()
        tableView.refreshControl?.transform = CGAffineTransform(scaleX: 0.75, y: 0.75)
        tableView.refreshControl?.tintColor = UIColor.lightGray
        tableView.refreshControl?.addTarget(self, action: #selector(fetchData), for: .valueChanged)

        configureStateMachine()
        configureAppearance()
        fetchData(withLoader: false)
        registerObservers()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        updateTableInsets()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        navigationItem.title = viewModel.file?.name
    }

    func registerObservers() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(onNetworkReachabilityChanged),
            name: NetworkReachability.NOTIFICATION,
            object: nil
        )

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(willEnterForeground),
            name: UIApplication.willEnterForegroundNotification,
            object: nil
        )
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    func handlePossibleNetworkTransition() {
        fetchData(withLoader: true)
    }

    @objc func willEnterForeground() {
        handlePossibleNetworkTransition()
    }

    @objc func onNetworkReachabilityChanged() {
        handlePossibleNetworkTransition()
    }

    func configureStateMachine() {
        let loaderView = LoaderView.instantiateFromInterfaceBuilder()
        stateMachine.addView(loaderView, forState: "loading")

        let emptyView = EmptyStateView.instantiateFromInterfaceBuilder()
        stateMachine.addView(emptyView, forState: "empty")

        let offlineStatusView = OfflineStatusView.instantiateFromInterfaceBuilder()
        stateMachine.addView(offlineStatusView, forState: "offline")

        let errorNotFoundView = EmptyStateView.instantiateFromInterfaceBuilder()
        errorNotFoundView.configure(
            heading: NSLocalizedString("File not found", comment: ""),
            description: NSLocalizedString("We couldn't find that file", comment: "")
        )
        stateMachine.addView(errorNotFoundView, forState: "404")

        let errorView = EmptyStateView.instantiateFromInterfaceBuilder()
        errorView.configure(
            heading: NSLocalizedString("Oops", comment: ""),
            description: NSLocalizedString("An error occurred, please try again :(", comment: "")
        )
        stateMachine.addView(errorView, forState: "error")

        stateMachine.transitionToState(.view("loading"), animated: false, completion: nil)
    }

    func configureAppearance() {
        configureToolbar()

        tableView.rowHeight = 55.0
        tableView.contentInsetAdjustmentBehavior = .automatic
        tableView.tableHeaderView = UIView(frame: CGRect(x: 0, y: 0, width: 0, height: CGFloat.leastNormalMagnitude))

        navigationItem.title = viewModel.file?.name
        configureNavigationBarRightButtons()
    }

    func updateTableInsets() {
        let toolbarHeight = editingToolbar?.isHidden == false ? 44.0 : 0.0
        let contentInset = UIEdgeInsets(top: 0, left: 0, bottom: toolbarHeight, right: 0)
        tableView.contentInset = contentInset
        tableView.scrollIndicatorInsets = contentInset
    }

    @objc func fetchData(withLoader: Bool = false) {
        if withLoader {
            stateMachine.transitionToState(.view("loading"))
        }

        api.getFiles(parentID: viewModel.fileID, query: PutioFilesListQuery(mp4Status: true)) { result in
            self.tableView.refreshControl?.endRefreshing()

            switch result {
            case .success(let data):
                self.viewModel.file = data.parent
                self.viewModel.files = data.children

                self.tableView.reloadData()
                self.configureFileActionsButtonMenuItems()
                UIView.performWithoutAnimation {
                    self.setFileActionsEnabled(!(data.parent?.isShared ?? false))
                }

                if data.children.isEmpty {
                    self.stateMachine.transitionToState(.view("empty"))
                } else {
                    self.stateMachine.transitionToState(.none)
                }

            case .failure(let error):
                switch error.type {
                case .httpError(let statusCode, _):
                    if statusCode == 404 {
                        self.stateMachine.transitionToState(.view("404"))
                    } else {
                        self.stateMachine.transitionToState(.view("error"))
                    }

                case .networkError:
                    self.setFileActionsEnabled(false)
                    self.stateMachine.transitionToState(.view("offline"))

                case .decodingError, .unknownError:
                    self.stateMachine.transitionToState(.view("error"))
                }
            }
        }
    }

    func setSortSettings(nextSortKey: String) {
        guard let file = viewModel.file else { return }

        let currentSortKey = file.sortBy.split(separator: "_")[0]
        let currentSortDirection = file.sortBy.split(separator: "_")[1]

        var nextSortDirection = currentSortDirection
        if nextSortKey == currentSortKey {
            nextSortDirection = currentSortDirection == "ASC" ? "DESC" : "ASC"
        }

        api.setSortBy(fileId: file.id, sortBy: nextSortKey + "_" + nextSortDirection) { result in
            switch result {
            case .success:
                self.fetchData(withLoader: true)
            case .failure:
                break
            }
        }
    }
}
