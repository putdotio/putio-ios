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

        let traits = descriptor.object(forKey: .traits) as? [UIFontDescriptor.TraitKey: Any]
        let weightValue = (traits?[.weight] as? CGFloat) ?? UIFont.Weight.regular.rawValue
        let weight = UIFont.Weight(rawValue: weightValue)

        // Dynamic Type labels remap to the brand face scaled for their text
        // style. Labels pinned to a fixed size — a UIButton's default title
        // label, or a fixed-point storyboard label — carry no text style, so
        // they match their current point size instead. Both branches are a
        // no-op when the licensed faces are absent, keeping verification
        // builds byte-identical.
        if let styleName = descriptor.object(forKey: .textStyle) as? String {
            let textStyle = UIFont.TextStyle(rawValue: styleName)
            guard let brandFont = BrandFont.scaledSansIfAvailable(textStyle: textStyle, weight: weight) else { return }
            font = brandFont
            adjustsFontForContentSizeCategory = true
        } else {
            guard let brandFont = BrandFont.sansIfAvailable(size: font.pointSize, weight: weight) else { return }
            font = brandFont
        }
    }
}
