import GoogleCast
import UIKit

class RootContainerViewController: UIViewController, GCKUIMiniMediaControlsViewControllerDelegate {
    private var mainTabBarContainerView: UIView!
    private var mainTabBarController: MainTabBarController!
    private var mainTabBarTopToViewConstraint: NSLayoutConstraint!

    private var accountNoticeView: AccountNoticeView!
    private var mainTabBarTopToNoticeConstraint: NSLayoutConstraint!

    private var miniMediaControlsViewController: GCKUIMiniMediaControlsViewController!
    private var miniMediaControlsContainerView: UIView!
    private var miniMediaControlsHeightConstraint: NSLayoutConstraint!
    private var miniMediaControlsBottomConstraint: NSLayoutConstraint!

    private var maskingView: UIView!
    private var maskingViewHeightConstraint: NSLayoutConstraint!

    var asksProductAnalytics = false

    func installViewController(_ viewController: UIViewController, inContainerView containerView: UIView) {
        addChild(viewController)
        viewController.view.translatesAutoresizingMaskIntoConstraints = false
        containerView.addSubview(viewController.view)

        NSLayoutConstraint.activate([
            viewController.view.topAnchor.constraint(equalTo: containerView.topAnchor),
            viewController.view.bottomAnchor.constraint(equalTo: containerView.bottomAnchor),
            viewController.view.leadingAnchor.constraint(equalTo: containerView.leadingAnchor),
            viewController.view.trailingAnchor.constraint(equalTo: containerView.trailingAnchor)
        ])

        viewController.didMove(toParent: self)
    }

    func uninstallViewController(_ viewController: UIViewController) {
        viewController.willMove(toParent: nil)
        viewController.view.removeFromSuperview()
        viewController.removeFromParent()
    }

    func createMainTabBarControllerView() {
        mainTabBarContainerView = UIView()
        mainTabBarContainerView.translatesAutoresizingMaskIntoConstraints = false

        view.addSubview(mainTabBarContainerView)
        view.bringSubviewToFront(mainTabBarContainerView)

        mainTabBarTopToViewConstraint = mainTabBarContainerView.topAnchor.constraint(equalTo: view.topAnchor)
        NSLayoutConstraint.activate([
            mainTabBarContainerView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            mainTabBarContainerView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            mainTabBarTopToViewConstraint
        ])

        let bottomConstraint = mainTabBarContainerView.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        bottomConstraint.priority = .defaultHigh
        bottomConstraint.isActive = true

        mainTabBarController = UIStoryboard(name: "Main", bundle: nil).instantiateViewController(withIdentifier: "MainTabBarController") as? MainTabBarController
        installViewController(mainTabBarController, inContainerView: mainTabBarContainerView)
    }

    // Hidden for an account in good standing, which keeps the tabs pinned to
    // the top; shown, it pushes them down.
    func createAccountNoticeView() {
        accountNoticeView = AccountNoticeView()
        accountNoticeView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(accountNoticeView)

        NSLayoutConstraint.activate([
            accountNoticeView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            accountNoticeView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            accountNoticeView.topAnchor.constraint(equalTo: view.topAnchor)
        ])

        mainTabBarTopToNoticeConstraint = mainTabBarContainerView.topAnchor.constraint(equalTo: accountNoticeView.bottomAnchor)

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(updateAccountNotice),
            name: .accountNoticeDidChange,
            object: nil
        )
        updateAccountNotice()
    }

    @objc func updateAccountNotice() {
        let notice = AccountNoticeStore.shared.notice
        accountNoticeView.configure(with: notice)

        let isShowing = notice != nil
        NSLayoutConstraint.deactivate([isShowing ? mainTabBarTopToViewConstraint : mainTabBarTopToNoticeConstraint])
        NSLayoutConstraint.activate([isShowing ? mainTabBarTopToNoticeConstraint : mainTabBarTopToViewConstraint])
        view.setNeedsLayout()
    }

    func createMiniMediaControllerView() {
        miniMediaControlsContainerView = UIView()
        miniMediaControlsContainerView.translatesAutoresizingMaskIntoConstraints = false

        view.addSubview(miniMediaControlsContainerView)
        view.bringSubviewToFront(miniMediaControlsContainerView)

        NSLayoutConstraint.activate([
            miniMediaControlsContainerView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            miniMediaControlsContainerView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            miniMediaControlsContainerView.topAnchor.constraint(equalTo: mainTabBarContainerView.bottomAnchor, constant: 6)
        ])

        let topConstraint = miniMediaControlsContainerView.topAnchor.constraint(equalTo: mainTabBarContainerView.bottomAnchor)
        topConstraint.priority = .defaultLow
        topConstraint.isActive = true

        miniMediaControlsBottomConstraint = miniMediaControlsContainerView.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor)
        miniMediaControlsBottomConstraint.isActive = false

        miniMediaControlsHeightConstraint = miniMediaControlsContainerView.heightAnchor.constraint(equalToConstant: 0)
        miniMediaControlsHeightConstraint.isActive = true

        let castContext = GCKCastContext.sharedInstance()
        miniMediaControlsViewController = castContext.createMiniMediaControlsViewController()
        miniMediaControlsViewController.delegate = self

        installViewController(miniMediaControlsViewController, inContainerView: miniMediaControlsContainerView)
    }

    func createMaskingView() {
        maskingView = UIView()
        maskingView.translatesAutoresizingMaskIntoConstraints = false
        maskingView.backgroundColor = UIColor.Putio.Neutral.componentBg

        view.addSubview(maskingView)

        NSLayoutConstraint.activate([
            maskingView.leadingAnchor.constraint(equalTo: self.view.leadingAnchor),
            maskingView.trailingAnchor.constraint(equalTo: self.view.trailingAnchor),
            maskingView.bottomAnchor.constraint(equalTo: miniMediaControlsContainerView.topAnchor)
        ])

        maskingViewHeightConstraint = maskingView.heightAnchor.constraint(equalToConstant: 0)
        maskingViewHeightConstraint.isActive = true
    }

    func updateControlBarsVisibility(shouldAppear: Bool) {
        miniMediaControlsBottomConstraint.isActive = shouldAppear
        miniMediaControlsHeightConstraint.constant = shouldAppear ? miniMediaControlsViewController.minHeight : 0
        maskingViewHeightConstraint.constant = shouldAppear ? 6 : 0
        view.setNeedsLayout()
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = UIColor.Putio.Surface.appBg
        createMainTabBarControllerView()
        createAccountNoticeView()
        createMiniMediaControllerView()
        createMaskingView()
        updateControlBarsVisibility(shouldAppear: false)
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        guard asksProductAnalytics else { return }
        asksProductAnalytics = false

        var presenter: UIViewController = self
        while let presented = presenter.presentedViewController, !presented.isBeingDismissed {
            presenter = presented
        }
        presenter.present(ProductAnalyticsPromptViewController(), animated: true)
    }

    // GCKUIStyle resolves colors eagerly, so Cast chrome must be restyled on
    // every effective appearance change.
    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        if traitCollection.hasDifferentColorAppearance(comparedTo: previousTraitCollection) {
            ChromecastManager.sharedInstance.applyAppearanceStyling()
        }
    }

    func miniMediaControlsViewController(_ miniMediaControlsViewController: GCKUIMiniMediaControlsViewController, shouldAppear: Bool) {
        updateControlBarsVisibility(shouldAppear: shouldAppear)
    }
}
