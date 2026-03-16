import UIKit
import AVKit
import NotificationCenter
import GoogleCast
import StatefulViewController
import PutioAPI
import RealmSwift

// swiftlint:disable:next type_body_length
class FilesViewController: UIViewController, StatefulViewController, FilePresenter, DownloadedFilePresenter, FolderCreatorPresenter {
    var viewModel = FilesViewModel()
    var allSelected: Bool = false
    var fileActionsButton: UIBarButtonItem?
    var chromecastButton: GCKUICastButton?
    var editingToolbar: UIToolbar?

    lazy var downloads: Results<Download> = {
        let realm = try! Realm()
        return realm.objects(Download.self).sorted(byKeyPath: "createdAt")
    }()

    lazy var userSettings: UserSettings = {
        let realm = try! Realm()
        return realm.objects(User.self).first!.settings!
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

    func registerObservers() {
        NotificationCenter.default.addObserver(
            self, selector:
            #selector(onNetworkReachabilityChanged),
            name: NetworkReachability.NOTIFICATION, object: nil
        )

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(willEnterForeground),
            name: .UIApplicationWillEnterForeground, object: nil
        )
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        navigationItem.searchController = nil
        navigationItem.hidesSearchBarWhenScrolling = true
        navigationItem.title = viewModel.file?.name
    }

    func handlePossibleNetworkTransition() {
        fetchData(withLoader: true)
    }

    @objc func willEnterForeground() {
        self.handlePossibleNetworkTransition()
    }

    @objc func onNetworkReachabilityChanged() {
        self.handlePossibleNetworkTransition()
    }

    func configureStateMachine() {
        let loaderView = LoaderView.instantiateFromInterfaceBuilder()
        stateMachine.addView(loaderView, forState: "loading")

        let emptyView = EmptyStateView.instantiateFromInterfaceBuilder()
        stateMachine.addView(emptyView, forState: "empty")

        let offlineStatusView = OfflineStatusView.instantiateFromInterfaceBuilder()
        stateMachine.addView(offlineStatusView, forState: "offline")

        let errorNotFoundView = EmptyStateView.instantiateFromInterfaceBuilder()
        errorNotFoundView.configure(heading: "File not found", description: "We couldn't find that file")
        stateMachine.addView(errorNotFoundView, forState: "404")

        let errorView = EmptyStateView.instantiateFromInterfaceBuilder()
        errorView.configure(heading: "Oops", description: "An error occurred, please try again :(")
        stateMachine.addView(errorView, forState: "error")

        stateMachine.transitionToState(.view("loading"), animated: false, completion: nil)
    }

    func configureAppearance() {
        configureToolbar()

        tableView.rowHeight = 55.0
        tableView.separatorInset = UIEdgeInsets.zero
        tableView.contentInsetAdjustmentBehavior = .automatic

        tableView.sectionHeaderTopPadding = 0

        navigationItem.title = viewModel.file?.name

        configureNavigationBarRightButtons()
    }

    func updateTableInsets() {
        let toolbarHeight = editingToolbar?.isHidden == false ? 44.0 : 0.0
        let contentInset = UIEdgeInsets(top: 0, left: 0, bottom: toolbarHeight, right: 0)
        tableView.contentInset = contentInset
        tableView.scrollIndicatorInsets = contentInset
    }

    func createNavigationBarFileActionsButton() -> UIBarButtonItem {
        let imageConfig = UIImage.SymbolConfiguration(pointSize: 18, weight: .regular)
        let button = UIBarButtonItem(
            image: UIImage(systemName: "ellipsis.circle", withConfiguration: imageConfig),
            style: .plain,
            target: nil,
            action: nil
        )
        button.tintColor = UIColor.Putio.yellow
        return button
    }

    func configureNavigationBarRightButtons() {
        let button = createNavigationBarFileActionsButton()
        fileActionsButton = button

        let castButton = GCKUICastButton(frame: .zero)
        castButton.tintColor = UIColor.Putio.yellow
        castButton.frame = CGRect(x: 0, y: 0, width: 24, height: 24)
        chromecastButton = castButton
        let castBarButtonItem = UIBarButtonItem(customView: castButton)

        navigationItem.rightBarButtonItems = [button, castBarButtonItem]
        setFileActionsEnabled(false)
    }

    func setFileActionsEnabled(_ isEnabled: Bool) {
        fileActionsButton?.isEnabled = isEnabled
    }

