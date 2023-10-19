import Foundation
import UIKit

class Stylize {
    static func UIKit(window: UIWindow?) {
        window?.backgroundColor = UIColor.Putio.black

        UINavigationBar.appearance().backgroundColor = UIColor.Putio.black
        UINavigationBar.appearance().titleTextAttributes = [NSAttributedStringKey.foregroundColor: UIColor.white]

        UINavigationBar.appearance().barTintColor = UIColor.Putio.black
        UINavigationBar.appearance().tintColor = UIColor.Putio.yellow

        UITabBar.appearance().barTintColor = UIColor.Putio.black
        UITabBar.appearance().tintColor = UIColor.Putio.yellow

        UITableView.appearance().backgroundColor = UIColor.Putio.background
        UITableView.appearance().separatorColor = UIColor.Putio.listSeperator

        UITableViewCell.appearance().backgroundColor = UIColor.Putio.background
        UITableViewCell.appearance().tintColor = UIColor.Putio.yellow

        let uiTableViewCellColorView = UIView()
        uiTableViewCellColorView.backgroundColor = UIColor.Putio.black
        UITableViewCell.appearance().selectedBackgroundView = uiTableViewCellColorView
        UITableViewCell.appearance().multipleSelectionBackgroundView = uiTableViewCellColorView

        UIToolbar.appearance().backgroundColor = UIColor.Putio.black
        UIToolbar.appearance().tintColor = UIColor.Putio.yellow
        UIToolbar.appearance().barTintColor = UIColor.Putio.black

        UITextField.appearance().keyboardAppearance = .dark
    }

    static func searchBar(_ searchBar: UISearchBar) {
        searchBar.barStyle = .black
        searchBar.tintColor = UIColor.Putio.yellow
        searchBar.keyboardType = .default
        searchBar.keyboardAppearance = .dark
        searchBar.returnKeyType = .done
        searchBar.autocorrectionType = .no
    }
}
