import UIKit
import PutioSDK

extension FilesViewController {
    @objc func toggleTableEditing() {
        if tableView.isEditing {
            stopEditing()
        } else {
            startEditing()
        }
    }

    func startEditing() {
        showEditingToolbar()
        updateTableInsets()

        tableView.setEditing(true, animated: true)

        navigationItem.setHidesBackButton(true, animated: true)
        navigationItem.leftBarButtonItem = UIBarButtonItem(
            title: NSLocalizedString("Select All", comment: ""),
            style: .plain,
            target: self,
            action: #selector(toggleSelectAll)
        )

        navigationItem.title = NSLocalizedString("Select Items", comment: "")
        navigationItem.rightBarButtonItem = UIBarButtonItem(
            title: NSLocalizedString("Done", comment: ""),
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

    func getSelectedFiles() -> [PutioFile] {
        let indexPaths = tableView.indexPathsForSelectedRows ?? []
        return indexPaths.map { viewModel.files[$0.row] }
    }

    func updateSelectionState() {
        allSelected = getSelectedFiles().count == viewModel.getSelectableFiles().count
        updateNavigationBarState()
        updateToolbarActions()
    }

    @objc func toggleSelectAll() {
        if allSelected {
            deselectAll()
        } else {
            selectAll()
        }
    }

    func selectAll() {
        for section in 0..<tableView.numberOfSections {
            for row in 0..<tableView.numberOfRows(inSection: section) {
                let selectableFiles = viewModel.getSelectableFiles()
                if selectableFiles.contains(where: { $0.id == self.viewModel.files[row].id }) {
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

    func updateNavigationBarState() {
        guard tableView.isEditing else { return }

        let count = getSelectedFiles().count
        if count == 0 {
            navigationItem.title = NSLocalizedString("Select Items", comment: "")
        } else if count == 1 {
            navigationItem.title = NSLocalizedString("1 Item", comment: "")
        } else {
            navigationItem.title = String(
                format: NSLocalizedString("%d Items", comment: ""),
                count
            )
        }

        navigationItem.leftBarButtonItems?[0].title = allSelected
            ? NSLocalizedString("Deselect All", comment: "")
            : NSLocalizedString("Select All", comment: "")
    }

    func updateToolbarActions() {
        let isEnabled = !getSelectedFiles().isEmpty
        editingToolbar?.items?.forEach { $0.isEnabled = isEnabled }
    }

    func deleteFiles(fileIDs: [Int]) {
        stateMachine.transitionToState(.view("loading"))

        api.deleteFiles(fileIDs: fileIDs) { result in
            switch result {
            case .success:
                self.fetchData()

            case .failure(let error):
                self.stateMachine.transitionToState(.none)

                let errorAlert = UIAlertController(
                    title: NSLocalizedString("Oops, an error occurred :(", comment: ""),
                    message: error.message,
                    preferredStyle: .alert
                )

                errorAlert.addAction(UIAlertAction(title: NSLocalizedString("Close", comment: ""), style: .cancel))
                self.present(errorAlert, animated: true)
            }
        }
    }

    @objc func deleteSelectedFiles() {
        let selectedFiles = getSelectedFiles()

        if userSettings.trashEnabled {
            stopEditing()
            deleteFiles(fileIDs: selectedFiles.map { $0.id })
            return
        }

        let messageItem = selectedFiles.count > 1
            ? String(format: NSLocalizedString("%d files", comment: ""), selectedFiles.count)
            : selectedFiles[0].name

        let actionSheet = UIAlertController(
            title: String(
                format: NSLocalizedString("Are you sure you want to delete %@?", comment: ""),
                messageItem
            ),
            message: nil,
            preferredStyle: .actionSheet
        )

        let deleteButton = UIAlertAction(title: NSLocalizedString("Delete", comment: ""), style: .destructive) { _ in
            self.stopEditing()
            self.deleteFiles(fileIDs: selectedFiles.map { $0.id })
        }

        actionSheet.addAction(deleteButton)
        actionSheet.addAction(UIAlertAction(title: NSLocalizedString("Cancel", comment: ""), style: .cancel))
        actionSheet.popoverPresentationController?.sourceView = editingToolbar

        present(actionSheet, animated: true)
    }

    @objc func moveSelectedFiles() {
        moveFiles(getSelectedFiles())
    }
}
