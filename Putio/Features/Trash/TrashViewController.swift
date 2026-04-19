import UIKit
import StatefulViewController
import PutioSDK

class TrashViewController: UIViewController, StatefulViewController {
    var viewModel = TrashViewModel()
    var editingToolbar: UIToolbar?

    @IBOutlet weak var stackView: UIStackView!
    @IBOutlet weak var tableViewHeader: UIView!
    @IBOutlet weak var tableView: UITableView!

    override func viewDidLoad() {
        super.viewDidLoad()

        configureApperance()
        configureStateMachine()
        configureNavigationBar()
        configureToolbar()

        tableView.delegate = self
        tableView.dataSource = self
        tableView.refreshControl = UIRefreshControl()
        tableView.refreshControl?.transform = CGAffineTransform(scaleX: 0.75, y: 0.75)
        tableView.refreshControl?.tintColor = UIColor.lightGray
        tableView.refreshControl?.addTarget(self, action: #selector(refresh), for: .valueChanged)

        viewModel.delegate = self
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)

        switch viewModel.state {
        case .idle, .empty:
            viewModel.fetchFiles()
        default:
            break
        }
    }

    func configureApperance() {
        tableViewHeader.isHidden = true
    }

    func configureStateMachine() {
        let loadingView = LoaderView.instantiateFromInterfaceBuilder()
        stateMachine.addView(loadingView, forState: "loading")

        let emptyView = EmptyStateView.instantiateFromInterfaceBuilder()
        emptyView.configure(
            heading: NSLocalizedString("Your trash is empty", comment: ""),
            description: NSLocalizedString("Items you move to trash will appear here.", comment: "")
        )
        stateMachine.addView(emptyView, forState: "empty")

        let errorView = EmptyStateView.instantiateFromInterfaceBuilder()
        errorView.configure(
            heading: NSLocalizedString("Oops", comment: ""),
            description: NSLocalizedString("An error occurred, please try again :(", comment: "")
        )
        stateMachine.addView(errorView, forState: "error")

        let offlineStatusView = OfflineStatusView.instantiateFromInterfaceBuilder()
        stateMachine.addView(offlineStatusView, forState: "offline")

        stateMachine.transitionToState(.view("loading"))
    }

    func updateNavigationBarTitle(_ title: String = NSLocalizedString("Trash", comment: "")) {
        navigationItem.title = title
    }

    func configureNavigationBar(isEditing: Bool = false) {
        if isEditing {
            updateNavigationBarTitle(NSLocalizedString("Select Items", comment: ""))

            navigationItem.setHidesBackButton(true, animated: true)
            navigationItem.leftBarButtonItem = UIBarButtonItem(
                title: NSLocalizedString("Select All", comment: ""),
                style: .plain,
                target: self,
                action: #selector(toggleSelectAll)
            )

            navigationItem.rightBarButtonItem = UIBarButtonItem(
                title: NSLocalizedString("Done", comment: ""),
                style: .plain,
                target: self,
                action: #selector(toggleEditing)
            )
        } else {
            updateNavigationBarTitle(NSLocalizedString("Trash", comment: ""))
            navigationItem.setHidesBackButton(false, animated: true)
            navigationItem.leftBarButtonItem = nil

            let actions = [
                UIAction(
                    title: NSLocalizedString("Select", comment: ""),
                    image: UIImage(systemName: "checkmark.circle"),
                    identifier: nil,
                    handler: {  _ in self.toggleEditing() }
                ),
                UIAction(
                    title: NSLocalizedString("Restore all", comment: ""),
                    image: UIImage(systemName: "trash.slash"),
                    identifier: nil,
                    handler: {  _ in self.restoreAllFiles() }
                ),
                UIAction(
                    title: NSLocalizedString("Empty trash", comment: ""),
                    image: UIImage(systemName: "trash"),
                    identifier: nil,
                    attributes: .destructive,
                    handler: {  _ in self.emptyTrash() }
                )
            ]

            let rightBarButton = UIBarButtonItem(
                title: "",
                image: UIImage(systemName: "ellipsis.circle"),
                menu: UIMenu(title: "", children: actions)
            )

            navigationItem.rightBarButtonItem = rightBarButton

            switch viewModel.state {
            case .loaded:
                navigationItem.rightBarButtonItem?.isEnabled = true
            default:
                navigationItem.rightBarButtonItem?.isEnabled = false
            }
        }
    }

