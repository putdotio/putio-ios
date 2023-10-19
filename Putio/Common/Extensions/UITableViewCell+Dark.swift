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
        textLabel?.textColor = UIColor.white
        detailTextLabel?.textColor = UIColor.Putio.listSubtitle
    }
}
