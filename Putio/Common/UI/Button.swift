
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

        self.layer.cornerRadius = 4

        switch _variant {
        case .primary:
            self.backgroundColor = UIColor.Putio.yellow
            self.setTitleColor(UIColor.Putio.black, for: .normal)

        case .secondary:
            self.backgroundColor = UIColor.Putio.blackTint
            self.setTitleColor(.white, for: .normal)

        case .danger:
            self.backgroundColor = UIColor.systemRed
            self.setTitleColor(.white, for: .normal)
        }
    }
}
