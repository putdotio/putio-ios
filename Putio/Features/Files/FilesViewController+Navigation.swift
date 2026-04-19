import UIKit
import GoogleCast
import PutioSDK

extension FilesViewController {
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
        if fileActionsButton == nil {
            let button = createNavigationBarFileActionsButton()
            fileActionsButton = button

            let castButton = GCKUICastButton(frame: .zero)
            castButton.tintColor = UIColor.Putio.yellow
            castButton.frame = CGRect(x: 0, y: 0, width: 24, height: 24)
            chromecastButton = castButton
        }

        guard let fileActionsButton, let chromecastButton else {
            InternalFailurePresenter.log("Unable to configure navigation bar right buttons")
            return
        }

        let castBarButtonItem = UIBarButtonItem(customView: chromecastButton)
        navigationItem.rightBarButtonItems = [fileActionsButton, castBarButtonItem]
    }

    func setFileActionsEnabled(_ isEnabled: Bool) {
        fileActionsButton?.isEnabled = isEnabled
    }

    func configureFileActionsButtonMenuItems() {
        guard let parent = viewModel.file else { return }
        let children = viewModel.files

        let selectButton = UIAction(
            title: "Select",
            image: UIImage(systemName: "checkmark.circle")
        ) { _ in
            self.toggleTableEditing()
        }
        if children.isEmpty { selectButton.attributes = .disabled }

        let newFolderButton = UIAction(
            title: "New Folder",
            image: UIImage(systemName: "folder.badge.plus")
        ) { _ in
            let createFolderAlert = self.createFolderCreatorAlert(parentID: parent.id) { _, error in
                guard error == nil else { return }
                self.fetchData(withLoader: true)
            }

            self.present(createFolderAlert, animated: true)
        }

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

        let sortMenuItems = sortKeys.map { sortKey, label -> UIAction in
            let item = UIAction(
                title: label,
                identifier: UIAction.Identifier(sortKey)
            ) { _ in
                self.setSortSettings(nextSortKey: sortKey)
            }

            if sortKey == selectedSortKey {
                item.state = .on
                item.subtitle = selectedSortDirection == "ASC" ? "Ascending" : "Descending"
            }

            return item
        }

        let sortMenu = UIMenu(options: .displayInline, children: sortMenuItems)

        UIView.performWithoutAnimation {
            self.fileActionsButton?.menu = UIMenu(children: [
                selectButton,
                newFolderButton,
                sortMenu
            ])
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
            toolbar.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: 6)
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

    func moveFiles(_ files: [PutioFile]) {
        let storyboard = UIStoryboard(name: "MoveFiles", bundle: nil)
        guard let moveNC = storyboard.instantiateViewController(withIdentifier: "MoveNC", as: UINavigationController.self),
              let moveVC = moveNC.viewControllers.first as? MoveFilesViewController else {
            return InternalFailurePresenter.logAndPresent(
                on: self,
                logMessage: "Unable to instantiate MoveFiles flow"
            )
        }

        moveVC.filesToMove = files
        moveVC.delegate = self

        present(moveNC, animated: true)
    }
}
