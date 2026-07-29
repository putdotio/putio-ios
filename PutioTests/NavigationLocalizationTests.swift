import XCTest
@testable import Putio
@testable import PutioSDK

final class NavigationLocalizationTests: XCTestCase {
    func testEveryPutioIconResolvesToA16PointTemplateAsset() throws {
        for icon in PutioIcon.allCases {
            let image = try XCTUnwrap(icon.image, "Missing asset for \(icon.assetName)")
            XCTAssertEqual(image.size, CGSize(width: 16, height: 16), icon.assetName)
        }
    }

    func testPutioIconCanRenderForTabBarPresentation() throws {
        let image = try XCTUnwrap(PutioIcon.folder.image(for: .tabBar))
        XCTAssertEqual(image.size, CGSize(width: 24, height: 24))
        XCTAssertEqual(image.renderingMode, .alwaysTemplate)
    }

    func testNavigationListPresentationUses20PointGlyphIn24PointCanvas() throws {
        XCTAssertEqual(PutioIconPresentation.navigationList.glyphPointSize, 20)
        XCTAssertEqual(PutioIconPresentation.navigationList.canvasPointSize, 24)

        let image = try XCTUnwrap(PutioIcon.folder.image(for: .navigationList))
        XCTAssertEqual(image.size, CGSize(width: 24, height: 24))
        XCTAssertEqual(image.renderingMode, .alwaysTemplate)
    }

    func testFileActionsButtonUsesNavigationBarIconPresentation() throws {
        let button = FilesViewController().createNavigationBarFileActionsButton()
        let image = try XCTUnwrap(button.image(for: .normal))

        XCTAssertEqual(image.size, CGSize(width: 24, height: 24))
        XCTAssertEqual(image.renderingMode, .alwaysTemplate)
        XCTAssertEqual(button.accessibilityLabel, NSLocalizedString("More", comment: ""))
        XCTAssertTrue(button.showsMenuAsPrimaryAction)
    }

    func testNavigationBarActionGroupUsesAdjacent44PointTargets() throws {
        let viewController = FilesViewController()
        let castButton = UIButton(type: .system)
        let fileActionsButton = viewController.createNavigationBarFileActionsButton()
        let item = viewController.createNavigationBarActionGroup(
            chromecastButton: castButton,
            fileActionsButton: fileActionsButton
        )
        let stackView = try XCTUnwrap(item.customView as? UIStackView)

        stackView.layoutIfNeeded()

        XCTAssertEqual(stackView.spacing, 0)
        XCTAssertEqual(stackView.frame.size, CGSize(width: 88, height: 44))
        XCTAssertEqual(castButton.frame.size, CGSize(width: 44, height: 44))
        XCTAssertEqual(fileActionsButton.frame.size, CGSize(width: 44, height: 44))
        XCTAssertEqual(fileActionsButton.center.x - castButton.center.x, 44)
    }

    // The mocked e2e run leaves the cast button out, since it only appears when
    // the Cast SDK finds a receiver on the LAN. The group has to collapse to the
    // single remaining target rather than reserve the empty half.
    func testNavigationBarActionGroupCollapsesWithoutCastButton() throws {
        let viewController = FilesViewController()
        let fileActionsButton = viewController.createNavigationBarFileActionsButton()
        let item = viewController.createNavigationBarActionGroup(
            chromecastButton: nil,
            fileActionsButton: fileActionsButton
        )
        let stackView = try XCTUnwrap(item.customView as? UIStackView)

        stackView.layoutIfNeeded()

        XCTAssertEqual(stackView.arrangedSubviews.count, 1)
        XCTAssertEqual(stackView.frame.size, CGSize(width: 44, height: 44))
        XCTAssertEqual(fileActionsButton.frame.size, CGSize(width: 44, height: 44))
    }

