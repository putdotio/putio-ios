import UIKit

struct DownloadsSelectionState {
    private(set) var selectedIDs = Set<Int>()

    var count: Int {
        selectedIDs.count
    }

    func contains(_ id: Int) -> Bool {
        selectedIDs.contains(id)
    }

    func hasSelectedAll(_ selectableIDs: [Int]) -> Bool {
        !selectableIDs.isEmpty && selectedIDs == Set(selectableIDs)
    }

    mutating func select(_ id: Int, isCompleted: Bool) {
        guard isCompleted else { return }
        selectedIDs.insert(id)
    }

    mutating func deselect(_ id: Int) {
        selectedIDs.remove(id)
    }

    mutating func selectAll(_ selectableIDs: [Int]) {
        selectedIDs = Set(selectableIDs)
    }

    mutating func retain(_ ids: [Int]) {
        selectedIDs.formIntersection(ids)
    }

    mutating func clear() {
        selectedIDs.removeAll()
    }
}

struct DownloadDeletionItem: Equatable {
    let id: Int
    let name: String
    let fileType: Download.FileType
}

enum DownloadsBulkDeletion {
    static func failures(
        deleting items: [DownloadDeletionItem],
        with delete: (Int, Download.FileType) -> Bool
    ) -> [DownloadDeletionItem] {
        items.filter { !delete($0.id, $0.fileType) }
    }
}

extension DownloadsViewController {
    var completedDownloadIDs: [Int] {
        downloads?
            .filter { $0.state == .completed }
            .map(\.id) ?? []
    }

    func selectedDeletionItems() -> [DownloadDeletionItem] {
        downloads?
            .filter { self.selectionState.contains($0.id) && $0.state == .completed }
            .map {
                DownloadDeletionItem(id: $0.id, name: $0.name, fileType: $0.fileType)
            } ?? []
    }

    func configureEditingToolbar() {
        let toolbar = UIToolbar()
        toolbar.translatesAutoresizingMaskIntoConstraints = false
        toolbar.tintColor = UIColor.Putio.Red.solid

        let appearance = UIToolbarAppearance()
        appearance.configureWithTransparentBackground()
        toolbar.standardAppearance = appearance
        toolbar.compactAppearance = appearance

        let deleteButton = UIBarButtonItem(
            title: NSLocalizedString("Delete", comment: ""),
            style: .plain,
            target: self,
            action: #selector(confirmSelectedDownloadsDeletion)
        )
        deleteButton.isEnabled = false
        toolbar.items = [
            UIBarButtonItem(barButtonSystemItem: .flexibleSpace, target: nil, action: nil),
            deleteButton
        ]
        toolbar.isHidden = true

        view.addSubview(toolbar)
        NSLayoutConstraint.activate([
            toolbar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            toolbar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            toolbar.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: 6)
        ])

