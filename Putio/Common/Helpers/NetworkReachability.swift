import Foundation
import Network
import NotificationCenter

class NetworkReachability {
    static let sharedInstance = NetworkReachability()
    static let NOTIFICATION = Notification.Name("NETWORK_REACHABILITY_CHANGED")

    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "io.put.network-reachability")
    private var isReachable = false

    func setup() {
        monitor.pathUpdateHandler = { [weak self] path in
            guard let self = self else { return }

            self.isReachable = path.status == .satisfied
            log.info("Network status changed: \(path.status)", context: nil)
            NotificationCenter.default.post(name: NetworkReachability.NOTIFICATION, object: nil)
        }

        monitor.start(queue: queue)
    }

    func getIsReachable() -> Bool {
        return isReachable
    }
}
