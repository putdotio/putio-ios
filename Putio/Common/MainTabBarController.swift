import UIKit
import Intercom
import RealmSwift

class MainTabBarController: UITabBarController {
    enum Tab: Int {
        case files
        case history
        case downloads
        case account

        var icons: (regular: PutioIcon, fill: PutioIcon) {
            switch self {
            case .files:
                return (.folder, .folderFill)
            case .history:
                return (.clockCounterClockwise, .clockCounterClockwiseFill)
            case .downloads:
                return (.cloudArrowDown, .cloudArrowDownFill)
            case .account:
                return (.userCircle, .userCircleFill)
            }
        }
    }

    var cachedViewControllers: [UIViewController]? = []

    private(set) var userSettings: UserSettings?

    var notificationToken: NotificationToken?

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = UIColor.Putio.Surface.appBg
        userSettings = loadUserSettings()
        configureTabBarIcons()
        configureNavigationControllers()
        DeeplinkManager.sharedInstance.setup(with: self)
        cachedViewControllers = viewControllers
        updateDownloadQueueCount()
        updateUnreadConversationCount()
        updateHistoryTabVisibility()
        addObservers()
    }

    func configureTabBarIcons() {
        tabBar.items?.forEach { item in
            guard let tab = Tab(rawValue: item.tag) else {
                return InternalFailurePresenter.log("Unknown tab bar item tag: \(item.tag)")
            }
            item.image = tab.icons.regular.image(for: .tabBar)
            item.selectedImage = tab.icons.fill.image(for: .tabBar)
        }
    }

    deinit {
        notificationToken?.invalidate()
        NotificationCenter.default.removeObserver(self)
    }

    private func loadUserSettings() -> UserSettings? {
        guard let realm = PutioRealm.open(context: "MainTabBarController.loadUserSettings"),
              let userSettings = realm.objects(User.self).first?.settings else {
            InternalFailurePresenter.log("Unable to load UserSettings for MainTabBarController")
            return nil
        }

        return userSettings
    }

    func getTabBarItem(for tab: Tab) -> UITabBarItem? {
        return tabBar.items?.first(where: { (item) -> Bool in
            return item.tag == tab.rawValue
        })
    }

    func getTabBarItemIndex(for tab: Tab) -> Int? {
        return tabBar.items?.firstIndex(where: { (item) -> Bool in
            return item.tag == tab.rawValue
        })
    }

    func addObservers() {
        NotificationCenter.default.addObserver(
            self, selector:
            #selector(updateDownloadQueueCount),
            name: VideoDownloadManager.NOTIFICATION,
            object: nil
        )

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(updateUnreadConversationCount),
            name: NSNotification.Name.IntercomUnreadConversationCountDidChange,
            object: nil
        )

        guard let userSettings else { return }

        notificationToken = userSettings.observe({ (change) in
            switch change {
            case .change:
                self.updateHistoryTabVisibility()
            default:
                break
            }
        })
    }

    func configureNavigationControllers() {
        viewControllers?.forEach { controller in
            guard let navigationController = controller as? UINavigationController else { return }
            navigationController.navigationBar.prefersLargeTitles = false
        }
    }

    func setSelectedTab(_ tab: Tab) {
        guard let index = getTabBarItemIndex(for: tab) else { return }
        selectedIndex = index
    }

    func updateHistoryTabVisibility() {
        var viewControllers = cachedViewControllers

        if userSettings?.historyEnabled == false {
            guard let historyTabIndex = getTabBarItemIndex(for: .history) else { return }
            viewControllers?.remove(at: historyTabIndex)
        }

        setViewControllers(viewControllers, animated: false)
    }

    @objc func updateDownloadQueueCount() {
        guard let downloadsTab = getTabBarItem(for: .downloads) else { return }
        let count = VideoDownloadManager.sharedInstance.activeDownloadCount + AudioDownloadManager.sharedInstance.activeDownloadCount
        downloadsTab.badgeValue = count > 0 ? String(count) : nil
    }

    @objc func updateUnreadConversationCount() {
        guard let accountTab = getTabBarItem(for: .account) else { return }
        let count = Intercom.unreadConversationCount()
        accountTab.badgeValue = count > 0 ? String(count) : nil
    }
}
