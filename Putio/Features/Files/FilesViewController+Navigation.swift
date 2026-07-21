import UIKit
import GoogleCast
import PutioSDK

extension FilesViewController {
    func createNavigationBarFileActionsButton() -> UIButton {
        let button = UIButton(type: .system)
        button.setImage(PutioIcon.dotsThreeCircle.image(for: .navigationBar), for: .normal)
        button.tintColor = UIColor.Putio.yellow
        button.accessibilityLabel = NSLocalizedString("More", comment: "")
        button.showsMenuAsPrimaryAction = true
        return button
    }

    func createNavigationBarActionGroup(
        chromecastButton: UIView,
        fileActionsButton: UIView
    ) -> UIBarButtonItem {
        let targetSize: CGFloat = 44
        [chromecastButton, fileActionsButton].forEach { button in
            button.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                button.widthAnchor.constraint(equalToConstant: targetSize),
                button.heightAnchor.constraint(equalToConstant: targetSize)
            ])
        }

        let stackView = UIStackView(arrangedSubviews: [chromecastButton, fileActionsButton])
        stackView.axis = .horizontal
        stackView.alignment = .center
        stackView.distribution = .fillEqually
        stackView.spacing = 0
        stackView.frame = CGRect(x: 0, y: 0, width: targetSize * 2, height: targetSize)
        return UIBarButtonItem(customView: stackView)
    }

    func configureNavigationBarRightButtons() {
        if fileActionsButton == nil {
            let button = createNavigationBarFileActionsButton()
            fileActionsButton = button

            let castButton = GCKUICastButton(frame: .zero)
            castButton.tintColor = UIColor.Putio.yellow
            chromecastButton = castButton
        }

        guard let fileActionsButton, let chromecastButton else {
            InternalFailurePresenter.log("Unable to configure navigation bar right buttons")
            return
        }

        if navigationActionsBarButtonItem == nil {
            navigationActionsBarButtonItem = createNavigationBarActionGroup(
                chromecastButton: chromecastButton,
                fileActionsButton: fileActionsButton
            )
        }
        navigationItem.rightBarButtonItem = navigationActionsBarButtonItem
    }

    func setFileActionsEnabled(_ isEnabled: Bool) {
        fileActionsButton?.isEnabled = isEnabled
    }

    func configureFileActionsButtonMenuItems() {
        guard let parent = viewModel.file else { return }
        let children = viewModel.files

        let selectButton = UIAction(
            title: NSLocalizedString("Select", comment: ""),
            image: PutioIcon.checkCircle.image
        ) { _ in
            self.toggleTableEditing()
        }
        if children.isEmpty { selectButton.attributes = .disabled }

        let newFolderButton = UIAction(
            title: NSLocalizedString("New Folder", comment: ""),
            image: PutioIcon.folderPlus.image
        ) { _ in
            let createFolderAlert = self.createFolderCreatorAlert(parentID: parent.id) { _, error in
                guard error == nil else { return }
                self.fetchData(withLoader: true)
            }

            self.present(createFolderAlert, animated: true)
        }

        let sortKeys: KeyValuePairs<String, String> = [
            "NAME": NSLocalizedString("Name", comment: ""),
            "SIZE": NSLocalizedString("Size", comment: ""),
            "DATE": NSLocalizedString("Date Added", comment: ""),
            "MODIFIED": NSLocalizedString("Date Modified", comment: ""),
            "TYPE": NSLocalizedString("Type", comment: ""),
            "WATCH": NSLocalizedString("Watch Status", comment: "")
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
                item.subtitle = selectedSortDirection == "ASC"
                    ? NSLocalizedString("Ascending", comment: "")
                    : NSLocalizedString("Descending", comment: "")
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

        let deleteTitle = userSettings.trashEnabled
            ? NSLocalizedString("Trash", comment: "")
            : NSLocalizedString("Delete", comment: "")
        let moveBtn = UIBarButtonItem(
            title: NSLocalizedString("Move", comment: ""),
            style: .plain,
            target: self,
            action: #selector(moveSelectedFiles)
        )
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
