import UIKit

// Retrofits every nib-loaded label onto the design-system type scale while
// keeping iOS Dynamic Type. Mirrors the awakeFromNib appearance convention
// used by UITableViewCell+Appearance and UITextField+Appearance.
//
// A complete no-op when the licensed faces are absent (verification builds
// exclude them): the label keeps exactly the font the nib set, so system-font
// snapshot baselines stay byte-identical.
extension UILabel {
    open override func awakeFromNib() {
        super.awakeFromNib()
        applyBrandFontIfAvailable()
    }

    // Also called for labels UIKit creates for us (e.g. a UIButton's
    // titleLabel), which never receive awakeFromNib.
    func applyBrandFontIfAvailable() {
        let descriptor = font.fontDescriptor

        if let styleName = descriptor.object(forKey: .textStyle) as? String {
            // Map the label's Apple text style onto the nearest design-system
            // role and adopt that role's font (size + weight + Dynamic Type).
            // An unrecognized style is left untouched rather than collapsed.
            guard let role = Self.brandRole(for: UIFont.TextStyle(rawValue: styleName)),
                  let brandFont = BrandTypography.fontIfAvailable(role) else { return }
            font = brandFont
            adjustsFontForContentSizeCategory = true
        } else {
            // Fixed-size labels (a UIButton's default title label, or a
            // fixed-point storyboard label) carry no text style, so match
            // their current point size and weight on the brand face.
            let weight = Self.brandWeight(from: descriptor)
            guard let brandFont = BrandFont.sansIfAvailable(size: font.pointSize, weight: weight) else { return }
            font = brandFont
        }
    }

    // Applies a design-system role's *full* styling to the label's current
    // text — font + Dynamic Type + tracking (kerning) + line height + optional
    // uppercasing — rather than the font alone. Because kerning and line height
    // live on attributedText, this must be called AFTER the text, colour, and
    // alignment are set: a later `text =` assignment would drop the styling.
    // Use it for labels whose text is set once in code (the nib hook stays
    // font-only, since nib text is typically replaced at runtime).
    //
    // A no-op when the licensed faces are absent (verification builds): the
    // label keeps exactly what the caller configured, so snapshot baselines
    // stay on their system fonts.
    func applyBrandStyle(_ role: BrandTypography.Role) {
        guard let style = BrandTypography.styleIfAvailable(role),
              let source = text, !source.isEmpty else { return }

        font = style.font
        adjustsFontForContentSizeCategory = true

        let paragraph = NSMutableParagraphStyle()
        // A multiple (not an absolute height), so it scales with the font under
        // Dynamic Type without any recomputation.
        paragraph.lineHeightMultiple = style.lineHeightMultiple
        paragraph.alignment = textAlignment
        paragraph.lineBreakMode = lineBreakMode

        let attributes: [NSAttributedString.Key: Any] = [
            .font: style.font,
            .paragraphStyle: paragraph,
            .foregroundColor: textColor as Any
        ]
        // The role's em-based tracking is deliberately NOT applied here: an
        // NSAttributedString kern is an absolute point value, and UIKit does not
        // rescale it when the content size category changes, so it would drift
        // out of proportion under Dynamic Type. Family, weight, size (scaled),
        // line height (a multiple), and uppercasing all track the size safely.
        let display = style.isUppercase ? source.localizedUppercase : source
        attributedText = NSAttributedString(string: display, attributes: attributes)
    }

    // Reads a font's weight from its descriptor. The weight trait is stored
    // as an NSNumber in the traits dictionary; a direct `as? CGFloat` cast
    // fails and would silently drop every fixed-size label to regular.
    static func brandWeight(from descriptor: UIFontDescriptor) -> UIFont.Weight {
        let traits = descriptor.object(forKey: .traits) as? [UIFontDescriptor.TraitKey: Any]
        let raw = (traits?[.weight] as? NSNumber)?.doubleValue ?? Double(UIFont.Weight.regular.rawValue)
        return UIFont.Weight(rawValue: CGFloat(raw))
    }

    // Apple text style → design-system role. Every iOS text style is mapped
    // explicitly; an unrecognized (e.g. future) style returns nil so the label
    // is left untouched rather than collapsed onto body. The auto hook never
    // resolves to the `label` role, whose uppercase treatment must be applied
    // deliberately rather than swept across every caption.
    private static func brandRole(for style: UIFont.TextStyle) -> BrandTypography.Role? {
        switch style {
        case .extraLargeTitle, .extraLargeTitle2: return .display
        case .largeTitle: return .h1
        case .title1: return .h2
        case .title2: return .h3
        case .title3, .headline: return .h4
        case .body, .callout, .subheadline: return .body
        case .footnote, .caption1, .caption2: return .small
        default: return nil
        }
    }
}
