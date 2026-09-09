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
// signingOut -> signedOut or signOutFailed -> signingOut. `unknown` exists
// only until the first restore() resolves on launch.
public enum PutioSessionState: Equatable, Sendable {
  case unknown
  case signedOut(PutioSignedOutReason?)
  case authenticating
  case signedIn(PutioAccountSnapshot)
  case signingOut
  case signOutFailed(PutioSignOutFailure)
}

public enum PutioSignOutFailure: Equatable, Sendable {
  case credentialRemoval
  case revocation
  case credentialRemovalAndRevocation
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
  /// True while a committed storage mutation has not been reflected in the
  /// signed-in snapshot. Owned here so it survives leaving the screen that
  /// caused it; any later successful refresh clears it.
  public private(set) var isAccountStorageStale = false
  /// A preference write has completed, but its account snapshot remains unconfirmed.
  public private(set) var isAccountPreferencesStale = false
  public private(set) var isUpdatingAccountPreferences = false
  public private(set) var folderSortsRevision: UInt64 = 0
  private var lastPreferencesMutationSequence: UInt64 = 0
  private(set) var authenticationGeneration: UInt64 = 0
  // Orders overlapping account refreshes inside one session so a slow older
  // response cannot overwrite a newer snapshot.
  private var accountRefreshSequence: UInt64 = 0
  private var lastAppliedAccountRefresh: UInt64 = 0
  // Sequence value at the most recent committed storage mutation. Only a
  // refresh that started after it observed the mutation's effect.
  private var lastStorageMutationSequence: UInt64 = 0

