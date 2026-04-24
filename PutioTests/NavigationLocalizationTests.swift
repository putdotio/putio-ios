import XCTest
@testable import Putio
@testable import PutioSDK

final class NavigationLocalizationTests: XCTestCase {
    func testConfigureFileActionsButtonMenuItemsUsesLocalizedTitles() throws {
        let viewController = FilesViewController()
        viewController.fileActionsButton = viewController.createNavigationBarFileActionsButton()
        viewController.viewModel.file = makeFolder(id: 1, name: "Folder", sortBy: "NAME_ASC")
        viewController.viewModel.files = [makeFile(id: 2, name: "Video", type: "VIDEO")]

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
        XCTAssertEqual(action.backgroundColor, .systemRed)
    }

    private func makeFolder(id: Int, name: String, sortBy: String) -> PutioFile {
        return makePutioFile([
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

    private func makeFile(id: Int, name: String, type: String) -> PutioFile {
        return makePutioFile([
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

    private func makePutioFile(_ payload: [String: Any]) -> PutioFile {
        let data = try! JSONSerialization.data(withJSONObject: payload)
        return try! JSONDecoder().decode(PutioFile.self, from: data)
    }
}