    func configureFileActionsButtonMenuItems() {
        guard let parent = self.viewModel.file else { return }
        let children = self.viewModel.files

        // app specific actions
        // -- select --
        let selectButton = UIAction(
            title: "Select",
            image: UIImage(systemName: "checkmark.circle"),
            identifier: nil,
            handler: { _ in self.toggleTableEditing() }
        )
        if children.count == 0 { selectButton.attributes = .disabled }

        // api: universal actions
        // -- new folder --
        let newFolderButton = UIAction(
            title: "New Folder",
            image: UIImage(systemName: "folder.badge.plus"),
            identifier: nil,
            handler: { _ in
                let createFolderAlert = self.createFolderCreatorAlert(parentID: parent.id) { (_, error) in
                    guard error == nil else { return }
                    self.fetchData(withLoader: true)
                }

                self.present(createFolderAlert, animated: true, completion: nil)
            }
        )

        // -- sort --
        let sortKeys: KeyValuePairs = [
            "NAME": "Name",
            "SIZE": "Size",
            "DATE": "Date Added",
            "MODIFIED": "Date Modified",
            "TYPE": "Type",
            "WATCH": "Watch Status"
        ]

        let selectedSortKey = parent.sortBy.split(separator: "_")[0]
        let selectedSortDirection = parent.sortBy.split(separator: "_")[1]

        let sortMenuItems = sortKeys.map { (sortKey, label) -> UIAction in
            let item = UIAction(
                title: label,
                image: nil,
                identifier: UIAction.Identifier(sortKey),
                discoverabilityTitle: nil,
                state: .off,
                handler: { _ in self.setSortSettings(nextSortKey: sortKey) }
            )

            if sortKey == selectedSortKey {
                item.state = .on
                item.subtitle = selectedSortDirection == "ASC" ? "Ascending" : "Descending"
            }

            return item
        }

        let sortMenu = UIMenu(
            title: "",
            image: nil,
            identifier: nil,
            options: .displayInline,
            children: sortMenuItems
        )

        // -- UI MENU --
        fileActionsButton?.menu = UIMenu(
            image: nil,
            identifier: nil,
            options: [],
            children: [
                selectButton,
                newFolderButton,
                sortMenu
            ]
        )
    }

