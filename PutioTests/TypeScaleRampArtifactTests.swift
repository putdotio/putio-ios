import XCTest
@testable import Putio

// Renders the Type · Scale specimen across content size categories to PNGs, as
// a visual artifact of Dynamic Type scaling.
//
// Inert unless PUTIO_RAMP_OUT points at an output directory, so it never runs
// in CI and writes no baselines:
//
//   PUTIO_RAMP_OUT=/tmp/ramp PUTIO_SIMULATOR_ID=<booted-udid> mise run verify
//
// Without the licensed faces it renders the same sizes in the system font.
@MainActor
final class TypeScaleRampArtifactTests: XCTestCase {
    private struct Step {
        let category: UIContentSizeCategory
        let name: String
    }

    private let ramp: [Step] = [
        Step(category: .extraSmall, name: "XS"),
        Step(category: .large, name: "Default"),
        Step(category: .extraExtraExtraLarge, name: "XXXL"),
        Step(category: .accessibilityExtraExtraExtraLarge, name: "AX-XXXL")
    ]

    func testRenderTypeScaleRamp() throws {
        let outPath = ProcessInfo.processInfo.environment["PUTIO_RAMP_OUT"]
        try XCTSkipIf(outPath == nil, "set PUTIO_RAMP_OUT to render the scaling ramp artifact")
        let outDir = URL(fileURLWithPath: outPath!, isDirectory: true)
        try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

        var written = 0
        for (index, step) in ramp.enumerated() {
            let image = renderSheet(for: step.category)
            let data = try XCTUnwrap(image.pngData(), "sheet must encode to PNG")
            let url = outDir.appendingPathComponent(String(format: "ramp-%d-%@.png", index, step.name))
            try data.write(to: url)
            written += 1
        }
        XCTAssertEqual(written, ramp.count, "every ramp step must produce a PNG")

        // The font-only sheet above (ramp-1-Default) against the full styling:
        // tracking, line height, and the uppercase `label` role.
        let styled = renderSheet(for: .large, styled: true)
        try XCTUnwrap(styled.pngData()).write(to: outDir.appendingPathComponent("style-full-Default.png"))
    }

    // One specimen sheet at one content size category. `styled` applies the
    // role's full Style via attributedText, matching UILabel.applyBrandStyle;
    // otherwise the sample is font-only.
    private func renderSheet(for category: UIContentSizeCategory, styled: Bool = false) -> UIImage {
        let width: CGFloat = 420
        let margin: CGFloat = 24
        let contentWidth = width - margin * 2
        let ink = UIColor(white: 0.10, alpha: 1)
        let muted = UIColor(white: 0.55, alpha: 1)

        let container = UIView()
        container.overrideUserInterfaceStyle = .light
        container.backgroundColor = .white

        var y = margin
        for row in TypeScaleSpecimen.rows {
            let font = TypeScaleSpecimen.font(for: row, category: category)

            let tag = UILabel()
            tag.text = "\(row.role)  ·  \(Int(font.pointSize.rounded()))pt"
            tag.font = .systemFont(ofSize: 11, weight: .medium)
            tag.textColor = muted
            place(tag, in: container, x: margin, y: &y, width: contentWidth, gap: 3)

            let sample = UILabel()
            sample.numberOfLines = 0
            sample.textColor = ink
            let traits = UITraitCollection(preferredContentSizeCategory: category)
            if styled, let style = BrandTypography.styleIfAvailable(row.role, compatibleWith: traits) {
                let display = style.isUppercase ? row.sample.localizedUppercase : row.sample
                let paragraph = NSMutableParagraphStyle()
                paragraph.lineHeightMultiple = style.lineHeightMultiple
                var attributes: [NSAttributedString.Key: Any] = [.font: font, .paragraphStyle: paragraph, .foregroundColor: ink]
                // Same requested category as `font`, so the trait-scaled kern
                // matches the rendered size whatever the simulator's ambient
                // content-size setting is.
                if style.tracking != 0 { attributes[.kern] = style.tracking }
                sample.attributedText = NSAttributedString(string: display, attributes: attributes)
            } else {
                sample.font = font
                sample.text = row.sample
            }
            place(sample, in: container, x: margin, y: &y, width: contentWidth, gap: 18)
        }

        container.frame = CGRect(x: 0, y: 0, width: width, height: y + margin - 18)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 3
        return UIGraphicsImageRenderer(bounds: container.bounds, format: format).image { _ in
            container.drawHierarchy(in: container.bounds, afterScreenUpdates: true)
        }
    }

    private func place(_ label: UILabel, in parent: UIView, x: CGFloat, y: inout CGFloat, width: CGFloat, gap: CGFloat) {
        let fit = label.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude))
        label.frame = CGRect(x: x, y: y, width: width, height: ceil(fit.height))
        parent.addSubview(label)
        y += ceil(fit.height) + gap
    }
}
