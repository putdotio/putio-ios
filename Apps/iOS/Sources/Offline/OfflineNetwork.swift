import Foundation
import Network

final class PutioOfflineNetworkMonitor {
  private let monitor = NWPathMonitor()

  init(onChange: @escaping @MainActor @Sendable (Bool) -> Void) {
    monitor.pathUpdateHandler = { path in
      let online = path.status == .satisfied
      Task { @MainActor in onChange(online) }
    }
    monitor.start(queue: DispatchQueue(label: "io.put.offline.network"))
  }

  func cancel() {
    monitor.cancel()
  }
}
