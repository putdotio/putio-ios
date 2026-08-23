import Foundation
import Observation
import PutioSDK

public enum PutioSignedOutReason: Equatable, Sendable {
  case sessionExpired
  case authenticationFailed(String)
  case restoreFailed(String)
  case userSignedOut
}

// Closed session lifecycle: signedOut -> authenticating -> signedIn, with
// restore and sign-out re-entering signedOut. `unknown` exists only until the
// first restore() resolves on launch.
public enum PutioSessionState: Equatable {
  case unknown
  case signedOut(PutioSignedOutReason?)
  case authenticating
  case signedIn(PutioAccount)

  public static func == (lhs: PutioSessionState, rhs: PutioSessionState) -> Bool {
    switch (lhs, rhs) {
    case (.unknown, .unknown), (.authenticating, .authenticating):
      true
    case (.signedOut(let left), .signedOut(let right)):
      left == right
    case (.signedIn(let left), .signedIn(let right)):
      left.username == right.username
    default:
      false
    }
  }
}

public struct PutioSignInRequest: Sendable {
  public let url: URL
  public let callbackScheme: String
}

@MainActor
@Observable
public final class PutioSessionStore {
  public private(set) var state: PutioSessionState = .unknown

  private let sdk: PutioSDK
  private let tokenStore: PutioTokenStore
  private let callbackScheme: String
  private let callbackHost = "auth"
  private var pendingOAuthState: String?

  public init(
    sdk: PutioSDK,
    tokenStore: PutioTokenStore,
    callbackScheme: String = "putio"
  ) {
    self.sdk = sdk
    self.tokenStore = tokenStore
    self.callbackScheme = callbackScheme
  }

  // MARK: - Launch restore

  public func restore() async {
    guard let token = try? tokenStore.read(), !token.isEmpty else {
      state = .signedOut(nil)
      return
    }
    sdk.setToken(token: token)
    do {
      let validation = try await sdk.validateToken(token: token)
      guard validation.result else {
        try? tokenStore.clear()
        sdk.clearToken()
        state = .signedOut(.sessionExpired)
        return
      }
      await bootstrap(failure: PutioSignedOutReason.restoreFailed)
    } catch {
      if isAuthRejection(error) {
        try? tokenStore.clear()
        sdk.clearToken()
        state = .signedOut(.sessionExpired)
      } else {
        // Transient failure: keep the token so a retry can restore without
        // re-authenticating.
        sdk.clearToken()
        state = .signedOut(.restoreFailed(message(for: error)))
      }
    }
  }

  // MARK: - Sign in

  public func beginSignIn() throws -> PutioSignInRequest {
    let oauthState = try PutioSDK.generateOAuthState()
    pendingOAuthState = oauthState
    state = .authenticating
    let url = sdk.getAuthURL(
      redirectURI: "\(callbackScheme)://\(callbackHost)",
      state: oauthState
    )
    return PutioSignInRequest(url: url, callbackScheme: callbackScheme)
  }

  public func completeSignIn(callbackURL: URL) async {
    guard let expectedState = pendingOAuthState else {
      state = .signedOut(.authenticationFailed("No sign-in is in progress."))
      return
    }
    pendingOAuthState = nil
    do {
      let token = try sdk.accessToken(
        fromOAuthCallback: callbackURL,
        expectedScheme: callbackScheme,
        expectedHost: callbackHost,
        expectedState: expectedState
      )
      sdk.setToken(token: token)
      try tokenStore.write(token)
      await bootstrap(failure: PutioSignedOutReason.authenticationFailed)
    } catch {
      sdk.clearToken()
      state = .signedOut(.authenticationFailed(message(for: error)))
    }
  }

  public func cancelSignIn() {
    pendingOAuthState = nil
    state = .signedOut(nil)
  }

  public func failSignIn(_ error: Error) {
    pendingOAuthState = nil
    sdk.clearToken()
    state = .signedOut(.authenticationFailed(message(for: error)))
  }

  // MARK: - Sign out

  public func signOut() async {
    _ = try? await sdk.logout()
    sdk.clearToken()
    try? tokenStore.clear()
    state = .signedOut(.userSignedOut)
  }

  // MARK: - Account bootstrap

  private func bootstrap(failure: (String) -> PutioSignedOutReason) async {
    do {
      let account = try await sdk.getAccountInfo()
      state = .signedIn(account)
    } catch {
      if isAuthRejection(error) {
        try? tokenStore.clear()
        sdk.clearToken()
        state = .signedOut(.sessionExpired)
      } else {
        sdk.clearToken()
        state = .signedOut(failure(message(for: error)))
      }
    }
  }

  // MARK: - Failure classification

  private func isAuthRejection(_ error: Error) -> Bool {
    guard let sdkError = error as? PutioSDKError else { return false }
    if case .httpError(let statusCode, _) = sdkError.type {
      return statusCode == 401 || statusCode == 403
    }
    return false
  }

  private func message(for error: Error) -> String {
    if let sdkError = error as? PutioSDKError {
      switch sdkError.type {
      case .networkError:
        return "put.io is unreachable. Check your connection and try again."
      case .httpError, .decodingError, .unknownError:
        return "put.io could not complete the request. Try again."
      }
    }
    return (error as? LocalizedError)?.errorDescription
      ?? "Sign-in did not complete. Try again."
  }
}
