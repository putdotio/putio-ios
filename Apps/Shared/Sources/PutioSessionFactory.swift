import Foundation
import PutioCore
import PutioSDK

#if canImport(UIKit)
  import UIKit
#endif
#if canImport(WatchKit)
  import WatchKit
#endif

enum PutioSessionFactory {
  @MainActor
  static func make(scenario: HarnessScenario) -> PutioSessionStore {
    #if DEBUG
      if scenario == .signedIn {
        HarnessSeededAPI.isEnabled = true
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [HarnessSeededAPI.self]
        // Bounds only stray requests to hosts the mock does not claim; mocked
        // responses return in-process.
        configuration.timeoutIntervalForRequest = 10
        configuration.timeoutIntervalForResource = 10
        return PutioSessionStore(
          sdk: PutioSDK(config: sdkConfig, urlSession: URLSession(configuration: configuration)),
          tokenStore: PutioInMemoryTokenStore(token: HarnessSeededAPI.token)
        )
      }
    #endif
    return PutioSessionStore(
      sdk: PutioSDK(config: sdkConfig),
      tokenStore: PutioKeychainTokenStore()
    )
  }

  private static var sdkConfig: PutioSDKConfig {
    PutioSDKConfig(clientID: clientID, clientName: clientName)
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
