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

        layer.cornerRadius = 4

        switch _variant {
        case .primary:
            backgroundColor = UIColor.Putio.yellow
            setTitleColor(UIColor.Putio.black, for: .normal)

        case .secondary:
            backgroundColor = UIColor.Putio.blackTint
            setTitleColor(.white, for: .normal)

        case .danger:
            backgroundColor = UIColor.systemRed
            setTitleColor(.white, for: .normal)
        }
    }
}
