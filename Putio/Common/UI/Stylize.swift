import Foundation
import UIKit

class Stylize {
    private static func makeNavigationBarAppearance() -> UINavigationBarAppearance {
        let navigationBarAppearance = UINavigationBarAppearance()
        navigationBarAppearance.configureWithOpaqueBackground()
        navigationBarAppearance.backgroundColor = UIColor.Putio.Surface.navBg
        navigationBarAppearance.shadowColor = .clear

        var titleAttributes: [NSAttributedString.Key: Any] = [.foregroundColor: UIColor.Putio.Neutral.text]
        // Brand type only when the licensed faces are bundled; otherwise the
        // system styling stays byte-identical for snapshot baselines. Large
        // titles (Files/Account/History/Downloads) style through their own
        // attribute set, at the system large-title metrics (34pt bold).
        if let brandTitleFont = BrandFont.sansIfAvailable(size: 17, weight: .bold) {
            titleAttributes[.font] = brandTitleFont
        }
        if let brandLargeTitleFont = BrandFont.sansIfAvailable(size: 34, weight: .bold) {
            // Assigning the attribute dictionary replaces the configured
            // defaults, so carry the title color large titles should share
            // with the inline title.
            navigationBarAppearance.largeTitleTextAttributes = [
                .font: brandLargeTitleFont,
                .foregroundColor: UIColor.Putio.Neutral.text
            ]
        }
        navigationBarAppearance.titleTextAttributes = titleAttributes

        let buttonAppearance = UIBarButtonItemAppearance(style: .plain)
        buttonAppearance.normal.titleTextAttributes = [.foregroundColor: UIColor.Putio.Yellow.textSecondary]
        buttonAppearance.highlighted.titleTextAttributes = [.foregroundColor: UIColor.Putio.Yellow.textSecondary]
        buttonAppearance.disabled.titleTextAttributes = [.foregroundColor: UIColor.Putio.Yellow.textSecondary.withAlphaComponent(0.5)]

        navigationBarAppearance.buttonAppearance = buttonAppearance
        navigationBarAppearance.backButtonAppearance = buttonAppearance
        navigationBarAppearance.prominentButtonAppearance = buttonAppearance

        return navigationBarAppearance
    }

    static func UIKit(window: UIWindow?) {
        window?.backgroundColor = UIColor.Putio.Surface.appBg

        let navigationBar = UINavigationBar.appearance()
        navigationBar.tintColor = UIColor.Putio.Yellow.textSecondary
        navigationBar.titleTextAttributes = [.foregroundColor: UIColor.Putio.Neutral.text]
        navigationBar.isTranslucent = false
        navigationBar.barTintColor = UIColor.Putio.Surface.navBg

        let navigationBarAppearance = makeNavigationBarAppearance()
        navigationBar.standardAppearance = navigationBarAppearance
        navigationBar.compactAppearance = navigationBarAppearance
        navigationBar.scrollEdgeAppearance = navigationBarAppearance
        navigationBar.compactScrollEdgeAppearance = navigationBarAppearance

        UITabBar.appearance().tintColor = UIColor.Putio.Yellow.textSecondary
        UITabBar.appearance().unselectedItemTintColor = UIColor.Putio.Neutral.solid

        UITableView.appearance().backgroundColor = UIColor.Putio.Surface.appBg
        UITableView.appearance().separatorColor = UIColor.Putio.Surface.listItemBorder
        UITableView.appearance().separatorInset = UIEdgeInsets(top: 0, left: 44, bottom: 0, right: 0)
        UITableView.appearance().sectionHeaderTopPadding = 0

        UITableViewCell.appearance().backgroundColor = UIColor.Putio.Surface.appBg
        UITableViewCell.appearance().tintColor = UIColor.Putio.Yellow.textSecondary

        let uiTableViewCellColorView = UIView()
        uiTableViewCellColorView.backgroundColor = UIColor.Putio.Surface.listItemBgActive
        UITableViewCell.appearance().selectedBackgroundView = uiTableViewCellColorView
        UITableViewCell.appearance().multipleSelectionBackgroundView = uiTableViewCellColorView

        let toolbar = UIToolbar.appearance()
        toolbar.tintColor = UIColor.Putio.Yellow.textSecondary

    }

    static func searchBar(_ searchBar: UISearchBar) {
        searchBar.tintColor = UIColor.Putio.Yellow.textSecondary
        searchBar.keyboardType = .default
        searchBar.returnKeyType = .done
        searchBar.autocorrectionType = .no
    }
}