    func configureToolbar() {
        let toolbar = UIToolbar()
        toolbar.translatesAutoresizingMaskIntoConstraints = false
        toolbar.tintColor = UIColor.Putio.yellow

        let appearance = UIToolbarAppearance()
        appearance.configureWithTransparentBackground()
        toolbar.standardAppearance = appearance
        toolbar.compactAppearance = appearance

        let deleteTitle = userSettings.trashEnabled ? "Trash" : "Delete"
        let moveBtn = UIBarButtonItem(title: "Move", style: .plain, target: self, action: #selector(moveSelectedFiles))
        moveBtn.isEnabled = false
        let deleteBtn = UIBarButtonItem(title: deleteTitle, style: .plain, target: self, action: #selector(deleteSelectedFiles))
        deleteBtn.isEnabled = false

        toolbar.items = [
            moveBtn,
            UIBarButtonItem(barButtonSystemItem: .flexibleSpace, target: nil, action: nil),
            deleteBtn
        ]

        toolbar.isHidden = true
        view.addSubview(toolbar)

        NSLayoutConstraint.activate([
            toolbar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            toolbar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            toolbar.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])

        editingToolbar = toolbar
    }

    func showEditingToolbar() {
        tabBarController?.setTabBarHidden(true, animated: true)
        editingToolbar?.isHidden = false
    }

    func hideEditingToolbar() {
        editingToolbar?.isHidden = true
        tabBarController?.setTabBarHidden(false, animated: true)
    }

    @objc func fetchData(withLoader: Bool = false) {
        if withLoader {
            stateMachine.transitionToState(.view("loading"))
        }

        api.getFiles(parentID: viewModel.fileID, query: ["mp4_status": true], completion: { result in
            self.tableView.refreshControl?.endRefreshing()

            switch result {
            case .success(let data):
                self.viewModel.file = data.parent
                self.viewModel.files = data.children

                self.tableView.reloadData()
                self.configureFileActionsButtonMenuItems()
                self.setFileActionsEnabled(!data.parent.isShared)

                if data.children.count == 0 {
                    self.stateMachine.transitionToState(.view("empty"))
                } else {
                    self.stateMachine.transitionToState(.none)
                }

            case .failure(let error):
                switch error.type {
                case .httpError(let statusCode, _):
                    if statusCode == 404 {
                        return self.stateMachine.transitionToState(.view("404"))
                    }

                    self.stateMachine.transitionToState(.view("error"))

                case .networkError:
                    self.setFileActionsEnabled(false)
                    self.stateMachine.transitionToState(.view("offline"))

                case .unknownError:
                    self.stateMachine.transitionToState(.view("error"))
                }
            }
        })
    }

    func setSortSettings(nextSortKey: String) {
        guard let file = self.viewModel.file else { return }

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

    @objc func toggleTableEditing() {
        if tableView.isEditing {
            return stopEditing()
        }

        return startEditing()
    }

    func startEditing() {
        showEditingToolbar()
        updateTableInsets()

        tableView.setEditing(true, animated: true)

        navigationItem.setHidesBackButton(true, animated: true)
        navigationItem.leftBarButtonItem = UIBarButtonItem(
            title: "Select All",
            style: .plain,
            target: self,
            action: #selector(toggleSelectAll)
        )

        navigationItem.title = "Select Items"

        navigationItem.rightBarButtonItem = UIBarButtonItem(
            title: "Done",
            style: .plain,
            target: self,
            action: #selector(toggleTableEditing)
        )

        navigationItem.searchController?.searchBar.isUserInteractionEnabled = false
        navigationItem.searchController?.searchBar.alpha = 0.3
    }

    func stopEditing() {
        hideEditingToolbar()
        updateTableInsets()

        tableView.setEditing(false, animated: true)

        navigationItem.setHidesBackButton(false, animated: true)
        navigationItem.leftBarButtonItem = nil

        navigationItem.title = viewModel.file?.name

        configureNavigationBarRightButtons()
        setFileActionsEnabled(!(viewModel.file?.isShared ?? false))
        configureFileActionsButtonMenuItems()

        navigationItem.searchController?.searchBar.isUserInteractionEnabled = true
        navigationItem.searchController?.searchBar.alpha = 1

        deselectAll()
    }

    // MARK: Bulk Selection Methods
    func getSelectedFiles() -> [PutioFile] {
        let indexPaths = tableView.indexPathsForSelectedRows ?? []
        return indexPaths.map { self.viewModel.files[$0.row] }
    }

    func updateSelectionState() {
        allSelected = getSelectedFiles().count == viewModel.getSelectableFiles().count
        updateNavigationBarState()
        updateToolbarActions()
    }

    @objc func toggleSelectAll() {
        if allSelected {
            return deselectAll()
        }

        return selectAll()
    }

    func selectAll() {
        for section in 0..<tableView.numberOfSections {
            for row in 0..<tableView.numberOfRows(inSection: section) {
                let selectableFiles = viewModel.getSelectableFiles()
                if selectableFiles.contains(where: { (file) -> Bool in file.id == self.viewModel.files[row].id }) {
                    tableView.selectRow(at: IndexPath(row: row, section: section), animated: false, scrollPosition: .none)
                }
            }
        }

        updateSelectionState()
    }

    func deselectAll() {
        for section in 0..<tableView.numberOfSections {
            for row in 0..<tableView.numberOfRows(inSection: section) {
                tableView.deselectRow(at: IndexPath(row: row, section: section), animated: false)
            }
        }

        updateSelectionState()
    }

    // MARK: Selection Mode NavBar State
    func updateNavigationBarState() {
        guard tableView.isEditing else {
            return
        }

        let count = getSelectedFiles().count

        if count == 0 {
            navigationItem.title = "Select Items"
        } else if count == 1 {
            navigationItem.title = "1 Item"
        } else {
            navigationItem.title = "\(count) Items"
        }

        navigationItem.leftBarButtonItems?[0].title = allSelected ? "Deselect All" : "Select All"
    }

    // MARK: Toolbar State and Actions
    func updateToolbarActions() {
        let isEnabled = getSelectedFiles().count > 0
        editingToolbar?.items?.forEach { $0.isEnabled = isEnabled }
    }

    func deleteFiles(fileIDs: [Int]) {
        self.stateMachine.transitionToState(.view("loading"))

        api.deleteFiles(fileIDs: fileIDs, completion: { result in
            switch result {
            case .success:
                self.fetchData()

            case .failure(let error):
                self.stateMachine.transitionToState(.none)

                let errorAlert = UIAlertController(
                    title: "Oops, an error occurred :(",
                    message: error.message,
                    preferredStyle: .alert
                )

                errorAlert.addAction(UIAlertAction(title: "Close", style: .cancel, handler: nil))
                return self.present(errorAlert, animated: true, completion: nil)
            }
        })
    }

    @objc func deleteSelectedFiles() {
        let selectedFiles = getSelectedFiles()

        // send to trash without confirmation
        if userSettings.trashEnabled {
            stopEditing()
            return deleteFiles(fileIDs: selectedFiles.map { $0.id })
        }

        // show confirmation
        let messageItem = selectedFiles.count > 1 ?
            "\(selectedFiles.count) files" :
            selectedFiles[0].name

        let actionSheet = UIAlertController(
            title: "Are you sure you want to delete \(messageItem)?",
            message: nil,
            preferredStyle: .actionSheet
        )

        let deleteButton = UIAlertAction(title: "Delete", style: .destructive, handler: { (_) in
            self.stopEditing()
            self.deleteFiles(fileIDs: selectedFiles.map { $0.id })
        })

        actionSheet.addAction(deleteButton)
        actionSheet.addAction(UIAlertAction(title: "Cancel", style: .cancel, handler: nil))
        actionSheet.popoverPresentationController?.sourceView = editingToolbar

        present(actionSheet, animated: true, completion: nil)
    }

    @objc func moveSelectedFiles() {
        moveFiles(getSelectedFiles())
    }

    // MARK: Move Files
    func moveFiles(_ files: [PutioFile]) {
        let storyboard = UIStoryboard(name: "MoveFiles", bundle: nil)
        let moveNC = storyboard.instantiateViewController(withIdentifier: "MoveNC") as! UINavigationController
        let moveVC = moveNC.viewControllers[0] as! MoveFilesViewController

        moveVC.filesToMove = files
        moveVC.delegate = self

        present(moveNC, animated: true, completion: nil)
    }

    // MARK: Open in VLC
    func openInVLC(_ file: PutioFile) {
        if UIApplication.shared.canOpenURL(URL(string: "vlc://")!) {
            let loadingAlert = UIAlertController(title: "Processing...", message: "", preferredStyle: .alert)
            self.present(loadingAlert, animated: true, completion: nil)

            api.getFile(fileID: file.id) { result in
                loadingAlert.dismiss(animated: true) {
                    switch result {
                    case .success(let file):
                        let url = file.type == .video ? file.streamURL : file.getAudioStreamURL(token: api.config.token).absoluteString

                        UIApplication.shared.open(
                            URL(string: "vlc://\(url)")!,
                            options: [:],
                            completionHandler: nil
                        )

                    case .failure(let error):
                        let errorAlert = UIAlertController(
                            title: "Oops, an error occurred :(",
                            message: error.message,
                            preferredStyle: .alert
                        )

                        errorAlert.addAction(UIAlertAction(title: "Close", style: .cancel, handler: nil))
                        self.present(errorAlert, animated: true, completion: nil)
                    }
                }
            }
        } else {
            UIApplication.shared.open(
                URL(string: "https://apps.apple.com/app/vlc-for-mobile/id650377962")!,
                options: [:],
                completionHandler: nil
            )
        }
    }

    // MARK: Single File Actions (Swipe)
    func contextualDeleteAction(forRowAtIndexPath indexPath: IndexPath) -> UIContextualAction {
        let file = viewModel.files[indexPath.row]
        let cell = tableView.cellForRow(at: indexPath)!

        func deleteFile(_ completion: @escaping (_ result: Bool) -> Void) {
            let loadingAlert = UIAlertController(
                title: userSettings.trashEnabled ? "Moving to trash..." : "Deleting...",
                message: "",
                preferredStyle: .alert
            )

            present(loadingAlert, animated: true, completion: nil)

            api.deleteFile(fileID: file.id) { result in
                loadingAlert.dismiss(animated: true) {
                    switch result {
                    case .success:
                        self.viewModel.files.remove(at: indexPath.row)
                        self.tableView.deleteRows(at: [indexPath], with: .automatic)
                        completion(true)

                    case .failure(let error):
                        let errorAlert = UIAlertController(
                            title: "Oops, an error occurred",
                            message: error.message,
                            preferredStyle: .alert
                        )

                        errorAlert.addAction(UIAlertAction(title: "Close", style: .cancel, handler: nil))
                        self.present(errorAlert, animated: true, completion: { completion(false) })
                    }
                }
            }
        }

        let action = UIContextualAction(style: .destructive, title: userSettings.trashEnabled ? "Trash" : "Delete") { (_, _, handler) in
            if self.userSettings.trashEnabled {
                return deleteFile { result in handler(result) }
            }

            let actionSheet = UIAlertController(
                title: "Are you sure you want to delete \(file.name)?",
                message: nil,
                preferredStyle: .actionSheet
            )

            let deleteButton = UIAlertAction(title: "Delete", style: .destructive, handler: { (_) in deleteFile { result in handler(result) } })
            let cancelButton = UIAlertAction(title: "Cancel", style: .cancel, handler: { (_) in handler(false) })

            actionSheet.addAction(deleteButton)
            actionSheet.addAction(cancelButton)
            actionSheet.popoverPresentationController?.sourceView = cell
            actionSheet.popoverPresentationController?.sourceRect = CGRect(x: cell.frame.width, y: 0, width: 80, height: cell.frame.height)

            self.present(actionSheet, animated: true, completion: nil)
        }

        action.backgroundColor = .systemRed
        return action
    }

    func contextualMoreAction(forRowAtIndexPath indexPath: IndexPath) -> UIContextualAction {
        let file = viewModel.files[indexPath.row]
        let cell = tableView.cellForRow(at: indexPath)!

        let action = UIContextualAction(style: .normal, title: "More") { (_, _, handler) in
            let actionSheet = UIAlertController(
                title: file.name,
                message: nil,
                preferredStyle: .actionSheet
            )

            // MARK: Rename Button
            let renameButton = UIAlertAction(title: "Rename", style: .default, handler: { (_) in
                handler(true)

                let renameAlert = UIAlertController(
                    title: "Rename \(file.name)",
                    message: nil,
                    preferredStyle: .alert
                )

                renameAlert.addTextField { (textField) -> Void in
                    textField.placeholder = "New Name"
                    textField.text = file.name
                    textField.autocorrectionType = .no
                }

                renameAlert.addAction(UIAlertAction(title: "Save", style: .default, handler: { (_) in
                    let newName = renameAlert.textFields![0].text!
                    api.renameFile(fileID: file.id, name: newName, completion: { _ in })
                    self.viewModel.files[indexPath.row].name = newName
                    self.tableView.reloadData()
                }))

                renameAlert.addAction(UIAlertAction(title: "Cancel", style: .cancel, handler: nil))

                self.present(renameAlert, animated: true, completion: nil)
            })

            actionSheet.addAction(renameButton)

            // MARK: Move Button
            let moveButton = UIAlertAction(title: "Move", style: .default, handler: { (_) in
                handler(true)
                self.moveFiles([file])
            })

            actionSheet.addAction(moveButton)

            // MARK: Open in VLC
            if file.type == .video || file.type == .audio {
                let openInVLCButton = UIAlertAction(title: "Play original in VLC", style: .default) { (_) in
                    handler(true)
                    self.openInVLC(file)
                }

                actionSheet.addAction(openInVLCButton)
            }

            // MARK: Cancel Button
            let cancelButton = UIAlertAction(title: "Cancel", style: .cancel, handler: { (_) in handler(false) })
            actionSheet.addAction(cancelButton)

            actionSheet.popoverPresentationController?.sourceView = cell
            actionSheet.popoverPresentationController?.sourceRect = CGRect(x: cell.frame.width, y: 0, width: 80, height: cell.frame.height)

            self.present(actionSheet, animated: true, completion: nil)
        }

        action.backgroundColor = UIColor.Putio.black

        return action
    }

    func contextualCopyAction(forRowAtIndexPath indexPath: IndexPath) -> UIContextualAction {
        let file = viewModel.files[indexPath.row]

        let action = UIContextualAction(style: .normal, title: "Copy") { (_, _, handler) in
            handler(true)
            self.stateMachine.transitionToState(.view("loading"))

            api.copyFile(fileID: file.id, completion: { result in
                self.stateMachine.transitionToState(.none)

                switch result {
                case .failure(let error):
                    let errorAlert = UIAlertController(
                        title: "Oops, an error occurred :(",
                        message: error.localizedDescription,
                        preferredStyle: .alert
                    )

                    errorAlert.addAction(UIAlertAction(title: "Close", style: .cancel, handler: nil))
                    return self.present(errorAlert, animated: true, completion: nil)

                case .success:
                    break
                }
            })
        }

        action.backgroundColor = UIColor.Putio.black

        return action
    }

    func contextualDownloadAction(forRowAtIndexPath indexPath: IndexPath) -> UIContextualAction {
        let file = viewModel.files[indexPath.row]
        var action: UIContextualAction

        if file.needConvert {
            action = UIContextualAction(style: .normal, title: "Convert and Download", handler: { (_, _, handler) in
                self.presentVideoConversionView(for: file, intention: VideoConversionIntention.download)
                handler(true)
            })
        } else {
            if let download = downloads.first(where: { (download) -> Bool in
                download.id == file.id && download.state == .completed
            }) {
                action = UIContextualAction(style: .normal, title: "Play Downloaded") { (_, _, handler) in
                    self.presentDownloadedFile(download)
                    handler(true)
                }
            } else {
                action = UIContextualAction(style: .normal, title: "Download") { (_, _, handler) in
                    if file.type == .video {
                        VideoDownloadManager.sharedInstance.createDownload(from: file)
                    } else {
                        AudioDownloadManager.sharedInstance.createDownload(from: file)
                    }

                    handler(true)
                }
            }
        }

        action.backgroundColor = UIColor.darkGray

        return action
    }
}

extension FilesViewController: MoveFilesViewControllerDelegate {
    func moveFilesCompleted(movedTo: PutioFile) {
        stopEditing()
        fetchData()
    }

    func moveFilesCancelled() {
        stopEditing()
        fetchData()
    }
}

extension FilesViewController: UITableViewDataSource {
    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        return viewModel.files.count
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "fileReuse", for: indexPath) as! FilesTableViewCell
        let file = viewModel.files[indexPath.row]

        let download = downloads.first(where: { (download) -> Bool in
            download.id == file.id
        })

        var relativeDate = file.updatedAt.timeAgoSinceDate()

        if let parent = viewModel.file, parent.sortBy.starts(with: "DATE") {
            relativeDate = file.createdAt.timeAgoSinceDate()
        }

        cell.configure(with: file, download: download, relativeDate: relativeDate)
        return cell
    }
}

extension FilesViewController: UITableViewDelegate {
    func tableView(_ tableView: UITableView, canEditRowAt indexPath: IndexPath) -> Bool {
        if viewModel.files[indexPath.row].isSharedRoot {
            return false
        }

        return true
    }

