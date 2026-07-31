import XCTest
import PutioSDK
@testable import Putio

// Asserts the resolved *face* on surfaces the snapshot suite cannot speak for.
//
// A pixel comparison can tell you two images match; it cannot tell you they
// match because the surface never adopted the brand font at all. Naming the
// face directly is what turns that silent gap into a failure.
@MainActor
final class BrandTypographyCoverageTests: XCTestCase {
    private static let sansFamily = "GT America"

    override func setUp() {
        super.setUp()
        BrandFont.registerIfAvailable()
    }

    // Mirrors ComponentSnapshotTests.assertComponent, so these assertions measure
    // the same state the visual baselines capture, not a detached view.
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
        weight: UIFont.Weight? = nil,
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

        // The family alone cannot catch a weight regression, which is the live
        // failure mode: a system font descriptor reports regular whatever it
        // renders at, so a derived weight silently demotes the title.
        guard let weight else { return }
        guard let expected = BrandFont.sansIfAvailable(size: font.pointSize, weight: weight) else {
            return XCTFail("no brand face for weight \(weight.rawValue)", file: file, line: line)
        }

        XCTAssertEqual(
            font.fontName,
            expected.fontName,
            "\(surface) renders in \(font.fontName), not \(expected.fontName)",
            file: file,
            line: line
        )
    }

    func testButtonTitleUsesBrandFace() {
        let button = Button(type: .custom)
        button.variant = "primary"
        button.setTitle("Log in", for: .normal)
        button.applyVariantStyle()
        // Layout is UIKit's chance to reset the title font, so assert after it.
        button.frame = CGRect(x: 0, y: 0, width: 240, height: 44)
        button.layoutIfNeeded()

        assertBrandFace(button.titleLabel?.font, "Button title", weight: .medium)
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
