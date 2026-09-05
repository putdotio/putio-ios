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
      if scenario == .signedIn || scenario == .filesBrowser {
        HarnessSeededAPI.trashEnabled = !ProcessInfo.processInfo.arguments.contains(
          "--putio-harness-trash-disabled"
        )
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
          tokenStore: scenario == .filesBrowser
            ? PutioKeychainTokenStore()
            : PutioInMemoryTokenStore(token: HarnessSeededAPI.token),
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

  #if DEBUG
    static func runtimeProofCallback(for request: PutioSignInRequest) throws -> URL {
      guard
        let state = URLComponents(url: request.url, resolvingAgainstBaseURL: false)?
          .queryItems?
          .first(where: { $0.name == "state" })?
          .value,
        !state.isEmpty
      else {
        throw HarnessRuntimeError.missingOAuthState
      }
      var callback = URLComponents()
      callback.scheme = request.callbackScheme
      callback.host = "auth"
      callback.fragment = "access_token=\(HarnessSeededAPI.token)&state=\(state)"
      guard let url = callback.url else {
        throw HarnessRuntimeError.invalidOAuthCallback
      }
      return url
    }
  #endif

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

#if DEBUG
  private enum HarnessRuntimeError: Error {
    case invalidOAuthCallback
    case missingOAuthState
  }
#endif
