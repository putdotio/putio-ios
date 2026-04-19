import UIKit

extension FilesViewController {
    func contextualDeleteAction(forRowAtIndexPath indexPath: IndexPath) -> UIContextualAction {
        let file = viewModel.files[indexPath.row]
        guard let cell = tableView.cellForRow(at: indexPath) else {
            InternalFailurePresenter.log("Unable to access file cell for delete action at row \(indexPath.row)")
            return UIContextualAction(style: .destructive, title: userSettings.trashEnabled ? "Trash" : "Delete") { _, _, handler in
                handler(false)
            }
        }

        let action = UIContextualAction(style: .destructive, title: userSettings.trashEnabled ? "Trash" : "Delete") { _, _, handler in
            func deleteFile(_ completion: @escaping (Bool) -> Void) {
                let loadingAlert = UIAlertController(
                    title: self.userSettings.trashEnabled ? "Moving to trash..." : "Deleting...",
                    message: "",
                    preferredStyle: .alert
                )

                self.present(loadingAlert, animated: true)

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

                            errorAlert.addAction(UIAlertAction(title: "Close", style: .cancel))
                            self.present(errorAlert, animated: true) { completion(false) }
                        }
                    }
                }
            }

            if self.userSettings.trashEnabled {
                deleteFile { result in handler(result) }
                return
            }

            let actionSheet = UIAlertController(
                title: "Are you sure you want to delete \(file.name)?",
                message: nil,
                preferredStyle: .actionSheet
            )

            let deleteButton = UIAlertAction(title: "Delete", style: .destructive) { _ in deleteFile { result in handler(result) } }
            let cancelButton = UIAlertAction(title: "Cancel", style: .cancel) { _ in handler(false) }

            actionSheet.addAction(deleteButton)
            actionSheet.addAction(cancelButton)
            actionSheet.popoverPresentationController?.sourceView = cell
            actionSheet.popoverPresentationController?.sourceRect = CGRect(x: cell.frame.width, y: 0, width: 80, height: cell.frame.height)

            self.present(actionSheet, animated: true)
        }

        action.backgroundColor = .systemRed
        return action
    }

    func contextualMoreAction(forRowAtIndexPath indexPath: IndexPath) -> UIContextualAction {
        let file = viewModel.files[indexPath.row]
        guard let cell = tableView.cellForRow(at: indexPath) else {
            InternalFailurePresenter.log("Unable to access file cell for more action at row \(indexPath.row)")
            return UIContextualAction(style: .normal, title: "More") { _, _, handler in
                handler(false)
            }
        }

        let action = UIContextualAction(style: .normal, title: "More") { _, _, handler in
            let actionSheet = UIAlertController(title: file.name, message: nil, preferredStyle: .actionSheet)

            let renameButton = UIAlertAction(title: "Rename", style: .default) { _ in
                handler(true)

                let renameAlert = UIAlertController(
                    title: "Rename \(file.name)",
                    message: nil,
                    preferredStyle: .alert
                )

                renameAlert.addTextField { textField in
                    textField.placeholder = "New Name"
                    textField.text = file.name
                    textField.autocorrectionType = .no
                }

                renameAlert.addAction(UIAlertAction(title: "Save", style: .default) { _ in
                    let newName = renameAlert.textFields?.first?.text ?? file.name
                    api.renameFile(fileID: file.id, name: newName) { _ in }
                    self.viewModel.files[indexPath.row].name = newName
                    self.tableView.reloadData()
                })

                renameAlert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
                self.present(renameAlert, animated: true)
            }

            let moveButton = UIAlertAction(title: "Move", style: .default) { _ in
                handler(true)
                self.moveFiles([file])
            }

            actionSheet.addAction(renameButton)
            actionSheet.addAction(moveButton)

            if file.type == .video || file.type == .audio {
                let openInVLCButton = UIAlertAction(title: "Play original in VLC", style: .default) { _ in
                    handler(true)
                    self.openInVLC(file)
                }

                actionSheet.addAction(openInVLCButton)
            }

            let cancelButton = UIAlertAction(title: "Cancel", style: .cancel) { _ in handler(false) }
            actionSheet.addAction(cancelButton)

            actionSheet.popoverPresentationController?.sourceView = cell
            actionSheet.popoverPresentationController?.sourceRect = CGRect(x: cell.frame.width, y: 0, width: 80, height: cell.frame.height)

            self.present(actionSheet, animated: true)
        }

        action.backgroundColor = UIColor.Putio.black
        return action
    }

    func contextualCopyAction(forRowAtIndexPath indexPath: IndexPath) -> UIContextualAction {
        let file = viewModel.files[indexPath.row]

        let action = UIContextualAction(style: .normal, title: "Copy") { _, _, handler in
            handler(true)
            self.stateMachine.transitionToState(.view("loading"))

            api.copyFile(fileID: file.id) { result in
                self.stateMachine.transitionToState(.none)

                switch result {
                case .failure(let error):
                    let errorAlert = UIAlertController(
                        title: "Oops, an error occurred :(",
                        message: error.localizedDescription,
                        preferredStyle: .alert
                    )

                    errorAlert.addAction(UIAlertAction(title: "Close", style: .cancel))
                    self.present(errorAlert, animated: true)

                case .success:
                    break
                }
            }
        }

        action.backgroundColor = UIColor.Putio.black
        return action
    }

    func contextualDownloadAction(forRowAtIndexPath indexPath: IndexPath) -> UIContextualAction {
        let file = viewModel.files[indexPath.row]
        let action: UIContextualAction

        if file.needConvert {
            action = UIContextualAction(style: .normal, title: "Convert and Download") { _, _, handler in
                self.presentVideoConversionView(for: file, intention: VideoConversionIntention.download)
                handler(true)
            }
        } else if let download = downloads?.first(where: { download in
            download.id == file.id && download.state == .completed
        }) {
            action = UIContextualAction(style: .normal, title: "Play Downloaded") { _, _, handler in
                self.presentDownloadedFile(download)
                handler(true)
            }
        } else {
            action = UIContextualAction(style: .normal, title: "Download") { _, _, handler in
                if file.type == .video {
                    VideoDownloadManager.sharedInstance.createDownload(from: file)
                } else {
                    AudioDownloadManager.sharedInstance.createDownload(from: file)
                }

                handler(true)
            }
        }

        action.backgroundColor = UIColor.darkGray
        return action
    }
}

extension FilesViewController: UITableViewDataSource {
    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        viewModel.files.count
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        guard let cell = tableView.dequeueReusableCell(withIdentifier: "fileReuse", for: indexPath) as? FilesTableViewCell else {
            InternalFailurePresenter.log("Unable to dequeue FilesTableViewCell")
            return UITableViewCell()
        }

        let file = viewModel.files[indexPath.row]
        let download = downloads?.first(where: { download in
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
        !viewModel.files[indexPath.row].isSharedRoot
    }

    func tableView(_ tableView: UITableView, willSelectRowAt indexPath: IndexPath) -> IndexPath? {
        if tableView.isEditing && viewModel.files[indexPath.row].isSharedRoot {
            return nil
        }

        return indexPath
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        if tableView.isEditing {
            updateSelectionState()
            return
        }

        let file = viewModel.files[indexPath.row]
        tableView.deselectRow(at: indexPath, animated: false)
        presentFile(file)
    }

    func tableView(_ tableView: UITableView, didDeselectRowAt indexPath: IndexPath) {
        if tableView.isEditing {
            updateSelectionState()
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
