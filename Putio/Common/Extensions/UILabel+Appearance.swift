import ObjectiveC
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
        // Idempotent: configureGlobalAppearance calls this from draw(_:), and a
        // second pass would re-derive the weight from a descriptor that no
        // longer carries the trait — quietly demoting a bold label to regular.
        guard !BrandFont.isBrandFace(font) else { return }

        let descriptor = font.fontDescriptor

        // Map the label's Dynamic Type style onto the nearest design-system role
        // and adopt that role's font (size + weight + Dynamic Type).
        if let styleName = descriptor.object(forKey: .textStyle) as? String,
           let role = Self.brandRole(for: UIFont.TextStyle(rawValue: styleName)),
           let brandFont = BrandTypography.fontIfAvailable(role) {
            font = brandFont
            adjustsFontForContentSizeCategory = true
            return
        }

        // Everything else: no text style at all (a fixed-point storyboard
        // label), or a token that is not a Dynamic Type style. UIKit stamps
        // plain system fonts with CoreText usage tokens like
        // `CTFontRegularUsage`, and a UIButton's title label carries exactly
        // that — which is how buttons, and every built-in-style table cell,
        // kept the system face through three typography releases while this
        // helper reported success.
        //
        // Matching the current point size and weight on the brand face gives up
        // Dynamic Type for these labels, which is the smaller loss: the
        // alternative is shipping the system face next to GT America on the
        // same screen.
        let weight = Self.brandWeight(from: descriptor)
        guard let brandFont = BrandFont.sansIfAvailable(size: font.pointSize, weight: weight) else { return }
        font = brandFont
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
    private static var brandTraitRegistrationKey: UInt8 = 0

    func applyBrandStyle(_ role: BrandTypography.Role) {
        // Always drop any registration from an earlier applyBrandStyle FIRST —
        // before the guard below — so a reused label never keeps re-applying a
        // prior role on later Dynamic Type changes, even when this call
        // early-returns (empty text, or the licensed faces absent).
        if let prior = objc_getAssociatedObject(self, &UILabel.brandTraitRegistrationKey) as? UITraitChangeRegistration {
            unregisterForTraitChanges(prior)
            objc_setAssociatedObject(self, &UILabel.brandTraitRegistrationKey, nil, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        }

        // No-op without the licensed faces, so the label keeps what the caller
        // configured and verification baselines stay on their system fonts.
        guard BrandTypography.styleIfAvailable(role) != nil, text?.isEmpty == false else { return }

        applyBrandStyleAttributes(role)
        // The role is resolved against the label's own trait collection, so the
        // scaled font *and* the absolute kern derived from the scaled size are
        // both correct for the current content size category. UIKit rescales
        // neither inside an attributed string on its own, so recompute whenever
        // the category changes.
        let registration = registerForTraitChanges([UITraitPreferredContentSizeCategory.self]) { (label: UILabel, _: UITraitCollection) in
            label.applyBrandStyleAttributes(role)
        }
        objc_setAssociatedObject(self, &UILabel.brandTraitRegistrationKey, registration, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
    }

    private func applyBrandStyleAttributes(_ role: BrandTypography.Role) {
        guard let style = BrandTypography.styleIfAvailable(role, compatibleWith: traitCollection),
              let source = attributedText?.string ?? text, !source.isEmpty else { return }

        font = style.font
        // Scaling is owned here (recomputed per content-size change via
        // registerForTraitChanges), so UIKit's own auto-adjust is off to avoid
        // double-scaling.
        adjustsFontForContentSizeCategory = false

        let paragraph = NSMutableParagraphStyle()
        paragraph.lineHeightMultiple = style.lineHeightMultiple
        paragraph.alignment = textAlignment
        paragraph.lineBreakMode = lineBreakMode

        var attributes: [NSAttributedString.Key: Any] = [
            .font: style.font,
            .paragraphStyle: paragraph
        ]
        if style.tracking != 0 { attributes[.kern] = style.tracking }
        if let textColor { attributes[.foregroundColor] = textColor }

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