        bulkDeleteButton = deleteButton
        editingToolbar = toolbar
    }

    func updateTableInsets() {
        let toolbarHeight = editingToolbar?.isHidden == false ? 44.0 : 0.0
        let contentInset = UIEdgeInsets(top: 0, left: 0, bottom: toolbarHeight, right: 0)
        tableView.contentInset = contentInset
        tableView.scrollIndicatorInsets = contentInset
    }

    @objc func startSelectingDownloads() {
        guard !completedDownloadIDs.isEmpty else { return }

        tableView.setEditing(true, animated: true)
        navigationItem.title = NSLocalizedString("Select Items", comment: "")
        navigationItem.leftBarButtonItem = UIBarButtonItem(
            title: NSLocalizedString("Select All", comment: ""),
            style: .plain,
            target: self,
            action: #selector(toggleSelectAllDownloads)
        )
        navigationItem.rightBarButtonItems = [
            UIBarButtonItem(
                title: NSLocalizedString("Done", comment: ""),
                style: .plain,
                target: self,
                action: #selector(stopSelectingDownloads)
            )
        ]

        editingToolbar?.isHidden = false
        tabBarController?.setTabBarHidden(true, animated: true)
        updateTableInsets()
        updateSelectionUI()
        restoreSelectedRows()
    }

    @objc func stopSelectingDownloads() {
        guard !isDeletingSelectedDownloads else { return }

        selectionState.clear()
        tableView.setEditing(false, animated: true)
        editingToolbar?.isHidden = true
        tabBarController?.setTabBarHidden(false, animated: true)
        navigationItem.leftBarButtonItem = nil
        navigationItem.title = NSLocalizedString("Downloads", comment: "")
        configureNavigationBarButtons()
        updateTableInsets()
        updateVisibleCellAccessibility()
    }

    @objc func toggleSelectAllDownloads() {
        let selectableIDs = completedDownloadIDs
        if selectionState.hasSelectedAll(selectableIDs) {
            selectionState.clear()
        } else {
            selectionState.selectAll(selectableIDs)
        }

        restoreSelectedRows()
        updateSelectionUI()
    }

    func updateSelectionUI() {
        guard tableView.isEditing else { return }

        switch selectionState.count {
        case 0:
            navigationItem.title = NSLocalizedString("Select Items", comment: "")
        case 1:
            navigationItem.title = NSLocalizedString("1 Item", comment: "")
        default:
            navigationItem.title = String(
                format: NSLocalizedString("%d Items", comment: ""),
                selectionState.count
            )
        }

        navigationItem.leftBarButtonItem?.title = selectionState.hasSelectedAll(completedDownloadIDs)
            ? NSLocalizedString("Deselect All", comment: "")
            : NSLocalizedString("Select All", comment: "")

        bulkDeleteButton?.isEnabled = selectionState.count > 0 && !isDeletingSelectedDownloads
        bulkDeleteButton?.accessibilityLabel = bulkDeleteAccessibilityLabel(count: selectionState.count)
    }

    func bulkDeleteAccessibilityLabel(count: Int) -> String {
        if count == 1 {
            return NSLocalizedString("Delete 1 selected download", comment: "")
        }

        return String(
            format: NSLocalizedString("Delete %d selected downloads", comment: ""),
            count
        )
    }

    func updateSelectionAvailability() {
        let hasCompletedDownloads = !completedDownloadIDs.isEmpty
        let needsRecovery = PutioRealm.needsDownloadRecovery
        let canSelect = hasCompletedDownloads && !needsRecovery
        selectButton?.isEnabled = canSelect
        selectButton?.accessibilityHint = selectionAvailabilityAccessibilityHint(
            hasCompletedDownloads: hasCompletedDownloads,
            needsRecovery: needsRecovery
        )
    }

    func selectionAvailabilityAccessibilityHint(
        hasCompletedDownloads: Bool,
        needsRecovery: Bool
    ) -> String {
        if needsRecovery {
            return NSLocalizedString("Restore offline downloads before selecting items.", comment: "")
        }

        if hasCompletedDownloads {
            return NSLocalizedString("Enters selection mode for completed downloads.", comment: "")
        }

        return NSLocalizedString("No completed downloads are available to select.", comment: "")
    }

    func reconcileSelectionAfterDownloadsChange() {
        selectionState.retain(completedDownloadIDs)

        if tableView.isEditing && completedDownloadIDs.isEmpty && !isDeletingSelectedDownloads {
            stopSelectingDownloads()
        } else {
            updateSelectionUI()
        }
    }

    func restoreSelectedRows() {
        guard tableView.isEditing else {
            updateVisibleCellAccessibility()
            return
        }

        for row in 0..<tableView.numberOfRows(inSection: 0) {
            let indexPath = IndexPath(row: row, section: 0)
            guard let download = downloads?[row] else { continue }

            if selectionState.contains(download.id) {
                tableView.selectRow(at: indexPath, animated: false, scrollPosition: .none)
            } else {
                tableView.deselectRow(at: indexPath, animated: false)
            }

            if let cell = tableView.cellForRow(at: indexPath) as? DownloadsTableViewCell {
                configureSelectionAccessibility(for: cell, download: download)
            }
        }
    }

    func updateVisibleCellAccessibility() {
        for case let cell as DownloadsTableViewCell in tableView.visibleCells {
            guard let id = cell.id,
                  let download = downloads?.first(where: { $0.id == id }) else {
                continue
            }
            configureSelectionAccessibility(for: cell, download: download)
        }
    }

    func configureSelectionAccessibility(for cell: DownloadsTableViewCell, download: Download) {
        cell.configureSelectionAccessibility(
            isSelecting: tableView.isEditing,
            isSelected: selectionState.contains(download.id),
            isSelectable: download.state == .completed
        )
    }

    @objc func confirmSelectedDownloadsDeletion() {
        let items = selectedDeletionItems()
        guard !items.isEmpty else { return }

        let title: String
        if items.count == 1 {
            title = NSLocalizedString("Delete 1 Download?", comment: "")
        } else {
            title = String(
                format: NSLocalizedString("Delete %d Downloads?", comment: ""),
                items.count
            )
        }

        let alert = UIAlertController(
            title: title,
            message: NSLocalizedString("The selected downloads will be removed from this device.", comment: ""),
            preferredStyle: .actionSheet
        )
        alert.addAction(UIAlertAction(
            title: NSLocalizedString("Delete", comment: ""),
            style: .destructive
        ) { [weak self] _ in
            self?.deleteSelectedDownloads(items)
        })
        alert.addAction(UIAlertAction(title: NSLocalizedString("Cancel", comment: ""), style: .cancel))
        alert.popoverPresentationController?.sourceView = editingToolbar

        present(alert, animated: true)
    }

    func deleteSelectedDownloads(_ items: [DownloadDeletionItem]) {
        guard !items.isEmpty, !isDeletingSelectedDownloads else { return }

        isDeletingSelectedDownloads = true
        tableView.isUserInteractionEnabled = false
        navigationItem.leftBarButtonItem?.isEnabled = false
        navigationItem.rightBarButtonItems?.forEach { $0.isEnabled = false }
        bulkDeleteButton?.title = NSLocalizedString("Deleting...", comment: "")
        updateSelectionUI()

        let deleteDownload = self.deleteDownload
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let failures = DownloadsBulkDeletion.failures(deleting: items, with: deleteDownload)

            DispatchQueue.main.async {
                guard let self else { return }

                self.isDeletingSelectedDownloads = false
                self.tableView.isUserInteractionEnabled = true
                self.navigationItem.leftBarButtonItem?.isEnabled = true
                self.navigationItem.rightBarButtonItems?.forEach { $0.isEnabled = true }
                self.bulkDeleteButton?.title = NSLocalizedString("Delete", comment: "")
                self.selectionState.retain(failures.map(\.id))

                if failures.isEmpty {
                    if self.tableView.isEditing {
                        self.stopSelectingDownloads()
                    } else {
                        self.updateSelectionAvailability()
                    }
                } else {
                    self.restoreSelectedRows()
                    self.updateSelectionUI()
                    self.presentDeletionFailure(for: failures)
                }
            }
        }
    }

    func presentDeletionFailure(for failures: [DownloadDeletionItem]) {
        guard !failures.isEmpty else { return }

        let title: String
        if failures.count == 1 {
            title = NSLocalizedString("Couldn't Delete 1 Download", comment: "")
        } else {
            title = String(
                format: NSLocalizedString("Couldn't Delete %d Downloads", comment: ""),
                failures.count
            )
        }

        let names = ListFormatter.localizedString(byJoining: failures.map(\.name))
        let message: String
        if tableView.isEditing {
            message = String(
                format: NSLocalizedString("%@ couldn't be deleted. The failed downloads remain selected so you can retry.", comment: ""),
                names
            )
        } else {
            message = String(
                format: NSLocalizedString("%@ couldn't be deleted. Please try again.", comment: ""),
                names
            )
        }

        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(
            title: NSLocalizedString("Retry", comment: ""),
            style: .destructive
        ) { [weak self] _ in
            self?.deleteSelectedDownloads(failures)
        })
        alert.addAction(UIAlertAction(title: NSLocalizedString("Close", comment: ""), style: .cancel))
        present(alert, animated: true)
    }
}
