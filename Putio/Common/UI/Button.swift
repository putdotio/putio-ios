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
