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

    // Cells built in code never receive awakeFromNib, so they must call this
    // from their own configure(_:) — see HistoryTableViewCell and
    // TrashTableViewCell. Adding a layoutSubviews override here does not work:
    // an extension override of a UIKit method is not reliably installed, which
    // is measurable — the font stays on the system face even with the cell in a
    // window and laid out.
    func configureGlobalAppearance() {
        textLabel?.textColor = UIColor.Putio.Neutral.text
        detailTextLabel?.textColor = UIColor.Putio.Neutral.textSecondary

        // Built-in cell styles (.subtitle, .value1) get these two labels from
        // UIKit, not from a nib, so UILabel.awakeFromNib never runs on them and
        // they kept the system face. Branding them here covers every such cell
        // at once, and applyBrandFontIfAvailable is idempotent so the draw(_:)
        // path costs nothing after the first pass.
        textLabel?.applyBrandFontIfAvailable()
        detailTextLabel?.applyBrandFontIfAvailable()
    }
}
