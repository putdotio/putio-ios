import SnapshotTesting
import PutioSDK
import RealmSwift
import XCTest
@testable import Putio

// View-level visual baselines under PutioTests/__Snapshots__/. Re-record
// intentionally with `mise run screenshots-record` and review the image diff.
@MainActor
final class ComponentSnapshotTests: XCTestCase {
    private var isRecording: Bool {
        ProcessInfo.processInfo.environment["PUTIO_RECORD_SNAPSHOTS"] == "1"
    }

    private func assertComponent(
        _ view: UIView,
        size: CGSize,
        named name: String,
        contentSizeCategory: UIContentSizeCategory? = nil,
        file: StaticString = #filePath,
        testName: String = "component",
        line: UInt = #line
    ) {
        for (label, style) in [("dark", UIUserInterfaceStyle.dark)] {
            let window = UIWindow(frame: CGRect(origin: .zero, size: size))
            window.overrideUserInterfaceStyle = style
            if let contentSizeCategory {
                window.traitOverrides.preferredContentSizeCategory = contentSizeCategory
            }
            window.backgroundColor = UIColor.Putio.Surface.appBg
            view.frame = window.bounds
            window.addSubview(view)
            window.isHidden = false
            window.layoutIfNeeded()

            assertSnapshot(
                of: window,
                as: .image(precision: 0.995, perceptualPrecision: 0.98),
                named: "\(label)-\(name)",
                record: isRecording,
                file: file,
                testName: testName,
                line: line
            )

            view.removeFromSuperview()
            window.isHidden = true
        }
    }

