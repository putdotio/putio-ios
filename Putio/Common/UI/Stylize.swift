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
        navigationBarAppearance.doneButtonAppearance = buttonAppearance

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
