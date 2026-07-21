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

    func configureGlobalAppearance() {
        textLabel?.textColor = UIColor.Putio.Neutral.text
        detailTextLabel?.textColor = UIColor.Putio.Neutral.textSecondary
    }
}
