import Foundation
import Observation
import PutioSDK

public enum PutioSignedOutReason: Equatable, Sendable {
  case sessionExpired
  case authenticationFailed(String)
  case restoreFailed(String)
  case userSignedOut
}

// Closed session lifecycle: signedOut -> authenticating -> signedIn ->
// signingOut -> signedOut. `unknown` exists only until the first restore()
// resolves on launch.
public enum PutioSessionState: Equatable, Sendable {
  case unknown
  case signedOut(PutioSignedOutReason?)
  case authenticating
  case signedIn(PutioAccountSnapshot)
  case signingOut
}

public enum PutioSessionOperationError: Error, Equatable, Sendable {
  case signInUnavailable
}

public struct PutioSignInRequest: Sendable {
  public let url: URL
  public let callbackScheme: String
}

@MainActor
@Observable
public final class PutioSessionStore {
  public private(set) var state: PutioSessionState = .unknown
  private(set) var authenticationGeneration: UInt64 = 0

  private let sdk: PutioSDK
  private let tokenStore: PutioTokenStore
  private let callbackScheme: String
  private let callbackHost = "auth"
  private var pendingOAuthState: String?
  private var pendingOAuthGeneration: UInt64?

  init(
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
    switch state {
    case .unknown, .signedOut:
      break
    case .authenticating, .signedIn, .signingOut:
      return
    }
    pendingOAuthState = nil
    pendingOAuthGeneration = nil
    let generation = advanceAuthenticationGeneration()
    guard let token = try? tokenStore.read(), !token.isEmpty else {
      sdk.clearToken()
      state = .signedOut(nil)
      return
    }
    sdk.setToken(token: token)
    do {
      let validation = try await sdk.validateToken(token: token)
      guard generation == authenticationGeneration else { return }
      guard validation.result else {
        expireSession()
        return
      }
      await bootstrap(failure: PutioSignedOutReason.restoreFailed, generation: generation)
    } catch {
      guard generation == authenticationGeneration else { return }
      if isAuthRejection(error) {
        expireSession()
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
    switch state {
    case .unknown, .signedOut:
      break
    case .authenticating, .signedIn, .signingOut:
      throw PutioSessionOperationError.signInUnavailable
    }
    let oauthState = try PutioSDK.generateOAuthState()
    let generation = advanceAuthenticationGeneration()
    pendingOAuthState = oauthState
    pendingOAuthGeneration = generation
    state = .authenticating
    let url = sdk.getAuthURL(
      redirectURI: "\(callbackScheme)://\(callbackHost)",
      state: oauthState
    )
    return PutioSignInRequest(url: url, callbackScheme: callbackScheme)
  }

  public func completeSignIn(callbackURL: URL) async {
    guard
      let expectedState = pendingOAuthState,
      let generation = pendingOAuthGeneration,
      generation == authenticationGeneration
    else {
      // A callback without a live transaction may only fail an active
      // sign-in; outside `.authenticating` it must not disturb a signed-in
      // session or a sign-out that still owns credential cleanup.
      guard case .authenticating = state else { return }
      pendingOAuthState = nil
      pendingOAuthGeneration = nil
      _ = advanceAuthenticationGeneration()
      state = .signedOut(.authenticationFailed("No sign-in is in progress."))
      return
    }
    pendingOAuthState = nil
    pendingOAuthGeneration = nil
    do {
      let token = try sdk.accessToken(
        fromOAuthCallback: callbackURL,
        expectedScheme: callbackScheme,
        expectedHost: callbackHost,
        expectedState: expectedState
      )
      guard generation == authenticationGeneration else { return }
      sdk.setToken(token: token)
      try tokenStore.write(token)
      await bootstrap(failure: PutioSignedOutReason.authenticationFailed, generation: generation)
    } catch {
      guard generation == authenticationGeneration else { return }
      sdk.clearToken()
      state = .signedOut(.authenticationFailed(message(for: error)))
    }
  }

  public func cancelSignIn() {
    pendingOAuthState = nil
    pendingOAuthGeneration = nil
    _ = advanceAuthenticationGeneration()
    state = .signedOut(nil)
  }

  public func failSignIn(_ error: Error) {
    if error as? PutioSessionOperationError == .signInUnavailable {
      return
    }
    pendingOAuthState = nil
    pendingOAuthGeneration = nil
    _ = advanceAuthenticationGeneration()
    sdk.clearToken()
    state = .signedOut(.authenticationFailed(message(for: error)))
  }

  // MARK: - Sign out

  public func signOut() async {
    pendingOAuthState = nil
    pendingOAuthGeneration = nil
    let generation = advanceAuthenticationGeneration()
    state = .signingOut
    try? tokenStore.clear()
    _ = try? await sdk.logout()
    guard generation == authenticationGeneration else { return }
    sdk.clearToken()
    state = .signedOut(.userSignedOut)
  }

  func expireSession() {
    pendingOAuthState = nil
    pendingOAuthGeneration = nil
    _ = advanceAuthenticationGeneration()
    sdk.clearToken()
    try? tokenStore.clear()
    state = .signedOut(.sessionExpired)
  }

  // MARK: - Account bootstrap

  private func bootstrap(
    failure: (String) -> PutioSignedOutReason,
    generation: UInt64
  ) async {
    do {
      let account = try await sdk.getAccountInfo()
      guard generation == authenticationGeneration else { return }
      state = .signedIn(snapshot(account))
    } catch {
      guard generation == authenticationGeneration else { return }
      if isAuthRejection(error) {
        expireSession()
      } else {
        sdk.clearToken()
        state = .signedOut(failure(message(for: error)))
      }
    }
  }

  // MARK: - Failure classification

  @discardableResult
  private func advanceAuthenticationGeneration() -> UInt64 {
    authenticationGeneration += 1
    return authenticationGeneration
  }

  private func isAuthRejection(_ error: Error) -> Bool {
    (error as? PutioSDKError)?.isAuthenticationFailure == true
  }

  private func snapshot(_ account: PutioAccount) -> PutioAccountSnapshot {
    PutioAccountSnapshot(
      id: account.id,
      username: account.username,
      email: account.mail,
      storage: PutioAccountSnapshot.Storage(
        availableBytes: account.disk.available,
        totalBytes: account.disk.size,
        usedBytes: account.disk.used
      )
    )
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
