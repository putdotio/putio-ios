import UIKit

extension FilesViewController {
    func file(at indexPath: IndexPath) -> PutioFile? {
        guard viewModel.files.indices.contains(indexPath.row) else { return nil }
        return viewModel.files[indexPath.row]
    }

    func contextualDeleteAction(for file: PutioFile, at indexPath: IndexPath) -> UIContextualAction {
        guard let cell = tableView.cellForRow(at: indexPath) else {
            InternalFailurePresenter.log("Unable to access file cell for delete action at row \(indexPath.row)")
            return UIContextualAction(
                style: .destructive,
                title: userSettings.trashEnabled ? NSLocalizedString("Trash", comment: "") : NSLocalizedString("Delete", comment: "")
            ) { _, _, handler in
                handler(false)
            }
        }

        let action = UIContextualAction(
            style: .destructive,
            title: userSettings.trashEnabled ? NSLocalizedString("Trash", comment: "") : NSLocalizedString("Delete", comment: "")
        ) { _, _, handler in
            func deleteFile(_ completion: @escaping (Bool) -> Void) {
                let loadingAlert = UIAlertController(
                    title: self.userSettings.trashEnabled
                        ? NSLocalizedString("Moving to trash...", comment: "")
                        : NSLocalizedString("Deleting...", comment: ""),
                    message: "",
                    preferredStyle: .alert
                )

                self.present(loadingAlert, animated: true)

                api.deleteFile(fileID: file.id) { result in
                    loadingAlert.dismiss(animated: true) {
                        switch result {
                        case .success:
                            if let row = self.viewModel.files.firstIndex(where: { $0.id == file.id }) {
                                self.viewModel.files.remove(at: row)
                                self.tableView.deleteRows(at: [IndexPath(row: row, section: indexPath.section)], with: .automatic)
                            }
                            completion(true)

                        case .failure(let error):
                            let errorAlert = UIAlertController(
                                title: NSLocalizedString("Oops, an error occurred", comment: ""),
                                message: error.message,
                                preferredStyle: .alert
                            )

                            errorAlert.addAction(UIAlertAction(title: NSLocalizedString("Close", comment: ""), style: .cancel))
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
                title: String(
                    format: NSLocalizedString("Are you sure you want to delete %@?", comment: ""),
                    file.name
                ),
                message: nil,
                preferredStyle: .actionSheet
            )

            let deleteButton = UIAlertAction(title: NSLocalizedString("Delete", comment: ""), style: .destructive) { _ in
                deleteFile { result in handler(result) }
            }
            let cancelButton = UIAlertAction(title: NSLocalizedString("Cancel", comment: ""), style: .cancel) { _ in handler(false) }

            actionSheet.addAction(deleteButton)
            actionSheet.addAction(cancelButton)
            actionSheet.popoverPresentationController?.sourceView = cell
            actionSheet.popoverPresentationController?.sourceRect = CGRect(x: cell.frame.width, y: 0, width: 80, height: cell.frame.height)

            self.present(actionSheet, animated: true)
        }

        action.backgroundColor = UIColor.Putio.Red.solid
        return action
    }

    func contextualMoreAction(for file: PutioFile, at indexPath: IndexPath) -> UIContextualAction {
        guard let cell = tableView.cellForRow(at: indexPath) else {
            InternalFailurePresenter.log("Unable to access file cell for more action at row \(indexPath.row)")
            return UIContextualAction(style: .normal, title: NSLocalizedString("More", comment: "")) { _, _, handler in
                handler(false)
            }
        }

        let action = UIContextualAction(style: .normal, title: NSLocalizedString("More", comment: "")) { _, _, handler in
            let actionSheet = UIAlertController(title: file.name, message: nil, preferredStyle: .actionSheet)

            let renameButton = UIAlertAction(title: NSLocalizedString("Rename", comment: ""), style: .default) { _ in
                handler(true)

                let renameAlert = UIAlertController(
                    title: String(
                        format: NSLocalizedString("Rename %@", comment: ""),
                        file.name
                    ),
                    message: nil,
                    preferredStyle: .alert
                )

                renameAlert.addTextField { textField in
                    textField.placeholder = NSLocalizedString("New Name", comment: "")
                    textField.text = file.name
                    textField.autocorrectionType = .no
                }

                renameAlert.addAction(UIAlertAction(title: NSLocalizedString("Save", comment: ""), style: .default) { _ in
                    let newName = renameAlert.textFields?.first?.text ?? file.name
                    api.renameFile(fileID: file.id, name: newName) { _ in }
                    file.name = newName
                    self.tableView.reloadData()
                })

                renameAlert.addAction(UIAlertAction(title: NSLocalizedString("Cancel", comment: ""), style: .cancel))
                self.present(renameAlert, animated: true)
            }

            let moveButton = UIAlertAction(title: NSLocalizedString("Move", comment: ""), style: .default) { _ in
                handler(true)
                self.moveFiles([file])
            }

            actionSheet.addAction(renameButton)
            actionSheet.addAction(moveButton)

            if file.type == .video || file.type == .audio {
                let openInVLCButton = UIAlertAction(title: NSLocalizedString("Play original in VLC", comment: ""), style: .default) { _ in
                    handler(true)
                    self.openInVLC(file)
                }

                actionSheet.addAction(openInVLCButton)
            }

            let cancelButton = UIAlertAction(title: NSLocalizedString("Cancel", comment: ""), style: .cancel) { _ in handler(false) }
            actionSheet.addAction(cancelButton)

            actionSheet.popoverPresentationController?.sourceView = cell
            actionSheet.popoverPresentationController?.sourceRect = CGRect(x: cell.frame.width, y: 0, width: 80, height: cell.frame.height)

            self.present(actionSheet, animated: true)
        }

        action.backgroundColor = UIColor.Putio.Neutral.componentBg
        return action
    }

    func contextualCopyAction(for file: PutioFile) -> UIContextualAction {
        let action = UIContextualAction(style: .normal, title: NSLocalizedString("Copy", comment: "")) { _, _, handler in
            handler(true)
            self.stateMachine.transitionToState(.view("loading"))

            api.copyFile(fileID: file.id) { result in
                self.stateMachine.transitionToState(.none)

                switch result {
                case .failure(let error):
                    let errorAlert = UIAlertController(
                        title: NSLocalizedString("Oops, an error occurred :(", comment: ""),
                        message: error.localizedDescription,
                        preferredStyle: .alert
                    )

                    errorAlert.addAction(UIAlertAction(title: NSLocalizedString("Close", comment: ""), style: .cancel))
                    self.present(errorAlert, animated: true)

                case .success:
                    break
                }
            }
        }

        action.backgroundColor = UIColor.Putio.Neutral.componentBg
        return action
    }

    func contextualDownloadAction(for file: PutioFile) -> UIContextualAction {
        let action: UIContextualAction

        if file.needConvert {
            action = UIContextualAction(style: .normal, title: NSLocalizedString("Convert and Download", comment: "")) { _, _, handler in
                self.presentVideoConversionView(for: file, intention: VideoConversionIntention.download)
                handler(true)
            }
        } else if let download = downloads?.first(where: { download in
            download.id == file.id && download.state == .completed
        }) {
            action = UIContextualAction(style: .normal, title: NSLocalizedString("Play Downloaded", comment: "")) { _, _, handler in
                self.presentDownloadedFile(download)
                handler(true)
            }
        } else {
            action = UIContextualAction(style: .normal, title: NSLocalizedString("Download", comment: "")) { _, _, handler in
                if file.type == .video {
                    VideoDownloadManager.sharedInstance.createDownload(from: file)
                } else {
                    AudioDownloadManager.sharedInstance.createDownload(from: file)
                }

                handler(true)
            }
        }

        action.backgroundColor = UIColor.Putio.Neutral.solid
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

        guard let file = file(at: indexPath) else { return cell }
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
        guard let file = file(at: indexPath) else { return false }
        return !file.isSharedRoot
    }

    func tableView(_ tableView: UITableView, willSelectRowAt indexPath: IndexPath) -> IndexPath? {
        guard let file = file(at: indexPath) else { return nil }
        if tableView.isEditing && file.isSharedRoot {
            return nil
        }

        return indexPath
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        if tableView.isEditing {
            updateSelectionState()
            return
        }

        tableView.deselectRow(at: indexPath, animated: false)
        guard let file = file(at: indexPath) else { return }
        presentFile(file)
    }

    func tableView(_ tableView: UITableView, didDeselectRowAt indexPath: IndexPath) {
        if tableView.isEditing {
            updateSelectionState()
        }
    }

    func tableView(_ tableView: UITableView, trailingSwipeActionsConfigurationForRowAt indexPath: IndexPath) -> UISwipeActionsConfiguration? {
        guard let file = file(at: indexPath) else { return nil }

        var actions = file.isShared ? [
            contextualCopyAction(for: file)
        ] : [
            contextualDeleteAction(for: file, at: indexPath),
            contextualMoreAction(for: file, at: indexPath)
        ]

        if file.type == .video || file.type == .audio {
            actions.insert(contextualDownloadAction(for: file), at: 1)
        }

        if file.isSharedRoot {
            actions = []
        }

        let configuration = UISwipeActionsConfiguration(actions: actions)
        configuration.performsFirstActionWithFullSwipe = false
        return configuration
    }
}
