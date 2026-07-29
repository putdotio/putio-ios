import UIKit

class Button: UIButton {
    enum Variant: String {
        case primary
        case secondary
        case danger
    }

    private var _variant: Variant = .secondary

    @IBInspectable var variant: String {
        get {
            return _variant.rawValue
        }

        set {
            _variant = Button.Variant(rawValue: newValue)!
        }
    }

    override func awakeFromNib() {
        super.awakeFromNib()
        applyVariantStyle()
    }

    func applyVariantStyle() {
        layer.cornerRadius = 4

        // The title label is created by UIKit, so it never receives
        // awakeFromNib; brand it explicitly using the same helper (a no-op
        // when the licensed faces are absent).
        //
        // Medium is passed rather than derived: the title label's descriptor
        // reports regular for every system font, which is how button titles
        // stayed on GT America Regular. The design system is explicit that
        // medium is the weight for labels and controls, and reserves bold for
        // "where the hierarchy earns it" — a button is a control.
        //
        // It also defines no semibold: the weight ramp is regular 400, medium
        // 500, bold 700, black 900, and the bundled faces match it.
        titleLabel?.applyBrandFontIfAvailable(weight: .medium)

        switch _variant {
        case .primary:
            backgroundColor = UIColor.Putio.Yellow.solid
            setTitleColor(UIColor.Putio.Fg.primaryForeground, for: .normal)

        case .secondary:
            backgroundColor = UIColor.Putio.Neutral.componentBg
            setTitleColor(UIColor.Putio.Neutral.text, for: .normal)

        case .danger:
            backgroundColor = UIColor.Putio.Red.solid
            setTitleColor(UIColor.Putio.Fg.destructiveForeground, for: .normal)
        }
    }
}
