import Foundation
import Network
import dnssd

@MainActor
final class PutioLocalNetworkProbe {
  private var browser: NWBrowser?

  func start(onChange: @escaping @MainActor (_ denied: Bool) -> Void) {
    guard browser == nil else { return }
    let browser = NWBrowser(
      for: .bonjour(type: "_googlecast._tcp", domain: nil), using: NWParameters())
    browser.stateUpdateHandler = { [weak self] state in
      let denied: Bool? =
        switch state {
        case .waiting(let error), .failed(let error): Self.isPolicyDenied(error)
        case .ready: false
        case .setup, .cancelled: nil
        @unknown default: nil
        }
      MainActor.assumeIsolated {
        if case .failed = state { self?.reset() }
        if let denied { onChange(denied) }
      }
    }
    browser.start(queue: .main)
    self.browser = browser
  }

  private func reset() {
    browser?.cancel()
    browser = nil
  }

  isolated deinit {
    browser?.cancel()
  }

  nonisolated static func isPolicyDenied(_ error: NWError) -> Bool {
    guard case .dns(let code) = error else { return false }
    return code == DNSServiceErrorType(kDNSServiceErr_PolicyDenied)
  }
}
