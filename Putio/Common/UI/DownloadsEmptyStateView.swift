import UIKit

protocol DownloadsEmptyStateViewDelegate: class {
    func downloadTutorialButtonTapped()
}

class DownloadsEmptyStateView: UIView, InterfaceBuilderInstantiable {
    @IBOutlet weak var headingLabel: UILabel!
    @IBOutlet weak var button: UIButton!

    weak var delegate: DownloadsEmptyStateViewDelegate?

    @IBAction func buttonTapped(_ sender: Any) {
        delegate?.downloadTutorialButtonTapped()
    }
}