    func tableView(_ tableView: UITableView, willSelectRowAt indexPath: IndexPath) -> IndexPath? {
        if tableView.isEditing && viewModel.files[indexPath.row].isSharedRoot {
            return nil
        }

        return indexPath
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        if tableView.isEditing {
            return updateSelectionState()
        }

        let file = viewModel.files[indexPath.row]

        tableView.deselectRow(at: indexPath, animated: false)
        presentFile(file)
    }

    func tableView(_ tableView: UITableView, didDeselectRowAt indexPath: IndexPath) {
        if tableView.isEditing {
            return updateSelectionState()
        }
    }

    func tableView(_ tableView: UITableView, trailingSwipeActionsConfigurationForRowAt indexPath: IndexPath) -> UISwipeActionsConfiguration? {
        let file = viewModel.files[indexPath.row]

        var actions = file.isShared ? [
            contextualCopyAction(forRowAtIndexPath: indexPath)
        ] : [
            contextualDeleteAction(forRowAtIndexPath: indexPath),
            contextualMoreAction(forRowAtIndexPath: indexPath)
        ]

        if file.type == .video || file.type == .audio {
            actions.insert(contextualDownloadAction(forRowAtIndexPath: indexPath), at: 1)
        }

        if file.isSharedRoot {
            actions = []
        }

        let configuration = UISwipeActionsConfiguration(actions: actions)
        configuration.performsFirstActionWithFullSwipe = false

        return configuration
    }
}

extension FilesViewController: AVPlayerViewControllerDelegate {
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

extension FilesViewController: VideoConversionViewControllerDelegate {
    func videoConversionFinished(for file: PutioFile, intention: VideoConversionIntention) {
        switch intention {
        case .download:
            VideoDownloadManager.sharedInstance.createDownload(from: file)
        case .play:
           presentFile(file)
        }
    }

    func videoConversionControllerDismissedBeforeFinish() {}
}
