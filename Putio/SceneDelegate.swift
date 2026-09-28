import UIKit

final class SceneDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?

    private var appDelegate: AppDelegate? {
        UIApplication.shared.delegate as? AppDelegate
    }

    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options connectionOptions: UIScene.ConnectionOptions) {
        guard scene is UIWindowScene, let window else { return }
        // UIKit creates the window from the scene's Main storyboard first.
        appDelegate?.connect(window: window)
        for context in connectionOptions.urlContexts {
            appDelegate?.openIncomingURL(context.url)
        }
        for activity in connectionOptions.userActivities {
            self.scene(scene, continue: activity)
        }
    }

    func scene(_ scene: UIScene, openURLContexts URLContexts: Set<UIOpenURLContext>) {
        for context in URLContexts {
            appDelegate?.openIncomingURL(context.url)
        }
    }

    func scene(_ scene: UIScene, continue userActivity: NSUserActivity) {
        guard userActivity.activityType == NSUserActivityTypeBrowsingWeb,
              let url = userActivity.webpageURL else { return }
        appDelegate?.openIncomingURL(url)
    }

    func sceneDidDisconnect(_ scene: UIScene) {
        if appDelegate?.window === window {
            appDelegate?.window = nil
        }
    }
}