    func configureToolbar() {
        let toolbar = UIToolbar()
        toolbar.translatesAutoresizingMaskIntoConstraints = false
        toolbar.tintColor = UIColor.Putio.yellow

        let appearance = UIToolbarAppearance()
        appearance.configureWithTransparentBackground()
        toolbar.standardAppearance = appearance
        toolbar.compactAppearance = appearance

        let restoreBtn = UIBarButtonItem(
            title: NSLocalizedString("Restore", comment: ""),
            style: .plain,
            target: self,
            action: #selector(restoreSelectedFiles)
        )
        let deleteBtn = UIBarButtonItem(
            title: NSLocalizedString("Delete", comment: ""),
            style: .plain,
            target: self,
            action: #selector(deleteSelectedFiles)
        )

        toolbar.items = [
            restoreBtn,
            UIBarButtonItem(barButtonSystemItem: .flexibleSpace, target: nil, action: nil),
            deleteBtn
        ]

        toolbar.isHidden = true
        view.addSubview(toolbar)

        NSLayoutConstraint.activate([
            toolbar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            toolbar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            toolbar.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: 6)
        ])

        editingToolbar = toolbar
        updateToolbarButtonStates(isEnabled: false)
    }

    func updateToolbarButtonStates(isEnabled: Bool) {
        editingToolbar?.items?.forEach { $0.isEnabled = isEnabled }
    }

    // MARK: Actions
    @objc func refresh() {
        viewModel.refetchFiles()
    }

    func handleRestoreResult(_ result: TrashViewModel.ActionResult) {
        switch result {
        case .failure(let error):
            let errorAlert = UIAlertController(
                title: NSLocalizedString("Oops, we couldn't restore those files :(", comment: ""),
                message: error.localizedDescription,
                preferredStyle: .alert
            )

            errorAlert.addAction(UIAlertAction(title: NSLocalizedString("Close", comment: ""), style: .default, handler: nil))
            present(errorAlert, animated: true, completion: nil)
        default:
            let restoreStartedAlert = UIAlertController(
                title: NSLocalizedString("Restore started!", comment: ""),
                message: NSLocalizedString("It may take a long time if there are too many files.", comment: ""),
                preferredStyle: .alert
            )

            restoreStartedAlert.addAction(UIAlertAction(title: NSLocalizedString("OK", comment: ""), style: .default, handler: nil))
            present(restoreStartedAlert, animated: true, completion: nil)
        }
    }

    func restoreAllFiles() {
        viewModel.restoreAllFiles { result in self.handleRestoreResult(result) }
    }

    @objc func restoreSelectedFiles() {
        viewModel.restoreFiles(fileIDs: getSelectedFiles().map { $0.id }) { result in
            self.toggleEditing()
            self.handleRestoreResult(result)
        }
    }

    func handleDeleteResult(_ result: TrashViewModel.ActionResult) {
        switch result {
        case .failure(let error):
            let errorAlert = UIAlertController(
                title: NSLocalizedString("Oops, we couldn't delete those files :(", comment: ""),
                message: error.localizedDescription,
                preferredStyle: .alert
            )

            errorAlert.addAction(UIAlertAction(title: NSLocalizedString("Close", comment: ""), style: .default, handler: nil))
            present(errorAlert, animated: true, completion: nil)
        default:
            break
        }
    }

    func emptyTrash() {
        let confirmationAlert = UIAlertController(
            title: NSLocalizedString("Are you sure to delete those files?", comment: ""),
            message: nil,
            preferredStyle: .alert
        )

        let cancelButton = UIAlertAction(title: NSLocalizedString("Cancel", comment: ""), style: .cancel, handler: nil)
        let confirmButton = UIAlertAction(title: NSLocalizedString("Yes, empty trash", comment: ""), style: .destructive, handler: { (_) in
            self.viewModel.emptyTrash { result in self.handleDeleteResult(result) }
        })

        confirmationAlert.addAction(cancelButton)
        confirmationAlert.addAction(confirmButton)

        present(confirmationAlert, animated: true, completion: nil)
    }

    @objc func deleteSelectedFiles() {
        viewModel.deleteFiles(fileIDs: getSelectedFiles().map { $0.id }) { result in
            self.toggleEditing()
            self.handleDeleteResult(result)
        }
    }

    // MARK: Editing
    @objc func toggleEditing() {
        if tableView.isEditing {
            tableView.setEditing(false, animated: false)
            configureNavigationBar(isEditing: false)
            editingToolbar?.isHidden = true
            tabBarController?.setTabBarHidden(false, animated: true)
        } else {
            tableView.setEditing(true, animated: true)
            configureNavigationBar(isEditing: true)
            tabBarController?.setTabBarHidden(true, animated: true)
            editingToolbar?.isHidden = false
        }
    }

    // MARK: Selection
    func getSelectedFiles() -> [PutioTrashFile] {
        let indexPaths = tableView.indexPathsForSelectedRows ?? []
        return indexPaths.map { self.viewModel.files[$0.row] }
    }

    func updateSelectionState() {
        let selectedFiles = getSelectedFiles()
        let allSelected = selectedFiles.count == viewModel.files.count

        if selectedFiles.count > 0 {
            updateNavigationBarTitle(
                selectedFiles.count == 1
                    ? NSLocalizedString("1 Item", comment: "")
                    : String(format: NSLocalizedString("%d Items", comment: ""), selectedFiles.count)
            )
            updateToolbarButtonStates(isEnabled: true)
        } else {
            updateNavigationBarTitle(NSLocalizedString("Select Items", comment: ""))
            updateToolbarButtonStates(isEnabled: false)
        }

        if allSelected {
            navigationItem.leftBarButtonItem?.title = NSLocalizedString("Deselect All", comment: "")
        } else {
            navigationItem.leftBarButtonItem?.title = NSLocalizedString("Select All", comment: "")
        }
    }

    @objc func toggleSelectAll() {
        let allSelected = getSelectedFiles().count == viewModel.files.count

        for section in 0..<tableView.numberOfSections {
            for row in 0..<tableView.numberOfRows(inSection: section) {
                if allSelected {
                    tableView.deselectRow(at: IndexPath(row: row, section: section), animated: false)
                } else {
                    tableView.selectRow(at: IndexPath(row: row, section: section), animated: false, scrollPosition: .none)
                }
            }
        }

        updateSelectionState()
    }

    // MARK: Swipe Actions
    func contextualDeleteAction(forRowAtIndexPath indexPath: IndexPath) -> UIContextualAction {
        let file = viewModel.files[indexPath.row]

        let action = UIContextualAction(style: .destructive, title: NSLocalizedString("Delete", comment: "")) { (_, _, handler) in
            self.viewModel.deleteFile(fileID: file.id) { result in
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

extension TrashViewController: TrashViewModelDelegate {
    func stateChanged() {
        switch viewModel.state {
        case .loading:
            stateMachine.transitionToState(.view("loading"))

        case .loaded:
            tableView.refreshControl?.endRefreshing()
            tableView.reloadData()
            tableViewHeader.isHidden = false
            stateMachine.transitionToState(.none)

        case .empty:
            stateMachine.transitionToState(.view("empty"), animated: false, completion: nil)

        case .failure:
            stateMachine.transitionToState(.view("error"), animated: false, completion: nil)

        default:
            break
        }

        configureNavigationBar(isEditing: false)
    }
}

extension TrashViewController: UITableViewDelegate {
    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        updateSelectionState()
    }

    func tableView(_ tableView: UITableView, didDeselectRowAt indexPath: IndexPath) {
        updateSelectionState()
    }

    func tableView(_ tableView: UITableView, trailingSwipeActionsConfigurationForRowAt indexPath: IndexPath) -> UISwipeActionsConfiguration? {
        let actions = [contextualDeleteAction(forRowAtIndexPath: indexPath)]
        return UISwipeActionsConfiguration(actions: actions)
    }
}

extension TrashViewController: UITableViewDataSource {
    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        return viewModel.files.count
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "trashReuse", for: indexPath) as! TrashTableViewCell
        let file = viewModel.files[indexPath.row]
        cell.configure(with: file)
        return cell
    }
}
