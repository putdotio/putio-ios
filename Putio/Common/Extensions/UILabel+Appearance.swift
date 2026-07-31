import ObjectiveC
import UIKit

// Font styling here is skipped when the licensed faces are absent, so a build
// without them keeps exactly the fonts its callers and nibs set. Note this is
// not a full no-op: applyBrandStyle still clears a prior trait registration.
extension UILabel {
    open override func awakeFromNib() {
        super.awakeFromNib()
        applyBrandFontIfAvailable()
    }

    // Labels UIKit creates for us (a UIButton's titleLabel, a built-in cell's
    // textLabel) never receive awakeFromNib and must call this directly.
    //
    // Pass `weight` for those labels: UIKit gives them a *plain* system font,
    // whose descriptor reports regular, so a derived weight silently demotes
    // them. A descriptor built with an explicit weight does carry it.
    func applyBrandFontIfAvailable(weight: UIFont.Weight? = nil) {
        // Re-deriving from an already-branded descriptor loses the weight trait,
        // and draw(_:) reaches this more than once per label.
        guard !BrandFont.isBrandFace(font) else { return }

        let descriptor = font.fontDescriptor

        // A named weight skips role mapping, since a role carries its own.
        if weight == nil,
           let styleName = descriptor.object(forKey: .textStyle) as? String,
           let role = Self.brandRole(for: UIFont.TextStyle(rawValue: styleName)),
           let brandFont = BrandTypography.fontIfAvailable(role) {
            font = brandFont
            adjustsFontForContentSizeCategory = true
            return
        }

        // No text style, or a CoreText usage token like `CTFontRegularUsage`
        // that only looks like one — what UIKit stamps on a plain system font.
        // Matching point size and weight forfeits Dynamic Type for these
        // labels, in exchange for not mixing the system face with GT America on
        // one screen.
        let resolved = weight ?? Self.brandWeight(from: descriptor)
        guard let brandFont = BrandFont.sansIfAvailable(size: font.pointSize, weight: resolved) else { return }
        font = brandFont
    }

    private static var brandTraitRegistrationKey: UInt8 = 0

    // The role's full styling — font, tracking, line height, uppercasing —
    // rather than the font alone. Tracking and line height live on
    // attributedText, so this must run AFTER text, colour, and alignment: a
    // later `text =` drops the styling.
    func applyBrandStyle(_ role: BrandTypography.Role) {
        // Unregister before the guard, not after it, so an early return still
        // stops a reused label re-applying a prior role on trait changes.
        if let prior = objc_getAssociatedObject(self, &UILabel.brandTraitRegistrationKey) as? UITraitChangeRegistration {
            unregisterForTraitChanges(prior)
            objc_setAssociatedObject(self, &UILabel.brandTraitRegistrationKey, nil, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        }

        guard BrandTypography.styleIfAvailable(role) != nil, text?.isEmpty == false else { return }

        applyBrandStyleAttributes(role)
        // UIKit rescales neither the font nor the kern inside an attributed
        // string, so both are recomputed on every content size category change.
        let registration = registerForTraitChanges([UITraitPreferredContentSizeCategory.self]) { (label: UILabel, _: UITraitCollection) in
            label.applyBrandStyleAttributes(role)
        }
        objc_setAssociatedObject(self, &UILabel.brandTraitRegistrationKey, registration, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
    }

    private func applyBrandStyleAttributes(_ role: BrandTypography.Role) {
        guard let style = BrandTypography.styleIfAvailable(role, compatibleWith: traitCollection),
              let source = attributedText?.string ?? text, !source.isEmpty else { return }

        font = style.font
        // Scaling is owned by the trait-change registration above; UIKit's own
        // auto-adjust would double-scale.
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

    // The weight trait is an NSNumber; a direct `as? CGFloat` cast fails and
    // drops every fixed-size label to regular.
    static func brandWeight(from descriptor: UIFontDescriptor) -> UIFont.Weight {
        let traits = descriptor.object(forKey: .traits) as? [UIFontDescriptor.TraitKey: Any]
        let raw = (traits?[.weight] as? NSNumber)?.doubleValue ?? Double(UIFont.Weight.regular.rawValue)
        return UIFont.Weight(rawValue: CGFloat(raw))
    }

    // An unmapped (e.g. future) style returns nil so the label is left
    // untouched rather than collapsed onto body. `label` is deliberately
    // unreachable here — its uppercasing has to be opted into, not swept across
    // every caption.
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
