import Foundation
import UIKit

class Stylize {
    private static func makeNavigationBarAppearance() -> UINavigationBarAppearance {
        let navigationBarAppearance = UINavigationBarAppearance()
        navigationBarAppearance.configureWithOpaqueBackground()
        navigationBarAppearance.backgroundColor = UIColor.Putio.Surface.navBg
        navigationBarAppearance.shadowColor = .clear

        var titleAttributes: [NSAttributedString.Key: Any] = [.foregroundColor: UIColor.Putio.Neutral.text]
        // Sizes match the system's own nav-bar metrics, inline and large.
        if let brandTitleFont = BrandFont.sansIfAvailable(size: 17, weight: .bold) {
            titleAttributes[.font] = brandTitleFont
        }
        if let brandLargeTitleFont = BrandFont.sansIfAvailable(size: 34, weight: .bold) {
            // Assigning the dictionary replaces the configured defaults, so the
            // shared title colour has to be repeated here.
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

        // Tab bar labels are a fixed ~10pt, matching the system.
        if let tabBarItemFont = BrandFont.sansIfAvailable(size: 10, weight: .medium) {
            let attributes: [NSAttributedString.Key: Any] = [.font: tabBarItemFont]
            UITabBarItem.appearance().setTitleTextAttributes(attributes, for: .normal)
            UITabBarItem.appearance().setTitleTextAttributes(attributes, for: .selected)
        }

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
