import Foundation
import UIKit

class Stylize {
    private static func makeNavigationBarAppearance() -> UINavigationBarAppearance {
        let navigationBarAppearance = UINavigationBarAppearance()
        navigationBarAppearance.configureWithOpaqueBackground()
        navigationBarAppearance.backgroundColor = UIColor.Putio.Surface.navBg
        navigationBarAppearance.shadowColor = .clear

        var titleAttributes: [NSAttributedString.Key: Any] = [.foregroundColor: UIColor.Putio.Neutral.text]
        // Sizes match the system's own nav-bar metrics, inline and large, and
        // grow with Dynamic Type as the system titles do.
        if let brandTitleFont = BrandFont.sansIfAvailable(size: 17, weight: .bold) {
            titleAttributes[.font] = UIFontMetrics(forTextStyle: .headline).scaledFont(for: brandTitleFont)
        }
        if let brandLargeTitleFont = BrandFont.sansIfAvailable(size: 34, weight: .bold)
            .map({ UIFontMetrics(forTextStyle: .largeTitle).scaledFont(for: $0) }) {
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

    /// Navigation-bar fonts and pre-rendered list icons are sized when they
    /// are made, so a text-size change while the app runs rebuilds them.
    static func refreshForTextSize(in window: UIWindow) {
        let appearance = makeNavigationBarAppearance()
        let proxy = UINavigationBar.appearance()
        proxy.standardAppearance = appearance
        proxy.compactAppearance = appearance
        proxy.scrollEdgeAppearance = appearance
        proxy.compactScrollEdgeAppearance = appearance

        var views: [UIView] = [window]
        while let view = views.popLast() {
            if let bar = view as? UINavigationBar {
                bar.standardAppearance = appearance
                bar.compactAppearance = appearance
                bar.scrollEdgeAppearance = appearance
                bar.compactScrollEdgeAppearance = appearance
            } else if let table = view as? UITableView {
                table.reloadData()
            }
            views.append(contentsOf: view.subviews)
        }
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


/// UIKit pads a grouped section header far faster than its title grows: 38pt
/// at the default text size is over 100pt two steps above it. Up to
/// the default UIKit's own height stands; above it the header grows with its
/// title instead.
enum GroupedSectionHeader {
    /// UIKit's height for a one-line title at the default text size.
    static let defaultHeight: CGFloat = 38

    static func height(in tableView: UITableView) -> CGFloat {
        let traits = tableView.traitCollection
        guard traits.preferredContentSizeCategory > .large else {
            return UITableView.automaticDimension
        }
        return UIFontMetrics(forTextStyle: .body).scaledValue(for: defaultHeight, compatibleWith: traits)
    }
}

/// Fixed width and height constraints laid out for the default text size,
/// grown with body text so an icon keeps its proportion to the text beside it.
final class TextScaledSizes {
    private let sizes: [(constraint: NSLayoutConstraint, base: CGFloat)]

    init(_ views: [UIView]) {
        sizes = views.flatMap { view in
            view.constraints.filter {
                $0.firstItem === view && $0.secondItem == nil && [.width, .height].contains($0.firstAttribute)
            }
        }.map { ($0, $0.constant) }
    }

    static func scaled(_ value: CGFloat, for traits: UITraitCollection) -> CGFloat {
        UIFontMetrics(forTextStyle: .body).scaledValue(for: value, compatibleWith: traits)
    }

    func apply(_ traits: UITraitCollection) {
        for (constraint, base) in sizes {
            constraint.constant = Self.scaled(base, for: traits)
        }
    }
}
