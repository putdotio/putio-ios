import XCTest
@testable import Putio
@testable import PutioSDK
import RealmSwift

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

    // The mocked run leaves the cast button out, so the group has to collapse
    // to its single remaining target rather than reserve the empty half.
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

    func testDownloadsFailureSummaryCapsNamedItems() {
        let failures = [
            DownloadDeletionItem(id: 11, name: "First", fileType: .video),
            DownloadDeletionItem(id: 12, name: "Second", fileType: .audio),
            DownloadDeletionItem(id: 13, name: "Third", fileType: .video),
            DownloadDeletionItem(id: 14, name: "Fourth", fileType: .audio),
            DownloadDeletionItem(id: 15, name: "Fifth", fileType: .video)
        ]
        let more = String(format: NSLocalizedString("%d more", comment: ""), 2)

        XCTAssertEqual(
            DownloadsBulkDeletion.failureNamesSummary(failures),
            ["First", "Second", "Third", more].formatted(.list(type: .and))
        )
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

    func testDownloadDeletionReturnsFalseWhenDownloadIsMissing() {
        XCTAssertFalse(
            DownloadSupport.performDeletion(
                state: nil,
                cancelActiveDownload: { XCTFail("Missing downloads cannot be cancelled") },
                deleteLocalFile: {
                    XCTFail("Missing downloads cannot have local files deleted")
                    return .removed
                },
                deleteRecord: {
                    XCTFail("Missing downloads cannot have records deleted")
                    return true
                }
            )
        )
    }

    func testCompletedDownloadDeletionPreservesRecordWhenLocalFileDeletionFails() {
        var didDeleteRecord = false

        let didDelete = DownloadSupport.performDeletion(
            state: .completed,
            cancelActiveDownload: { XCTFail("Completed downloads do not need cancellation") },
            deleteLocalFile: { .failed },
            deleteRecord: {
                didDeleteRecord = true
                return true
            }
        )

        XCTAssertFalse(didDelete)
        XCTAssertFalse(didDeleteRecord)
    }

    func testCompletedDownloadDeletionPropagatesRecordFailure() {
        var didFinalizeLocalFileDeletion = false

        let didDelete = DownloadSupport.performDeletion(
            state: .completed,
            cancelActiveDownload: { XCTFail("Completed downloads do not need cancellation") },
            deleteLocalFile: { .removed },
            deleteRecord: { false },
            localFileDeletionDidSucceed: { didFinalizeLocalFileDeletion = true }
        )

        XCTAssertFalse(didDelete)
        XCTAssertFalse(didFinalizeLocalFileDeletion)
    }

    func testCompletedDownloadDeletionSucceedsAfterFileAndRecordDeletion() {
        var operations = [String]()

        let didDelete = DownloadSupport.performDeletion(
            state: .completed,
            cancelActiveDownload: { XCTFail("Completed downloads do not need cancellation") },
            deleteLocalFile: {
                operations.append("file")
                return .removed
            },
            deleteRecord: {
                operations.append("record")
                return true
            },
            localFileDeletionDidSucceed: { operations.append("metadata") }
        )

        XCTAssertTrue(didDelete)
        XCTAssertEqual(operations, ["file", "record", "metadata"])
    }

    func testActiveDownloadDeletionCancelsBeforeDeletingRecord() {
        var operations = [String]()

        let didDelete = DownloadSupport.performDeletion(
            state: .active,
            cancelActiveDownload: { operations.append("cancel") },
            deleteLocalFile: {
                XCTFail("Active downloads do not have completed files to delete")
                return .failed
            },
            deleteRecord: {
                operations.append("record")
                return true
            }
        )

        XCTAssertTrue(didDelete)
        XCTAssertEqual(operations, ["cancel", "record"])
    }

    func testLocalFileDeletionDistinguishesAbsentAndUnresolvedLocations() {
        XCTAssertEqual(
            DownloadSupport.deleteLocalFile(at: .none, context: #function),
            .noLocation
        )
        XCTAssertEqual(
            DownloadSupport.deleteLocalFile(at: .unresolved, context: #function),
            .unresolvedLocation
        )
    }

    func testPersistedLocalFileLocationDistinguishesAbsentMalformedAndResolvedValues() {
        let resolvedURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("resolved")

        XCTAssertEqual(
            DownloadSupport.localFileLocation(
                from: nil,
                as: String.self,
                resolve: { _ in resolvedURL }
            ),
            .none
        )
        XCTAssertEqual(
            DownloadSupport.localFileLocation(
                from: Data(),
                as: String.self,
                resolve: { _ in resolvedURL }
            ),
            .unresolved
        )
        XCTAssertEqual(
            DownloadSupport.localFileLocation(
                from: "persisted-path",
                as: String.self,
                resolve: { _ in nil }
            ),
            .unresolved
        )
        XCTAssertEqual(
            DownloadSupport.localFileLocation(
                from: "persisted-path",
                as: String.self,
                resolve: { _ in resolvedURL }
            ),
            .resolved(resolvedURL)
        )
    }

    func testLocalFileDeletionReportsMissingWhenResolvedFileDoesNotExist() {
        let missingURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("missing-\(UUID().uuidString)")

        XCTAssertEqual(
            DownloadSupport.deleteLocalFile(at: .resolved(missingURL), context: #function),
            .alreadyMissing
        )
    }

    func testLocalFileDeletionRemovesExistingFile() throws {
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("download-\(UUID().uuidString)")
        try Data("offline".utf8).write(to: fileURL)

        XCTAssertEqual(
            DownloadSupport.deleteLocalFile(at: .resolved(fileURL), context: #function),
            .removed
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path))
    }

    func testCompletedDownloadDeletionPreservesRecordWhenLocationCannotBeResolved() {
        var didDeleteRecord = false

        let didDelete = DownloadSupport.performDeletion(
            state: .completed,
            cancelActiveDownload: { XCTFail("Completed downloads do not need cancellation") },
            deleteLocalFile: { .noLocation },
            deleteRecord: {
                didDeleteRecord = true
                return true
            }
        )

        XCTAssertFalse(didDelete)
        XCTAssertFalse(didDeleteRecord)
    }

    func testCompletedDownloadWithKnownMissingFileCanDeleteItsRecord() {
        XCTAssertTrue(
            DownloadSupport.performDeletion(
                state: .completed,
                cancelActiveDownload: { XCTFail("Completed downloads do not need cancellation") },
                deleteLocalFile: { .alreadyMissing },
                deleteRecord: { true }
            )
        )
    }

    func testFailedDownloadWithoutLocalFileCanDeleteItsRecord() {
        XCTAssertTrue(
            DownloadSupport.performDeletion(
                state: .failed,
                cancelActiveDownload: { XCTFail("Failed downloads do not need cancellation") },
                deleteLocalFile: { .noLocation },
                deleteRecord: { true }
            )
        )
    }

    func testFailedDownloadPreservesRecordWhenPersistedLocationCannotBeResolved() {
        var didDeleteRecord = false

        let didDelete = DownloadSupport.performDeletion(
            state: .failed,
            cancelActiveDownload: { XCTFail("Failed downloads do not need cancellation") },
            deleteLocalFile: { .unresolvedLocation },
            deleteRecord: {
                didDeleteRecord = true
                return true
            }
        )

        XCTAssertFalse(didDelete)
        XCTAssertFalse(didDeleteRecord)
    }

    func testDownloadSelectionAvailabilityHintExplainsRecovery() {
        let viewController = DownloadsViewController()

        XCTAssertEqual(
            viewController.selectionAvailabilityAccessibilityHint(
                hasCompletedDownloads: true,
                needsRecovery: true
            ),
            NSLocalizedString("Restore offline downloads before selecting items.", comment: "")
        )
        XCTAssertEqual(
            viewController.selectionAvailabilityAccessibilityHint(
                hasCompletedDownloads: false,
                needsRecovery: false
            ),
            NSLocalizedString("No completed downloads are available to select.", comment: "")
        )
    }

    func testDownloadCellAccessibilityDescribesSelectionAndUnavailableState() {
        let cell = makeDownloadCell()
        cell.titleLabel.text = "Episode"
        cell.subtitleLabel.text = "Downloading..."

        cell.configureSelectionAccessibility(isSelecting: true, isSelected: true, isSelectable: true)

        XCTAssertTrue(cell.isAccessibilityElement)
        XCTAssertEqual(cell.accessibilityLabel, "Episode, Downloading...")
        XCTAssertEqual(cell.accessibilityValue, NSLocalizedString("Selected", comment: ""))
        XCTAssertTrue(cell.accessibilityTraits.contains(.selected))

        cell.configureSelectionAccessibility(isSelecting: true, isSelected: false, isSelectable: false)

        XCTAssertEqual(cell.accessibilityValue, "Downloading...")
        XCTAssertEqual(
            cell.accessibilityHint,
            NSLocalizedString("Only completed downloads can be selected.", comment: "")
        )
        XCTAssertFalse(cell.accessibilityTraits.contains(.selected))
        XCTAssertTrue(cell.accessibilityTraits.contains(.notEnabled))

        cell.configureSelectionAccessibility(isSelecting: true, isSelected: false, isSelectable: true)

        XCTAssertFalse(cell.accessibilityTraits.contains(.notEnabled))

        cell.accessibilityTraits.insert([.selected, .notEnabled])
        cell.prepareForReuse()

        XCTAssertFalse(cell.accessibilityTraits.contains(.selected))
        XCTAssertFalse(cell.accessibilityTraits.contains(.notEnabled))
    }

    func testDownloadProgressPresentationRoundsAndClampsLocalizedPercentages() {
        let locale = Locale(identifier: "en_US")

        XCTAssertEqual(DownloadProgressPresentation.fraction(from: "0.474"), 0.474)
        XCTAssertEqual(DownloadProgressPresentation.fraction(from: "not-a-number"), 0)
        XCTAssertEqual(DownloadProgressPresentation.percentage(fraction: -0.1, locale: locale), "0%")
        XCTAssertEqual(DownloadProgressPresentation.percentage(fraction: 0.474, locale: locale), "47%")
        XCTAssertEqual(DownloadProgressPresentation.percentage(fraction: 0.995, locale: locale), "100%")
        XCTAssertEqual(DownloadProgressPresentation.percentage(fraction: 1.4, locale: locale), "100%")
        XCTAssertEqual(
            DownloadProgressPresentation.activeStatus(fraction: 0.474, locale: locale),
            "Downloading... 47%"
        )
    }

    func testActiveDownloadRestoresPercentageAndCombinedAccessibility() throws {
        let configuration = Realm.Configuration(inMemoryIdentifier: #function)
        let realm = try Realm(configuration: configuration)
        let download = Download()
        download.id = 108
        download.name = "Episode"
        download.state = .active
        download.progress = "0.47"
        try realm.write { realm.add(download) }

        let cell = makeDownloadCell(realm: realm)
        cell.configure(with: download.id)
        cell.configureSelectionAccessibility(isSelecting: false, isSelected: false, isSelectable: false)
        let expectedStatus = DownloadProgressPresentation.activeStatus(fraction: 0.47)

        XCTAssertEqual(cell.subtitleLabel.text, expectedStatus)
        XCTAssertTrue(cell.isAccessibilityElement)
        XCTAssertEqual(cell.accessibilityLabel, "Episode, \(expectedStatus)")
        XCTAssertEqual(
            cell.accessibilityHint,
            NSLocalizedString("Double tap to stop this download.", comment: "")
        )
        XCTAssertTrue(cell.accessibilityTraits.contains(.button))

        let restoredCell = makeDownloadCell(realm: realm)
        restoredCell.configure(with: download.id)

        XCTAssertEqual(restoredCell.subtitleLabel.text, expectedStatus)
        XCTAssertEqual(restoredCell.accessibilityLabel, "Episode, \(expectedStatus)")
    }

    func testQueuedAndStartingDownloadsDoNotShowPercentages() throws {
        let configuration = Realm.Configuration(inMemoryIdentifier: #function)
        let realm = try Realm(configuration: configuration)
        let download = Download()
        download.id = 109
        download.name = "Queued Episode"
        download.progress = "0.47"
        try realm.write { realm.add(download) }

        let cell = makeDownloadCell(realm: realm)

        let states = [
            (Download.State.queued, NSLocalizedString("In Queue", comment: "")),
            (.starting, NSLocalizedString("Starting...", comment: ""))
        ]

        for (state, expected) in states {
            try realm.write { download.state = state }
            cell.configure(with: download.id)

            XCTAssertEqual(cell.subtitleLabel.text, expected)
            XCTAssertFalse(cell.subtitleLabel.text?.contains("%") == true)
        }
    }

    func testDownloadCellAccessibilityActivationInvokesActionOutsideEditing() throws {
        let configuration = Realm.Configuration(inMemoryIdentifier: #function)
        let realm = try Realm(configuration: configuration)
        let download = Download()
        download.id = 110
        download.name = "Episode"
        download.state = .active
        download.progress = "0.47"
        try realm.write { realm.add(download) }

        let cell = makeDownloadCell(realm: realm)
        let delegate = DownloadCellDelegateSpy()
        cell.delegate = delegate
        cell.configure(with: download.id)

        XCTAssertTrue(cell.accessibilityActivate())
        XCTAssertEqual(delegate.activatedDownloadIDs, [download.id])

        cell.setEditing(true, animated: false)

        XCTAssertFalse(cell.accessibilityActivate())
        XCTAssertEqual(delegate.activatedDownloadIDs, [download.id])

        cell.setEditing(false, animated: false)
        cell.prepareForReuse()

        XCTAssertFalse(cell.accessibilityActivate())
        XCTAssertEqual(delegate.activatedDownloadIDs, [download.id])
    }

    func testDownloadCellAccessibilityHintsDescribeEveryStateAction() throws {
        let configuration = Realm.Configuration(inMemoryIdentifier: #function)
        let realm = try Realm(configuration: configuration)
        let download = Download()
        download.id = 111
        download.name = "Episode"
        try realm.write { realm.add(download) }
        let cell = makeDownloadCell(realm: realm)
        let states = [
            (Download.State.queued, NSLocalizedString("Double tap to stop this download.", comment: "")),
            (.starting, NSLocalizedString("Double tap to stop this download.", comment: "")),
            (.active, NSLocalizedString("Double tap to stop this download.", comment: "")),
            (.stopped, NSLocalizedString("Double tap to retry this download.", comment: "")),
            (.failed, NSLocalizedString("Double tap to retry this download.", comment: "")),
            (.completed, NSLocalizedString("Double tap to open this download.", comment: ""))
        ]

        for (state, expectedHint) in states {
            try realm.write { download.state = state }
            cell.configure(with: download.id)

            XCTAssertEqual(cell.accessibilityHint, expectedHint)
            XCTAssertTrue(cell.accessibilityTraits.contains(.button))
        }
    }

    func testDownloadsSelectionEditingControlsOnlyAppearForCompletedRows() throws {
        let configuration = Realm.Configuration(inMemoryIdentifier: #function)
        let realm = try Realm(configuration: configuration)
        let active = Download()
        active.id = 11
        active.state = .active
        active.createdAt = Date(timeIntervalSince1970: 1)
        let completed = Download()
        completed.id = 12
        completed.state = .completed
        completed.createdAt = Date(timeIntervalSince1970: 2)
        try realm.write {
            realm.add([active, completed])
        }

        let viewController = DownloadsViewController()
        viewController.downloads = realm.objects(Download.self).sorted(byKeyPath: "createdAt")
        let tableView = UITableView()
        viewController.tableView = tableView

        XCTAssertTrue(viewController.tableView(tableView, canEditRowAt: IndexPath(row: 0, section: 0)))

        tableView.setEditing(true, animated: false)

        XCTAssertFalse(viewController.tableView(tableView, canEditRowAt: IndexPath(row: 0, section: 0)))
        XCTAssertTrue(viewController.tableView(tableView, canEditRowAt: IndexPath(row: 1, section: 0)))
    }

    private func makeDownloadCell(realm: Realm? = nil) -> DownloadsTableViewCell {
        let cell = DownloadsTableViewCell()
        let icon = UIImageView()
        let titleLabel = UILabel()
        let subtitleLabel = UILabel()
        let buttonContainer = UIView()
        [icon, titleLabel, subtitleLabel, buttonContainer].forEach {
            cell.contentView.addSubview($0)
        }
        cell.icon = icon
        cell.titleLabel = titleLabel
        cell.subtitleLabel = subtitleLabel
        cell.downloadButtonContainer = buttonContainer
        cell.realm = realm
        return cell
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

private final class DownloadCellDelegateSpy: DownloadsTableViewCellDelegate {
    private(set) var activatedDownloadIDs: [Int] = []

    func downloadCellActionButtonTapped(download: Download, sender: DownloadsTableViewCell) {
        activatedDownloadIDs.append(download.id)
    }
}
