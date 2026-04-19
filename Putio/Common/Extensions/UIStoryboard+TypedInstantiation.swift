import UIKit

extension UIStoryboard {
    func instantiateViewController<T: UIViewController>(withIdentifier identifier: String, as type: T.Type) -> T? {
        instantiateViewController(withIdentifier: identifier) as? T
    }
}
