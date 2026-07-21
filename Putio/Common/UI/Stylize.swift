import Foundation
import UIKit

class Stylize {
    private static func makeNavigationBarAppearance() -> UINavigationBarAppearance {
        let navigationBarAppearance = UINavigationBarAppearance()
        navigationBarAppearance.configureWithOpaqueBackground()
        navigationBarAppearance.backgroundColor = UIColor.Putio.Surface.navBg
        navigationBarAppearance.shadowColor = .clear
        navigationBarAppearance.titleTextAttributes = [.foregroundColor: UIColor.Putio.Neutral.text]

        let buttonAppearance = UIBarButtonItemAppearance(style: .plain)
        buttonAppearance.normal.titleTextAttributes = [.foregroundColor: UIColor.Putio.Yellow.solid]
        buttonAppearance.highlighted.titleTextAttributes = [.foregroundColor: UIColor.Putio.Yellow.solid]
        buttonAppearance.disabled.titleTextAttributes = [.foregroundColor: UIColor.Putio.Yellow.solid.withAlphaComponent(0.5)]

        navigationBarAppearance.buttonAppearance = buttonAppearance
        navigationBarAppearance.backButtonAppearance = buttonAppearance
        navigationBarAppearance.prominentButtonAppearance = buttonAppearance

        return navigationBarAppearance
    }

    static func UIKit(window: UIWindow?) {
        window?.backgroundColor = UIColor.Putio.Surface.appBg

        let navigationBar = UINavigationBar.appearance()
        navigationBar.tintColor = UIColor.Putio.Yellow.solid
        navigationBar.titleTextAttributes = [.foregroundColor: UIColor.Putio.Neutral.text]
        navigationBar.barStyle = .black
        navigationBar.isTranslucent = false
        navigationBar.barTintColor = UIColor.Putio.Surface.navBg

        let navigationBarAppearance = makeNavigationBarAppearance()
        navigationBar.standardAppearance = navigationBarAppearance
        navigationBar.compactAppearance = navigationBarAppearance
        navigationBar.scrollEdgeAppearance = navigationBarAppearance
        navigationBar.compactScrollEdgeAppearance = navigationBarAppearance

        UITabBar.appearance().tintColor = UIColor.Putio.Yellow.solid
        UITabBar.appearance().unselectedItemTintColor = UIColor.Putio.Neutral.solid

        UITableView.appearance().backgroundColor = UIColor.Putio.Surface.appBg
        UITableView.appearance().separatorColor = UIColor.Putio.Surface.listItemBorder
        UITableView.appearance().separatorInset = UIEdgeInsets(top: 0, left: 44, bottom: 0, right: 0)
        UITableView.appearance().sectionHeaderTopPadding = 0

        UITableViewCell.appearance().backgroundColor = UIColor.Putio.Surface.appBg
        UITableViewCell.appearance().tintColor = UIColor.Putio.Yellow.solid

        let uiTableViewCellColorView = UIView()
        uiTableViewCellColorView.backgroundColor = UIColor.Putio.Surface.listItemBgActive
        UITableViewCell.appearance().selectedBackgroundView = uiTableViewCellColorView
        UITableViewCell.appearance().multipleSelectionBackgroundView = uiTableViewCellColorView

        let toolbar = UIToolbar.appearance()
        toolbar.tintColor = UIColor.Putio.Yellow.solid

        UITextField.appearance().keyboardAppearance = .dark
    }

    static func searchBar(_ searchBar: UISearchBar) {
        searchBar.barStyle = .black
        searchBar.tintColor = UIColor.Putio.Yellow.solid
        searchBar.keyboardType = .default
        searchBar.keyboardAppearance = .dark
        searchBar.returnKeyType = .done
        searchBar.autocorrectionType = .no
    }
}
