import XCTest
import PutioSDK
@testable import Putio

// Asserts the resolved *face* on surfaces the snapshot suite cannot speak for.
//
// A pixel comparison tells you two images match; it cannot tell you they match
// because a surface never adopted the brand font in the first place. That is
// exactly what happened: #54 bundled the licensed faces and re-recorded, and
// eight component baselines came back byte-identical. Some of those were fine
// (a control with no text cannot change), and some were a real gap nobody had
// a way to see.
//
// These tests name the face directly, so the gap fails by name.
@MainActor
final class BrandTypographyCoverageTests: XCTestCase {
    private static let sansFamily = "GT America"

    override func setUp() {
        super.setUp()
        BrandFont.registerIfAvailable()
    }

    // Mirrors ComponentSnapshotTests.assertComponent, so these assertions
    // measure the same state the visual baselines capture rather than a
    // detached view the app never renders. Branding itself does not depend on
    // this: the cells call configureGlobalAppearance from configure(_:), and a
    // nib-loaded view gets it from awakeFromNib.
    private func render(_ view: UIView, size: CGSize) {
        let window = UIWindow(frame: CGRect(origin: .zero, size: size))
        window.overrideUserInterfaceStyle = .dark
        view.frame = window.bounds
        window.addSubview(view)
        window.isHidden = false
        window.layoutIfNeeded()
    }

    // Verification builds bundle the faces (BrandFontTests pins that), so an
    // absent family here is a real failure rather than a reason to skip.
    private func assertBrandFace(
        _ font: UIFont?,
        _ surface: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard let font else {
            return XCTFail("\(surface) has no font at all", file: file, line: line)
        }

        XCTAssertEqual(
            font.familyName,
            Self.sansFamily,
            "\(surface) renders in \(font.familyName), not the brand face",
            file: file,
            line: line
        )
    }

    func testButtonTitleUsesBrandFace() {
        let button = Button(type: .custom)
        button.variant = "primary"
        button.setTitle("Log in", for: .normal)
        button.applyVariantStyle()
        // Layout is when UIKit would have a chance to reset the title font, so
        // check after it rather than immediately after applyVariantStyle().
        button.frame = CGRect(x: 0, y: 0, width: 240, height: 44)
        button.layoutIfNeeded()

        assertBrandFace(button.titleLabel?.font, "Button title")
    }

    func testHistoryCellUsesBrandFace() throws {
        let createdAt = ISO8601DateFormatter().string(from: Date().addingTimeInterval(-60 * 60 * 2))
        let json = #"{"id": 1, "user_id": 1, "type": "upload", "created_at": "\#(createdAt)", "file_id": 42, "file_name": "E2E Upload.mp4", "file_size": 7340032}"#
        let event = try JSONDecoder().decode(PutioUploadEvent.self, from: Data(json.utf8))

        let cell = HistoryTableViewCell(style: .subtitle, reuseIdentifier: "historyReuse")
        cell.configure(with: event)
        render(cell, size: CGSize(width: 375, height: 64))

        assertBrandFace(cell.textLabel?.font, "History cell title")
        assertBrandFace(cell.detailTextLabel?.font, "History cell subtitle")
    }

    func testTrashCellUsesBrandFace() throws {
        let json = #"{"id": 77, "name": "E2E Trashed Movie.mp4", "size": 7340032, "file_type": "VIDEO", "created_at": "2026-04-24T10:00:00Z", "updated_at": "2026-04-24T10:00:00Z", "deleted_at": "2026-07-14T10:00:00Z", "expiration_date": "2026-08-14T10:00:00Z"}"#
        let file = try JSONDecoder().decode(PutioTrashFile.self, from: Data(json.utf8))

        let cell = TrashTableViewCell(style: .value1, reuseIdentifier: "trashReuse")
        cell.configure(with: file)
        render(cell, size: CGSize(width: 375, height: 64))

        assertBrandFace(cell.textLabel?.font, "Trash cell title")
        assertBrandFace(cell.detailTextLabel?.font, "Trash cell detail")
    }
}