    private func selfSizingHeight(
        for cell: UITableViewCell,
        width: CGFloat,
        contentSizeCategory: UIContentSizeCategory
    ) -> CGFloat {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: width, height: 1_000))
        window.traitOverrides.preferredContentSizeCategory = contentSizeCategory
        cell.frame = window.bounds
        window.addSubview(cell)
        window.isHidden = false
        window.layoutIfNeeded()

        let size = cell.contentView.systemLayoutSizeFitting(
            CGSize(width: width, height: UIView.layoutFittingCompressedSize.height),
            withHorizontalFittingPriority: .required,
            verticalFittingPriority: .fittingSizeLevel
        )

        cell.removeFromSuperview()
        window.isHidden = true
        return ceil(size.height)
    }

    func testButtonVariants() {
        for variant in ["primary", "secondary", "danger"] {
            let button = Button(type: .custom)
            button.variant = variant
            button.setTitle("Log in", for: .normal)
            button.applyVariantStyle()
            assertComponent(button, size: CGSize(width: 240, height: 44), named: "button-\(variant)")
        }
    }

    func testEmptyStateView() {
        let view = EmptyStateView.instantiateFromInterfaceBuilder()
        view.configure(
            heading: NSLocalizedString("Your history is empty", comment: ""),
            description: NSLocalizedString("There will be information when things start happening.", comment: "")
        )
        assertComponent(view, size: CGSize(width: 375, height: 320), named: "empty-state")
    }

    func testDownloadsEmptyStateView() {
        let view = DownloadsEmptyStateView.instantiateFromInterfaceBuilder()
        assertComponent(view, size: CGSize(width: 375, height: 320), named: "downloads-empty-state")
    }

    func testOfflineStatusView() {
        let view = OfflineStatusView.instantiateFromInterfaceBuilder()
        assertComponent(view, size: CGSize(width: 375, height: 320), named: "offline-status")
    }

    func testDownloadStateButtonStates() {
        let states: [(String, DownloadStateButton.DisplayState)] = [
            ("idle", .idle),
            ("progress", .progress(0.4)),
            ("completed", .completed)
        ]

        for (label, state) in states {
            let button = DownloadStateButton(frame: CGRect(x: 0, y: 0, width: 44, height: 44))
            button.displayState = state
            assertComponent(button, size: CGSize(width: 44, height: 44), named: "download-state-\(label)")
        }
    }

    func testDownloadCellStatesAndAccessibilityTextSize() throws {
        let storyboard = UIStoryboard(name: "Main", bundle: Bundle(for: DownloadsViewController.self))
        let tabBarController = try XCTUnwrap(
            storyboard.instantiateViewController(withIdentifier: "MainTabBarController") as? UITabBarController
        )
        let downloadsViewController = try XCTUnwrap(
            tabBarController.viewControllers?
                .compactMap { $0 as? UINavigationController }
                .flatMap(\.viewControllers)
                .compactMap { $0 as? DownloadsViewController }
                .first
        )
        downloadsViewController.loadViewIfNeeded()

        let configuration = Realm.Configuration(inMemoryIdentifier: #function)
        let realm = try Realm(configuration: configuration)
        let states: [(Download.State, String, String, String)] = [
            (.queued, "Queued Episode.mp4", "0.47", ""),
            (.active, "Active Episode.mp4", "0.47", ""),
            (.failed, "Failed Episode.mp4", "0.47", "Network unavailable"),
            (.completed, "Completed Episode.mp4", "1", "")
        ]

        try realm.write {
            for (index, state) in states.enumerated() {
                let download = Download()
                download.id = 200 + index
                download.name = state.1
                download.size = 7340032
                download.state = state.0
                download.progress = state.2
                download.message = state.3
                download.completedAt = state.0 == .completed
                    ? Date().addingTimeInterval(-2 * 60 * 60)
                    : nil
                realm.add(download)
            }
        }

        func makeCell(for index: Int) throws -> DownloadsTableViewCell {
            let cell = try XCTUnwrap(
                downloadsViewController.tableView.dequeueReusableCell(
                    withIdentifier: "downloadsReuse"
                ) as? DownloadsTableViewCell
            )
            cell.realm = realm
            cell.configure(with: 200 + index)
            cell.configureSelectionAccessibility(
                isSelecting: false,
                isSelected: false,
                isSelectable: false
            )
            return cell
        }

        let statesView = UIView()
        var previous: UIView?
        for index in states.indices {
            let cell = try makeCell(for: index)
            cell.translatesAutoresizingMaskIntoConstraints = false
            statesView.addSubview(cell)
            NSLayoutConstraint.activate([
                cell.leadingAnchor.constraint(equalTo: statesView.leadingAnchor),
                cell.trailingAnchor.constraint(equalTo: statesView.trailingAnchor),
                cell.heightAnchor.constraint(equalToConstant: 60),
                cell.topAnchor.constraint(equalTo: previous?.bottomAnchor ?? statesView.topAnchor)
            ])
            previous = cell
        }

        assertComponent(
            statesView,
            size: CGSize(width: 375, height: 240),
            named: "download-cell-states"
        )

        let accessibilityCell = try makeCell(for: 1)
        let accessibilityWidth: CGFloat = 375
        let accessibilityHeight = selfSizingHeight(
            for: accessibilityCell,
            width: accessibilityWidth,
            contentSizeCategory: .accessibilityLarge
        )
        XCTAssertGreaterThan(accessibilityHeight, 60)
        assertComponent(
            accessibilityCell,
            size: CGSize(width: accessibilityWidth, height: accessibilityHeight),
            named: "download-cell-active-accessibility-large",
            contentSizeCategory: .accessibilityLarge
        )
    }

    func testHistoryCell() throws {
        // Relative, not fixed: a fixed date drifts through timeAgoSinceDate
        // buckets as time passes.
        let createdAt = ISO8601DateFormatter().string(from: Date().addingTimeInterval(-60 * 60 * 2))
        let json = #"{"id": 1, "user_id": 1, "type": "upload", "created_at": "\#(createdAt)", "file_id": 42, "file_name": "E2E Upload.mp4", "file_size": 7340032}"#
        // The concrete subtype is required; the base PutioHistoryEvent would
        // snapshot the No-title fallback instead of a real upload row.
        let event = try JSONDecoder().decode(PutioUploadEvent.self, from: Data(json.utf8))

        let cell = HistoryTableViewCell(style: .subtitle, reuseIdentifier: "historyReuse")
        cell.configure(with: event)
        XCTAssertEqual(cell.textLabel?.text, "E2E Upload.mp4", "cell should render the upload, not the fallback")
        assertComponent(cell, size: CGSize(width: 375, height: 64), named: "history-cell-upload")
    }

    func testTrashCell() throws {
        let json = #"{"id": 77, "name": "E2E Trashed Movie.mp4", "size": 7340032, "file_type": "VIDEO", "created_at": "2026-04-24T10:00:00Z", "updated_at": "2026-04-24T10:00:00Z", "deleted_at": "2026-07-14T10:00:00Z", "expiration_date": "2026-08-14T10:00:00Z"}"#
        let file = try JSONDecoder().decode(PutioTrashFile.self, from: Data(json.utf8))

        let cell = TrashTableViewCell(style: .value1, reuseIdentifier: "trashReuse")
        cell.configure(with: file)
        assertComponent(cell, size: CGSize(width: 375, height: 64), named: "trash-cell")
    }
}
