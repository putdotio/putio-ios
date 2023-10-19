import UIKit

class EmptyStateView: UIView, InterfaceBuilderInstantiable {
    @IBOutlet weak var headingLabel: UILabel!
    @IBOutlet weak var descriptionLabel: UILabel!

    func configure(heading: String = "", description: String = "") {
        headingLabel.text = heading
        descriptionLabel.text = description
    }
}
