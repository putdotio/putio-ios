import UIKit
@testable import Putio

// Shared specimen for the Type · Scale, used by the scaling test and the ramp
// renderer.
//
// The role → anchor map mirrors Config/TypeScale.json and must be kept in sync
// with it when roles are re-anchored.
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

    // A role's base size is its anchor's native size, so the anchor's scaled
    // size is exactly what a branded label resolves to. `compatibleWith:` is
    // required — the no-argument APIs read the screen's category, not this one.
    static func pointSize(for row: Row, category: UIContentSizeCategory) -> CGFloat {
        UIFont.preferredFont(
            forTextStyle: row.anchor,
            compatibleWith: UITraitCollection(preferredContentSizeCategory: category)
        ).pointSize
    }

    // The font a user sees for `role` at `category`. The brand face is built
    // fresh with UIFont(name:size:) rather than re-scaled from the production
    // font, which is already a UIFontMetrics font and cannot be fed back in.
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

    // A label rendered as production renders `role`, with live Dynamic Type
    // re-scaling enabled, to exercise the real adjusts wiring.
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
