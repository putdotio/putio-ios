import Foundation
import PutioCore
import Synchronization

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
      if scenario == .live {
        // Live runs sign in to the devs-auto test account against put.io,
        // under the harness keychain item rather than the real login's.
        return PutioRuntime(
          clientID: clientID,
          clientName: clientName,
          tokenStore: liveTokenStore,
          signOutIntentStore: harnessSignOutIntentStore,
          supportIdentityPlatform: supportIdentityPlatform
        )
      }
      if scenario == .signedIn || scenario == .filesBrowser || scenario == .deviceSignIn {
        HarnessSeededAPI.trashEnabled = !ProcessInfo.processInfo.arguments.contains(
          "--putio-harness-trash-disabled"
        )
        HarnessSeededAPI.isEnabled = true
        HarnessSeededAPI.observeAccountRenewal()
        let failSignOut = usesSignOutFailureFixture(scenario: scenario)
        HarnessSeededAPI.configureSignOutFailure(failSignOut)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [HarnessSeededAPI.self]
        // Bounds only stray requests to hosts the mock does not claim; mocked
        // responses return in-process.
        configuration.timeoutIntervalForRequest = 10
        configuration.timeoutIntervalForResource = 10
        let tokenStore: PutioTokenStore
        let signOutIntentStore: PutioSignOutIntentStore
        if scenario == .filesBrowser || scenario == .deviceSignIn {
          let keychain = PutioKeychainTokenStore(service: harnessKeychainService)
          let arguments = ProcessInfo.processInfo.arguments
          if arguments.contains(signedOutAtLaunchArgument) {
            try? keychain.clear()
          }
          if arguments.contains(savedCredentialAtLaunchArgument) {
            try? keychain.write(HarnessSeededAPI.token)
            harnessSignOutIntentStore.setPending(false)
          }
          let failsCredentialRead = arguments.contains(credentialReadFailsOnceArgument)
          tokenStore =
            failSignOut || failsCredentialRead
            ? HarnessFaultyTokenStore(
              storage: keychain, failsFirstRead: failsCredentialRead, failsClear: failSignOut)
            : keychain
          signOutIntentStore = harnessSignOutIntentStore
        } else {
          tokenStore = PutioInMemoryTokenStore(token: HarnessSeededAPI.token)
          signOutIntentStore = PutioInMemorySignOutIntentStore()
        }
        return PutioRuntime(
          clientID: clientID,
          clientName: clientName,
          tokenStore: tokenStore,
          signOutIntentStore: signOutIntentStore,
          urlSession: URLSession(configuration: configuration),
          // The SDK clamps polling to one second; the seeded flow answers
          // pending, expired, and approved in consecutive polls.
          deviceCodePollInterval: .seconds(1),
          supportIdentityPlatform: supportIdentityPlatform
        )
      }
    #endif
    return PutioRuntime(
      clientID: clientID,
      clientName: clientName,
      tokenStore: PutioKeychainTokenStore(),
      supportIdentityPlatform: supportIdentityPlatform
    )
  }

  /// put.io signs the support-messenger identity per platform; only the iOS
  /// app runs the messenger.
  private static var supportIdentityPlatform: String? {
    #if os(iOS)
      "ios"
    #else
      nil
    #endif
  }

  static func usesSignOutFailureFixture(scenario: HarnessScenario) -> Bool {
    #if DEBUG
      scenario == .filesBrowser
        && ProcessInfo.processInfo.arguments.contains("--putio-harness-sign-out-failure")
    #else
      false
    #endif
  }

  #if DEBUG
    static let signedOutAtLaunchArgument = "--putio-harness-signed-out-at-launch"
    static let savedCredentialAtLaunchArgument = "--putio-harness-saved-credential-at-launch"
    static let credentialReadFailsOnceArgument = "--putio-harness-credential-read-fails-once"

    // Harness sign-in still round-trips the keychain for cold restore, but
    // never under the real login's item, which a proof run would overwrite
    // and a harness sign-out would delete.
    static var harnessKeychainService: String {
      (Bundle.main.bundleIdentifier ?? "io.put.dev") + ".harness"
    }

    static let liveTokenStore = HarnessLiveTokenStore(service: harnessKeychainService)

    static let harnessSignOutIntentStore = PutioUserDefaultsSignOutIntentStore(
      key: PutioUserDefaultsSignOutIntentStore.defaultKey + ".harness")

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

  // The checked-in default is the public open-source client; signed builds
  // set their own through Info.plist.
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
  private final class HarnessFaultyTokenStore: PutioTokenStore {
    private let storage: PutioTokenStore
    private let readFailurePending: Mutex<Bool>
    private let failsClear: Bool

    init(storage: PutioTokenStore, failsFirstRead: Bool, failsClear: Bool) {
      self.storage = storage
      readFailurePending = Mutex(failsFirstRead)
      self.failsClear = failsClear
    }

    func read() throws -> String? {
      let fails = readFailurePending.withLock { pending in
        defer { pending = false }
        return pending
      }
      if fails { throw HarnessRuntimeError.credentialReadFixture }
      return try storage.read()
    }

    func write(_ token: String) throws { try storage.write(token) }

    func clear() throws {
      if failsClear { throw HarnessRuntimeError.credentialRemovalFixture }
      try storage.clear()
    }
  }

  private enum HarnessRuntimeError: Error {
    case invalidOAuthCallback
    case missingOAuthState
    case credentialReadFixture
    case credentialRemovalFixture
  }
#endif
