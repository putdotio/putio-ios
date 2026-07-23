import UIKit
@testable import Putio

// Shared specimen for the design-system Type · Scale, used by the scaling test
// and (when generating visual artifacts) by the ramp renderer.
//
// The role → anchor map mirrors Config/TypeScale.json: each role's iOS base
// size is its anchor text style's native point size, and Dynamic Type scaling
// flows through UIFontMetrics(forTextStyle: anchor). Keep this in sync with the
// vendored scale if roles are re-anchored.
enum TypeScaleSpecimen {
    struct Row {
        let role: BrandTypography.Role
        let anchor: UIFont.TextStyle
        let sample: String
    }

    static let rows: [Row] = [
        Row(role: .display, anchor: .largeTitle, sample: "put.io"),
        Row(role: .h1,      anchor: .largeTitle, sample: "Downloads"),
        Row(role: .h2,      anchor: .title1,     sample: "Your Files"),
        Row(role: .h3,      anchor: .title2,     sample: "Transfers"),
        Row(role: .h4,      anchor: .title3,     sample: "Subsection header"),
        Row(role: .body,    anchor: .body,       sample: "The quick brown fox jumps over the lazy dog."),
        Row(role: .small,   anchor: .footnote,   sample: "Secondary and helper text."),
        Row(role: .label,   anchor: .caption1,   sample: "Section label"),
        Row(role: .numeric, anchor: .title3,     sample: "1,234.56 GB"),
        Row(role: .code,    anchor: .footnote,   sample: "GET /files/list")
    ]

    // The resolved point size for `role` at `category`. UIFontMetrics scales a
    // role by its anchor text style's Dynamic Type curve, and the role's base
    // size *is* that anchor's native size, so the anchor's scaled size is
    // exactly the size a branded label resolves to. The `compatibleWith:`
    // variant is used deliberately: the no-argument preferredFont/scaledFont
    // APIs read the screen's content size category, not a supplied one.
    static func pointSize(for row: Row, category: UIContentSizeCategory) -> CGFloat {
        UIFont.preferredFont(
            forTextStyle: row.anchor,
            compatibleWith: UITraitCollection(preferredContentSizeCategory: category)
        ).pointSize
    }

    // A deterministic snapshot of the font a user sees for `role` at `category`:
    // the brand face (when the licensed faces are present) at the size above,
    // or the anchor's system text style otherwise. Builds the brand face fresh
    // with UIFont(name:size:) rather than re-scaling the production font, which
    // is already a UIFontMetrics font and cannot be fed back into the metrics.
    static func font(for row: Row, category: UIContentSizeCategory) -> UIFont {
        let size = pointSize(for: row, category: category)
        if let brand = BrandTypography.fontIfAvailable(row.role),
           let named = UIFont(name: brand.fontName, size: size) {
            return named
        }
        return UIFont.preferredFont(
            forTextStyle: row.anchor,
            compatibleWith: UITraitCollection(preferredContentSizeCategory: category)
        )
    }

    // A label rendered exactly as production renders `role`: the branded font
    // when available, the anchor's system style otherwise, with live Dynamic
    // Type re-scaling enabled. Used to exercise the real adjusts wiring.
    static func label(for row: Row) -> UILabel {
        let label = UILabel()
        label.numberOfLines = 0
        label.text = row.sample
        label.font = BrandTypography.fontIfAvailable(row.role)
            ?? UIFont.preferredFont(forTextStyle: row.anchor)
        label.adjustsFontForContentSizeCategory = true
        return label
    }
}
