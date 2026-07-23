import XCTest
@testable import Putio

// Reproducible generator for the Dynamic Type "scaling ramp" artifact: renders
// the Type · Scale specimen at a range of content size categories to PNGs, so
// the brand type can be seen growing with the system text-size setting.
//
// Inert in normal runs — it skips unless PUTIO_RAMP_OUT points at an output
// directory, so it never runs in CI and writes no snapshot baselines. To
// capture the *branded* ramp, bundle the licensed faces first (flip
// PUTIO_BUNDLE_BRAND_FONTS = YES in Config/Verify.xcconfig), then:
//
//   PUTIO_RAMP_OUT=/tmp/ramp make verify PUTIO_SIMULATOR_ID=<booted-udid>
//
// Without the faces it renders the system-font fallback (the same sizes).
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

        // Styling before/after at the default size: the font-only sheet above
        // (ramp-1-Default) versus the full design-system styling — tracking,
        // line height, and the uppercase `label` role.
        let styled = renderSheet(for: .large, styled: true)
        try XCTUnwrap(styled.pngData()).write(to: outDir.appendingPathComponent("style-full-Default.png"))
    }

    // A single specimen sheet at one content size category: role tag + resolved
    // point size on top, the sample below. `styled` applies the role's full
    // Style (tracking + line height + uppercasing) via attributedText, matching
    // UILabel.applyBrandStyle; otherwise the sample is font-only.
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
            if styled, let style = BrandTypography.styleIfAvailable(row.role) {
                let display = style.isUppercase ? row.sample.localizedUppercase : row.sample
                let paragraph = NSMutableParagraphStyle()
                paragraph.lineHeightMultiple = style.lineHeightMultiple
                var attributes: [NSAttributedString.Key: Any] = [.font: font, .paragraphStyle: paragraph, .foregroundColor: ink]
                // At the default size the sample equals the role's base size, so
                // the style's point-based tracking applies directly.
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
