import SnapshotTesting
import PutioSDK
import XCTest
@testable import Putio

// View-level visual baselines for reusable components in the app's dark-only
// appearance, stored under PutioTests/__Snapshots__/. Re-record intentionally
// with `mise run screenshots-record` and review the image diff.
@MainActor
final class ComponentSnapshotTests: XCTestCase {
    private var isRecording: Bool {
        ProcessInfo.processInfo.environment["PUTIO_RECORD_SNAPSHOTS"] == "1"
    }

    private func assertComponent(
        _ view: UIView,
        size: CGSize,
        named name: String,
        file: StaticString = #filePath,
        testName: String = "component",
        line: UInt = #line
    ) {
        for (label, style) in [("dark", UIUserInterfaceStyle.dark)] {
            let window = UIWindow(frame: CGRect(origin: .zero, size: size))
            window.overrideUserInterfaceStyle = style
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

    func testHistoryCell() throws {
        // Two hours back renders "2 hours ago" in every calendar; a fixed
        // date would drift through timeAgoSinceDate buckets over time.
        let createdAt = ISO8601DateFormatter().string(from: Date().addingTimeInterval(-60 * 60 * 2))
        let json = #"{"id": 1, "user_id": 1, "type": "upload", "created_at": "\#(createdAt)", "file_id": 42, "file_name": "E2E Upload.mp4", "file_size": 7340032}"#
        // The upload presentation requires the concrete subtype; decoding the
        // base PutioHistoryEvent would snapshot the No-title fallback instead
        // of a real upload row.
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