    func testAccountSettingsUseSemanticPhosphorIcons() throws {
        let items = SettingsViewModel().buildSections().flatMap(\.items)

        XCTAssertEqual(
            items.first { $0.title == NSLocalizedString("Show subtitles", comment: "") }?.icon,
            .closedCaptioning
        )
        XCTAssertEqual(
            items.first { $0.title == NSLocalizedString("View your two-factor recovery codes", comment: "") }?.icon,
            .key
        )
        XCTAssertEqual(
            items.first { $0.title == NSLocalizedString("Where you are logged in", comment: "") }?.icon,
            .devices
        )
    }

    func testConfigureFileActionsButtonMenuItemsUsesLocalizedTitles() throws {
        let viewController = FilesViewController()
        viewController.fileActionsButton = viewController.createNavigationBarFileActionsButton()
        viewController.viewModel.file = try makeFolder(id: 1, name: "Folder", sortBy: "NAME_ASC")
        viewController.viewModel.files = [try makeFile(id: 2, name: "Video", type: "VIDEO")]

        viewController.configureFileActionsButtonMenuItems()

        let menu = try XCTUnwrap(viewController.fileActionsButton?.menu)
        let selectAction = try XCTUnwrap(menu.children.first as? UIAction)
        XCTAssertEqual(selectAction.title, NSLocalizedString("Select", comment: ""))
        XCTAssertFalse(selectAction.attributes.contains(.disabled))

        let newFolderAction = try XCTUnwrap(menu.children.dropFirst().first as? UIAction)
        XCTAssertEqual(newFolderAction.title, NSLocalizedString("New Folder", comment: ""))

        let sortMenu = try XCTUnwrap(menu.children.last as? UIMenu)
        let sortActions = sortMenu.children.compactMap { $0 as? UIAction }
        let selectedAction = try XCTUnwrap(sortActions.first(where: { $0.state == .on }))
        XCTAssertEqual(selectedAction.title, NSLocalizedString("Name", comment: ""))
        XCTAssertEqual(selectedAction.subtitle, NSLocalizedString("Ascending", comment: ""))
    }

    func testConfigureToolbarUsesLocalizedMoveAndTrashTitles() throws {
        let viewController = FilesViewController()
        let userSettings = UserSettings()
        userSettings.trashEnabled = true
        viewController.userSettings = userSettings
        viewController.view = UIView(frame: CGRect(x: 0, y: 0, width: 320, height: 640))

        viewController.configureToolbar()

        let items = try XCTUnwrap(viewController.editingToolbar?.items)
        XCTAssertEqual(items[0].title, NSLocalizedString("Move", comment: ""))
        XCTAssertEqual(items[2].title, NSLocalizedString("Trash", comment: ""))
    }

    func testConfigureToolbarUsesLocalizedDeleteTitleWhenTrashDisabled() throws {
        let viewController = FilesViewController()
        let userSettings = UserSettings()
        userSettings.trashEnabled = false
        viewController.userSettings = userSettings
        viewController.view = UIView(frame: CGRect(x: 0, y: 0, width: 320, height: 640))

        viewController.configureToolbar()

        let items = try XCTUnwrap(viewController.editingToolbar?.items)
        XCTAssertEqual(items[2].title, NSLocalizedString("Delete", comment: ""))
    }

    func testAuthAppsContextualDeleteActionUsesLocalizedRevokeTitle() {
        let viewController = AuthAppsTableViewController(style: .insetGrouped)

        let action = viewController.contextualDeleteAction(forRowAtIndexPath: IndexPath(row: 0, section: 0))

        XCTAssertEqual(action.title, NSLocalizedString("Revoke", comment: ""))
        XCTAssertEqual(action.backgroundColor, UIColor.Putio.Red.solid)
    }

    func testDownloadsSelectionStateOnlySelectsCompletedDownloads() {
        var selection = DownloadsSelectionState()

        selection.select(11, isCompleted: true)
        selection.select(12, isCompleted: false)

        XCTAssertEqual(selection.selectedIDs, Set([11]))
        XCTAssertTrue(selection.hasSelectedAll([11]))
        XCTAssertFalse(selection.hasSelectedAll([11, 12]))

        selection.selectAll([11, 13])
        XCTAssertEqual(selection.selectedIDs, Set([11, 13]))

        selection.retain([13])
        XCTAssertEqual(selection.selectedIDs, Set([13]))
    }

