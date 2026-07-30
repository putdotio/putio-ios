import UIKit

extension UITextField {
    open override func awakeFromNib() {
        super.awakeFromNib()

        autocorrectionType = .no

        attributedPlaceholder = NSAttributedString(
            string: self.placeholder != nil ? self.placeholder! : "",
            attributes: [NSAttributedString.Key.foregroundColor: UIColor.Putio.Neutral.textSecondary]
        )

        if let clearButton = value(forKey: "_clearButton") as? UIButton {
            let templateImage = clearButton.imageView?.image?.withRenderingMode(.alwaysTemplate)
            clearButton.setImage(templateImage, for: .normal)
            clearButton.tintColor = UIColor.Putio.Neutral.solid
        }
    }

    // The code face, for machine-readable input like 2FA and device-link codes.
    // Font only: a text field carries no tracking or line height.
    func applyCodeFont() {
        guard let font = BrandTypography.fontIfAvailable(.code) else { return }
        self.font = font
        adjustsFontForContentSizeCategory = true
    }
}
