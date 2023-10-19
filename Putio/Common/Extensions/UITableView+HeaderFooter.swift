import UIKit

extension UITableView {
    open override func awakeFromNib() {
        tableFooterView = UITableViewHeaderFooterView()
        tableFooterView?.backgroundColor = UIColor.Putio.background
    }
}
