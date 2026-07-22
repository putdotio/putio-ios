import UIKit

// Retro-fits every nib-loaded label onto the brand face while keeping the
// Dynamic Type text style it was designed with. Mirrors the awakeFromNib
// appearance convention used by UITableViewCell+Appearance and
// UITextField+Appearance.
//
// A complete no-op when the licensed fonts are absent (verification builds
// exclude them), so the label's font is left exactly as the nib set it and
// system-font snapshot baselines stay byte-identical.
extension UILabel {
    open override func awakeFromNib() {
        super.awakeFromNib()
        applyBrandFontIfAvailable()
    }

    // Also called for labels UIKit creates for us (e.g. a UIButton's
    // titleLabel), which never receive awakeFromNib.
    func applyBrandFontIfAvailable() {
        let descriptor = font.fontDescriptor

        // Brand adoption keys off Dynamic Type styles; labels pinned to a
        // fixed system size carry no text style and are left untouched.
        guard let styleName = descriptor.object(forKey: .textStyle) as? String else { return }
        let textStyle = UIFont.TextStyle(rawValue: styleName)

        let traits = descriptor.object(forKey: .traits) as? [UIFontDescriptor.TraitKey: Any]
        let weightValue = (traits?[.weight] as? CGFloat) ?? UIFont.Weight.regular.rawValue
        let weight = UIFont.Weight(rawValue: weightValue)

        guard let brandFont = BrandFont.scaledSansIfAvailable(textStyle: textStyle, weight: weight) else { return }

        font = brandFont
        adjustsFontForContentSizeCategory = true
    }
}
