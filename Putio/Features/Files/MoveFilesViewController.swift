import UIKit
import StatefulViewController
import PutioSDK

protocol MoveFilesViewControllerDelegate: AnyObject {
    func moveFilesCompleted(movedTo: PutioFile)
    func moveFilesCancelled()
}

class MoveFilesViewController: UIViewController, StatefulViewController, FolderCreatorPresenter {
    @IBOutlet weak var toolbar: UIToolbar!
    @IBOutlet weak var createFolderButton: UIBarButtonItem!
    @IBOutlet weak var moveButton: UIBarButtonItem!
    @IBOutlet weak var tableView: UITableView!

    weak var delegate: MoveFilesViewControllerDelegate?

    var file: PutioFile?
    var files: [PutioFile] = []
    var filesToMove: [PutioFile] = []

    override func viewDidLoad() {
        super.viewDidLoad()

        tableView.dataSource = self
        tableView.delegate = self

        configureAppearance()
        fetchData()
    }

    func configureStateMachine() {
        let loaderView = LoaderView.instantiateFromInterfaceBuilder()
        stateMachine.addView(loaderView, forState: "loading")
        stateMachine.transitionToState(.view("loading"), animated: false, completion: nil)
    }

    func configureAppearance() {
        configureStateMachine()

        let appearance = UIToolbarAppearance()
        appearance.configureWithTransparentBackground()
        toolbar.standardAppearance = appearance
        toolbar.compactAppearance = appearance
        toolbar.scrollEdgeAppearance = appearance

        tableView.contentInset = UIEdgeInsets(top: 0, left: 0, bottom: 56, right: 0)
        tableView.scrollIndicatorInsets = tableView.contentInset

        let prompt = filesToMove.count > 1
            ? String(format: NSLocalizedString("Choose new location for %d files", comment: ""), filesToMove.count)
            : NSLocalizedString("Choose new location for 1 file", comment: "")
        navigationItem.prompt = prompt
        navigationItem.title = file?.name ?? NSLocalizedString("Your Files", comment: "")
    }

    func canMove(to file: PutioFile) -> Bool {
        return !file.isShared && !file.isSharedRoot && !filesToMove.contains(where: { (fileToMove) -> Bool in
            fileToMove.id == file.id
        })
    }

    func updateActionButtonStates(isEnabled: Bool) {
        moveButton.isEnabled = isEnabled
        createFolderButton.isEnabled = isEnabled
    }

    func fetchData() {
        let fileID = file != nil ? file!.id : 0

        stateMachine.transitionToState(.view("loading"))
        updateActionButtonStates(isEnabled: false)

        api.getFiles(parentID: fileID, query: PutioFilesListQuery(contentType: "application/x-directory"), completion: { result in
            switch result {
            case .success(let data):
                self.file = data.parent
                self.files = data.children

                self.stateMachine.transitionToState(.none)

                if self.files.count == 0 {
                    let emptyView = EmptyStateView.instantiateFromInterfaceBuilder()
                    emptyView.configure(
                        heading: NSLocalizedString("No folders whatsoever", comment: ""),
                        description: NSLocalizedString("This directory doesn't contain any folder", comment: "")
                    )
                    self.tableView.backgroundView = emptyView
                } else {
                    self.tableView.backgroundView = nil
                }

                self.updateActionButtonStates(isEnabled: true)
                self.tableView.reloadData()

            case .failure:
                break
            }
        })
    }

    @IBAction func cancelButtonPressed(_ sender: Any) {
        delegate?.moveFilesCancelled()
        dismiss(animated: true, completion: nil)
    }

    @IBAction func moveButtonPressed(_ sender: Any) {
        let loadingAlert = UIAlertController(
            title: NSLocalizedString("Moving...", comment: ""),
            message: "",
            preferredStyle: .alert
        )
        self.present(loadingAlert, animated: true, completion: nil)

        api.moveFiles(fileIDs: filesToMove.map {$0.id}, parentID: file!.id) { result in
            loadingAlert.dismiss(animated: true, completion: {
                switch result {
                case .success:
                    self.dismiss(animated: true, completion: nil)
                    self.delegate?.moveFilesCompleted(movedTo: self.file!)

                case .failure(let error):
                    let errorAlert = UIAlertController(
                        title: NSLocalizedString("Oops, an error occurred :(", comment: ""),
                        message: error.message,
                        preferredStyle: .alert
                    )

                    errorAlert.addAction(UIAlertAction(title: NSLocalizedString("Close", comment: ""), style: .cancel, handler: nil))
                    self.present(errorAlert, animated: true, completion: nil)
                }
            })
        }
    }

    @IBAction func createFolderButtonPressed(_ sender: Any) {
        let createFolderAlert = self.createFolderCreatorAlert(parentID: self.file!.id) { (_, error) in
            guard error == nil else { return }
            self.fetchData()
        }

        self.present(createFolderAlert, animated: true, completion: nil)
    }
}

extension MoveFilesViewController: UITableViewDataSource {
    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        return files.count
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "moveFileReuse", for: indexPath)
        let file = files[indexPath.row]

        cell.imageView?.image = UIImage.Putio.folder
        cell.textLabel?.text = file.name

        if canMove(to: file) {
            cell.accessoryView = UIImageView(image: UIImage.Putio.chevronLeft)
        } else {
            cell.selectionStyle = .none
            cell.contentView.alpha = 0.25
        }

        return cell
    }
}

extension MoveFilesViewController: UITableViewDelegate {
    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: false)

        let file = files[indexPath.row]
        guard canMove(to: file) else { return }

        let next = UIStoryboard(name: "MoveFiles", bundle: nil).instantiateViewController(withIdentifier: "MoveVC") as! MoveFilesViewController
        next.delegate = self.delegate
        next.file = file
        next.filesToMove = filesToMove

        navigationController?.pushViewController(next, animated: true)
    }
}
