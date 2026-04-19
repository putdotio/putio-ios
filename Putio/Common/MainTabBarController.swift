import UIKit
import Intercom
import RealmSwift

class MainTabBarController: UITabBarController {
    enum TabbarItemTitle: String {
        case files = "Files", history = "History", downloads = "Downloads", account = "Account"
    }

    var cachedViewControllers: [UIViewController]? = []

    private(set) var userSettings: UserSettings?

    var notificationToken: NotificationToken?

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = UIColor.Putio.background
        overrideUserInterfaceStyle = .dark
        userSettings = loadUserSettings()
        configureNavigationControllers()
        DeeplinkManager.sharedInstance.setup(with: self)
        cachedViewControllers = viewControllers
        updateDownloadQueueCount()
        updateUnreadConversationCount()
        updateHistoryTabVisibility()
        addObservers()
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

    func getTabBarItem(of title: TabbarItemTitle) -> UITabBarItem? {
        return tabBar.items?.first(where: { (item) -> Bool in
            return item.title == title.rawValue
        })
    }

    func getTabBarItemIndex(of title: TabbarItemTitle) -> Int? {
        return tabBar.items?.firstIndex(where: { (item) -> Bool in
            return item.title == title.rawValue
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

    func setSelectedTab(title: TabbarItemTitle) {
        guard let index = getTabBarItemIndex(of: title) else { return }
        selectedIndex = index
    }

    func updateHistoryTabVisibility() {
        var viewControllers = cachedViewControllers

        if userSettings?.historyEnabled == false {
            guard let historyTabIndex = getTabBarItemIndex(of: .history) else { return }
            viewControllers?.remove(at: historyTabIndex)
        }

        setViewControllers(viewControllers, animated: false)
    }

    @objc func updateDownloadQueueCount() {
        guard let downloadsTab = getTabBarItem(of: .downloads) else { return }
        let count = VideoDownloadManager.sharedInstance.activeDownloadCount + AudioDownloadManager.sharedInstance.activeDownloadCount
        downloadsTab.badgeValue = count > 0 ? String(count) : nil
    }

    @objc func updateUnreadConversationCount() {
        guard let accountTab = getTabBarItem(of: .account) else { return }
        let count = Intercom.unreadConversationCount()
        accountTab.badgeValue = count > 0 ? String(count) : nil
    }
}
