import UIKit

extension UITableViewCell {
    open override func awakeFromNib() {
        super.awakeFromNib()
        configureGlobalAppearance()
    }

    open override func draw(_ rect: CGRect) {
        super.draw(rect)
        configureGlobalAppearance()
    }

    // Code-built cells must call this from their own configure(_:) — see
    // HistoryTableViewCell and TrashTableViewCell. A layoutSubviews override
    // here is not an alternative: an extension override of a UIKit method is
    // not reliably installed, and the font measurably stays on the system face.
    func configureGlobalAppearance() {
        textLabel?.textColor = UIColor.Putio.Neutral.text
        detailTextLabel?.textColor = UIColor.Putio.Neutral.textSecondary

        // UIKit supplies these two labels for the built-in cell styles, so
        // UILabel.awakeFromNib never runs on them.
        textLabel?.applyBrandFontIfAvailable()
        detailTextLabel?.applyBrandFontIfAvailable()
    }
}