  private let sdk: PutioSDK
  private let tokenStore: PutioTokenStore
  private let callbackScheme: String
  private let callbackHost = "auth"
  private var pendingOAuthState: String?
  private var pendingOAuthGeneration: UInt64?
  // Kept only for a deliberate revocation retry; failed sign-out never leaves
  // this credential active on the shared SDK.
  private var pendingSignOutToken: String?

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
    case .authenticating, .signedIn, .signingOut, .signOutFailed:
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
    case .authenticating, .signedIn, .signingOut, .signOutFailed:
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
    switch state {
    case .signingOut, .signOutFailed: return
    default: break
    }
    pendingOAuthState = nil
    pendingOAuthGeneration = nil
    _ = advanceAuthenticationGeneration()
    state = .signedOut(nil)
  }

  public func failSignIn(_ error: Error) {
    if error as? PutioSessionOperationError == .signInUnavailable {
      return
    }
    switch state {
    case .signingOut, .signOutFailed: return
    default: break
    }
    pendingOAuthState = nil
    pendingOAuthGeneration = nil
    _ = advanceAuthenticationGeneration()
    sdk.clearToken()
    state = .signedOut(.authenticationFailed(message(for: error)))
  }

  // MARK: - Sign out

  public func signOut() async {
    switch state {
    case .signingOut: return
    case .signOutFailed: break
    default:
      pendingSignOutToken = sdk.config.token.isEmpty ? nil : sdk.config.token
    }
    pendingOAuthState = nil
    pendingOAuthGeneration = nil
    let generation = advanceAuthenticationGeneration()
    state = .signingOut
    var credentialRemovalFailed = false
    do {
      try tokenStore.clear()
    } catch {
      credentialRemovalFailed = true
    }
    var revocationFailed = false
    if let token = pendingSignOutToken {
      sdk.setToken(token: token)
      do {
        _ = try await sdk.logout()
      } catch {
        // An already rejected token no longer needs revocation.
        revocationFailed = !isAuthRejection(error)
      }
    }
    guard generation == authenticationGeneration else { return }
    sdk.clearToken()
    if !revocationFailed { pendingSignOutToken = nil }
    switch (credentialRemovalFailed, revocationFailed) {
    case (false, false): state = .signedOut(.userSignedOut)
    case (true, false): state = .signOutFailed(.credentialRemoval)
    case (false, true): state = .signOutFailed(.revocation)
    case (true, true): state = .signOutFailed(.credentialRemovalAndRevocation)
    }
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

  /// Reloads the account after a committed mutation changed storage. The
  /// mutation itself is already durable; this only tracks whether the
  /// snapshot followed. Returns `false` when the snapshot is still stale.
  @discardableResult
  func refreshAccountAfterStorageMutation() async -> Bool {
    isAccountStorageStale = true
    lastStorageMutationSequence = accountRefreshSequence
    return await refreshAccount()
  }

  func invalidateFolderSorts(generation: UInt64) {
    guard generation == authenticationGeneration, case .signedIn = state else { return }
    // A reset may commit even when its response is lost. Mounted folders must
    // reload independently of the preferences screen that started the write.
    folderSortsRevision &+= 1
  }

  func beginAccountPreferencesUpdate() {
    isUpdatingAccountPreferences = true
  }

  func endAccountPreferencesUpdate(generation: UInt64) {
    guard authenticationGeneration == generation else { return }
    isUpdatingAccountPreferences = false
  }

  func applyAcknowledgedPreferences(
    defaultSort: PutioFolderSort? = nil, trashEnabled: Bool? = nil, historyEnabled: Bool? = nil,
    routeName: String? = nil, hideSubtitles: Bool? = nil, dontAutoSelectSubtitles: Bool? = nil
  ) {
    guard case .signedIn(let account) = state else { return }
    state = .signedIn(
      PutioAccountSnapshot(
        id: account.id, username: account.username, email: account.email,
        suggestNextVideo: account.suggestNextVideo, rememberVideoTime: account.rememberVideoTime,
        defaultSort: defaultSort ?? account.defaultSort,
        historyEnabled: historyEnabled ?? account.historyEnabled,
        trashEnabled: trashEnabled ?? account.trashEnabled, storage: account.storage,
        routeName: routeName ?? account.routeName,
        hideSubtitles: hideSubtitles ?? account.hideSubtitles,
        dontAutoSelectSubtitles: dontAutoSelectSubtitles ?? account.dontAutoSelectSubtitles))
  }

  @discardableResult
  func refreshAccountAfterPreferencesMutation(storageChanged: Bool) async -> Bool {
    isAccountPreferencesStale = true
    lastPreferencesMutationSequence = accountRefreshSequence
    if storageChanged {
      isAccountStorageStale = true
      lastStorageMutationSequence = accountRefreshSequence
    }
    return await refreshAccount()
  }

  /// Reloads the signed-in account snapshot. Returns `false` when the snapshot
  /// could not be updated so callers retain stale storage or preference warnings;
  /// an authentication rejection expires the session instead.
  @discardableResult
  func refreshAccount() async -> Bool {
    guard case .signedIn = state else { return false }
    let generation = authenticationGeneration
    accountRefreshSequence &+= 1
    let sequence = accountRefreshSequence
    do {
      let account = try await sdk.getAccountInfo()
      guard generation == authenticationGeneration, !Task.isCancelled,
        case .signedIn = state
      else { return false }
      // A newer response already applied a fresher snapshot: report its
      // success. A newer request that failed leaves ours as the latest
      // truth, so apply it.
      if lastAppliedAccountRefresh > sequence {
        return !isAccountStorageStale && !isAccountPreferencesStale
      }
      guard sequence > lastStorageMutationSequence,
        sequence > lastPreferencesMutationSequence
      else { return false }
      lastAppliedAccountRefresh = sequence
      state = .signedIn(snapshot(account))
      isAccountStorageStale = false
      isAccountPreferencesStale = false
      return true
    } catch {
      guard generation == authenticationGeneration, !Task.isCancelled,
        case .signedIn = state
      else { return false }
      if isAuthRejection(error) { expireSession() }
      return false
    }
  }

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
    // A new session boundary starts from a fresh bootstrap snapshot.
    isAccountStorageStale = false
    isAccountPreferencesStale = false
    isUpdatingAccountPreferences = false
    lastPreferencesMutationSequence = 0
    lastAppliedAccountRefresh = 0
    accountRefreshSequence = 0
    lastStorageMutationSequence = 0
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
      suggestNextVideo: account.settings.suggestNextVideo,
      rememberVideoTime: account.settings.rememberVideoTime,
      defaultSort: PutioFolderSort(rawValue: account.settings.sortBy),
      historyEnabled: account.settings.historyEnabled,
      trashEnabled: account.settings.trashEnabled,
      storage: PutioAccountSnapshot.Storage(
        availableBytes: account.disk.available,
        totalBytes: account.disk.size,
        usedBytes: account.disk.used
      ),
      routeName: account.settings.routeName,
      hideSubtitles: account.settings.hideSubtitles,
      dontAutoSelectSubtitles: account.settings.dontAutoSelectSubtitles
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