    func testDownloadsBulkDeletionAttemptsEveryItemAndReturnsOnlyFailures() {
        let items = [
            DownloadDeletionItem(id: 11, name: "First", fileType: .video),
            DownloadDeletionItem(id: 12, name: "Second", fileType: .audio),
            DownloadDeletionItem(id: 13, name: "Third", fileType: .video)
        ]
        var attemptedIDs = [Int]()

        let failures = DownloadsBulkDeletion.failures(deleting: items) { id, _ in
            attemptedIDs.append(id)
            return id != 12
        }

        XCTAssertEqual(attemptedIDs, [11, 12, 13])
        XCTAssertEqual(failures, [items[1]])
    }

    func testDownloadsBulkDeleteAccessibilityLabelDescribesSelectedCount() {
        let viewController = DownloadsViewController()

        XCTAssertEqual(
            viewController.bulkDeleteAccessibilityLabel(count: 1),
            NSLocalizedString("Delete 1 selected download", comment: "")
        )
        XCTAssertEqual(
            viewController.bulkDeleteAccessibilityLabel(count: 3),
            String(format: NSLocalizedString("Delete %d selected downloads", comment: ""), 3)
        )
    }

    func testDownloadCellAccessibilityDescribesSelectionAndUnavailableState() {
        let cell = DownloadsTableViewCell()
        let titleLabel = UILabel()
        let subtitleLabel = UILabel()
        let container = UIView()
        cell.contentView.addSubview(titleLabel)
        cell.contentView.addSubview(subtitleLabel)
        cell.contentView.addSubview(container)
        cell.titleLabel = titleLabel
        cell.subtitleLabel = subtitleLabel
        cell.downloadButtonContainer = container
        titleLabel.text = "Episode"
        subtitleLabel.text = "Downloading..."

        cell.configureSelectionAccessibility(isSelecting: true, isSelected: true, isSelectable: true)

        XCTAssertTrue(cell.isAccessibilityElement)
        XCTAssertEqual(cell.accessibilityLabel, "Episode")
        XCTAssertEqual(cell.accessibilityValue, NSLocalizedString("Selected", comment: ""))
        XCTAssertTrue(cell.accessibilityTraits.contains(.selected))

        cell.configureSelectionAccessibility(isSelecting: true, isSelected: false, isSelectable: false)

        XCTAssertEqual(cell.accessibilityValue, "Downloading...")
        XCTAssertEqual(
            cell.accessibilityHint,
            NSLocalizedString("Only completed downloads can be selected.", comment: "")
        )
        XCTAssertFalse(cell.accessibilityTraits.contains(.selected))
    }

    private func makeFolder(id: Int, name: String, sortBy: String) throws -> PutioFile {
        return try makePutioFile([
                "id": id,
                "name": name,
                "icon": "folder",
                "parent_id": 0,
                "file_type": "FOLDER",
                "size": 0,
                "created_at": "2026-04-20T00:00:00Z",
                "updated_at": "2026-04-20T00:00:00Z",
                "is_shared": false,
                "folder_type": "REGULAR",
                "sort_by": sortBy
            ]
        )
    }

    private func makeFile(id: Int, name: String, type: String) throws -> PutioFile {
        return try makePutioFile([
                "id": id,
                "name": name,
                "icon": "file",
                "parent_id": 1,
                "file_type": type,
                "size": 1024,
                "created_at": "2026-04-20T00:00:00Z",
                "updated_at": "2026-04-20T00:00:00Z",
                "is_shared": false
            ]
        )
    }

    private func makePutioFile(_ payload: [String: Any]) throws -> PutioFile {
        let data = try JSONSerialization.data(withJSONObject: payload)
        return try JSONDecoder().decode(PutioFile.self, from: data)
    }
}
