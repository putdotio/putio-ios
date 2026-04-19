import Foundation
import UIKit

class Stylize {
    private static func makeNavigationBarAppearance() -> UINavigationBarAppearance {
        let navigationBarAppearance = UINavigationBarAppearance()
        navigationBarAppearance.configureWithOpaqueBackground()
        navigationBarAppearance.backgroundColor = UIColor.Putio.black
        navigationBarAppearance.shadowColor = .clear
        navigationBarAppearance.titleTextAttributes = [.foregroundColor: UIColor.white]

        let buttonAppearance = UIBarButtonItemAppearance(style: .plain)
        buttonAppearance.normal.titleTextAttributes = [.foregroundColor: UIColor.Putio.yellow]
        buttonAppearance.highlighted.titleTextAttributes = [.foregroundColor: UIColor.Putio.yellow]
        buttonAppearance.disabled.titleTextAttributes = [.foregroundColor: UIColor.Putio.yellow.withAlphaComponent(0.5)]

        navigationBarAppearance.buttonAppearance = buttonAppearance
        navigationBarAppearance.backButtonAppearance = buttonAppearance
        navigationBarAppearance.prominentButtonAppearance = buttonAppearance

        return navigationBarAppearance
    }

    static func UIKit(window: UIWindow?) {
        window?.backgroundColor = UIColor.Putio.black

        let navigationBar = UINavigationBar.appearance()
        navigationBar.tintColor = UIColor.Putio.yellow
        navigationBar.titleTextAttributes = [.foregroundColor: UIColor.white]
        navigationBar.barStyle = .black
        navigationBar.isTranslucent = false
        navigationBar.barTintColor = UIColor.Putio.black

        let navigationBarAppearance = makeNavigationBarAppearance()
        navigationBar.standardAppearance = navigationBarAppearance
        navigationBar.compactAppearance = navigationBarAppearance
        navigationBar.scrollEdgeAppearance = navigationBarAppearance
        navigationBar.compactScrollEdgeAppearance = navigationBarAppearance

        UITabBar.appearance().tintColor = UIColor.Putio.yellow
        UITabBar.appearance().unselectedItemTintColor = .gray

        UITableView.appearance().backgroundColor = UIColor.Putio.background
        UITableView.appearance().separatorColor = UIColor.Putio.listSeperator
        UITableView.appearance().separatorInset = UIEdgeInsets(top: 0, left: 44, bottom: 0, right: 0)
        UITableView.appearance().sectionHeaderTopPadding = 0

        UITableViewCell.appearance().backgroundColor = UIColor.Putio.background
        UITableViewCell.appearance().tintColor = UIColor.Putio.yellow

        let uiTableViewCellColorView = UIView()
        uiTableViewCellColorView.backgroundColor = UIColor.Putio.black
        UITableViewCell.appearance().selectedBackgroundView = uiTableViewCellColorView
        UITableViewCell.appearance().multipleSelectionBackgroundView = uiTableViewCellColorView

        let toolbar = UIToolbar.appearance()
        toolbar.tintColor = UIColor.Putio.yellow

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
