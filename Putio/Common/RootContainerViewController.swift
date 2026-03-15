import GoogleCast
import UIKit

class RootContainerViewController: UIViewController, GCKUIMiniMediaControlsViewControllerDelegate {
    private var mainTabBarContainerView: UIView!
    private var mainTabBarController: MainTabBarController!

    private var miniMediaControlsViewController: GCKUIMiniMediaControlsViewController!
    private var miniMediaControlsContainerView: UIView!
    private var miniMediaControlsHeightConstraint: NSLayoutConstraint!
    private var miniMediaControlsBottomConstraint: NSLayoutConstraint!

    private var maskingView: UIView!
    private var maskingViewHeightConstraint: NSLayoutConstraint!

    func installViewController(_ viewController: UIViewController, inContainerView containerView: UIView) {
        addChildViewController(viewController)
        viewController.view.translatesAutoresizingMaskIntoConstraints = false
        containerView.addSubview(viewController.view)

        NSLayoutConstraint.activate([
            viewController.view.topAnchor.constraint(equalTo: containerView.topAnchor),
            viewController.view.bottomAnchor.constraint(equalTo: containerView.bottomAnchor),
            viewController.view.leadingAnchor.constraint(equalTo: containerView.leadingAnchor),
            viewController.view.trailingAnchor.constraint(equalTo: containerView.trailingAnchor)
        ])

        viewController.didMove(toParentViewController: self)
    }

    func uninstallViewController(_ viewController: UIViewController) {
        viewController.willMove(toParentViewController: nil)
        viewController.view.removeFromSuperview()
        viewController.removeFromParentViewController()
    }

    func createMainTabBarControllerView() {
        mainTabBarContainerView = UIView()
        mainTabBarContainerView.translatesAutoresizingMaskIntoConstraints = false

        view.addSubview(mainTabBarContainerView)
        view.bringSubview(toFront: mainTabBarContainerView)

        NSLayoutConstraint.activate([
            mainTabBarContainerView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            mainTabBarContainerView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            mainTabBarContainerView.topAnchor.constraint(equalTo: view.topAnchor)
        ])

        let bottomConstraint = mainTabBarContainerView.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        bottomConstraint.priority = .defaultHigh
        bottomConstraint.isActive = true

        mainTabBarController = UIStoryboard(name: "Main", bundle: nil).instantiateViewController(withIdentifier: "MainTabBarController") as? MainTabBarController
        installViewController(mainTabBarController, inContainerView: mainTabBarContainerView)
    }

    func createMiniMediaControllerView() {
        miniMediaControlsContainerView = UIView()
        miniMediaControlsContainerView.translatesAutoresizingMaskIntoConstraints = false

        view.addSubview(miniMediaControlsContainerView)
        view.bringSubview(toFront: miniMediaControlsContainerView)

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
        maskingView.backgroundColor = UIColor.Putio.black

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
        view.backgroundColor = UIColor.Putio.black
        overrideUserInterfaceStyle = .dark
        createMainTabBarControllerView()
        createMiniMediaControllerView()
        createMaskingView()
        updateControlBarsVisibility(shouldAppear: false)
    }

    func miniMediaControlsViewController(_ miniMediaControlsViewController: GCKUIMiniMediaControlsViewController, shouldAppear: Bool) {
        updateControlBarsVisibility(shouldAppear: shouldAppear)
    }
}
