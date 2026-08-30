import Foundation
import PutioCore

#if canImport(UIKit)
  import UIKit
#endif
#if canImport(WatchKit)
  import WatchKit
#endif

enum PutioRuntimeFactory {
  @MainActor
  static func make(scenario: HarnessScenario) -> PutioRuntime {
    #if DEBUG
      if scenario == .signedIn {
        HarnessSeededAPI.isEnabled = true
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [HarnessSeededAPI.self]
        // Bounds only stray requests to hosts the mock does not claim; mocked
        // responses return in-process.
        configuration.timeoutIntervalForRequest = 10
        configuration.timeoutIntervalForResource = 10
        return PutioRuntime(
          clientID: clientID,
          clientName: clientName,
          tokenStore: PutioInMemoryTokenStore(token: HarnessSeededAPI.token),
          urlSession: URLSession(configuration: configuration)
        )
      }
    #endif
    return PutioRuntime(
      clientID: clientID,
      clientName: clientName,
      tokenStore: PutioKeychainTokenStore()
    )
  }

  // The checked-in default stays open-source-safe; a registered client id
  // arrives with the app-identity work through the same Info.plist key the
  // legacy app uses.
  private static var clientID: String {
    let configured = Bundle.main.object(forInfoDictionaryKey: "PUTIO_OAUTH_CLIENT_ID") as? String
    let trimmed = configured?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    return trimmed.isEmpty ? "3001" : trimmed
  }

  private static var clientName: String {
    #if os(watchOS)
      WKInterfaceDevice.current().name
    #elseif canImport(UIKit)
      UIDevice.current.name
    #else
      ProcessInfo.processInfo.hostName
    #endif
  }
}
