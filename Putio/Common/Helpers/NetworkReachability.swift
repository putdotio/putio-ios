import Foundation
import Alamofire
import NotificationCenter

class NetworkReachability {
    static let sharedInstance = NetworkReachability()
    static let NOTIFICATION = Notification.Name("NETWORK_REACHABILITY_CHANGED")

    let reachabilityManager = Alamofire.NetworkReachabilityManager()

    func setup() {
        guard let reachabilityManager = reachabilityManager else {
            return log.error("Failed to initialize reachability manager", context: nil)
        }

        reachabilityManager.startListening { status in
            log.info("Network status changed: \(status)", context: nil)
            NotificationCenter.default.post(name: NetworkReachability.NOTIFICATION, object: nil)
        }
    }

    func getIsReachable() -> Bool {
        guard let reachabilityManager = reachabilityManager else {
            return false
        }

        return reachabilityManager.isReachable
    }
}
