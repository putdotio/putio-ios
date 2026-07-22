import UIKit

// Retro-fits every nib-loaded label onto the design-system type scale while
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
            let role = Self.brandRole(for: UIFont.TextStyle(rawValue: styleName))
            guard let brandFont = BrandTypography.fontIfAvailable(role) else { return }
            font = brandFont
            adjustsFontForContentSizeCategory = true
        } else {
            // Fixed-size labels (a UIButton's default title label, or a
            // fixed-point storyboard label) carry no text style, so match
            // their current point size on the brand face.
            let traits = descriptor.object(forKey: .traits) as? [UIFontDescriptor.TraitKey: Any]
            let weightValue = (traits?[.weight] as? CGFloat) ?? UIFont.Weight.regular.rawValue
            let weight = UIFont.Weight(rawValue: weightValue)
            guard let brandFont = BrandFont.sansIfAvailable(size: font.pointSize, weight: weight) else { return }
            font = brandFont
        }
    }

    // Apple text style → design-system role. The auto hook never resolves to
    // the `label` role, whose uppercase treatment must be applied deliberately
    // rather than swept across every caption.
    private static func brandRole(for style: UIFont.TextStyle) -> BrandTypography.Role {
        switch style {
        case .largeTitle: return .h1
        case .title1: return .h2
        case .title2: return .h3
        case .title3, .headline: return .h4
        case .footnote, .caption1, .caption2: return .small
        default: return .body // body, callout, subheadline, and any future style
        }
    }
}
