import Foundation
import UIKit

protocol InterfaceBuilderInstantiable {
    static var associatedNib: UINib { get }
}

extension InterfaceBuilderInstantiable {
    static func instantiateFromInterfaceBuilder() -> Self {
        return associatedNib.instantiate(withOwner: nil, options: nil)[0] as! Self
    }

    static var associatedNib: UINib {
        let name = String(describing: self)
        return UINib(nibName: name, bundle: Bundle.main)
    }
}
