import Foundation
import PutioSDK

@MainActor
public final class PutioRuntime {
  public let session: PutioSessionStore

  let sdk: PutioSDK

  public init(
    clientID: String,
    clientName: String,
    callbackScheme: String = "putio",
    tokenStore: PutioTokenStore = PutioKeychainTokenStore(),
    urlSession: URLSession = .shared,
    deviceCodePollInterval: Duration = .seconds(3)
  ) {
    let sdk = PutioSDK(
      config: PutioSDKConfig(clientID: clientID, clientName: clientName),
      urlSession: urlSession
    )
    self.sdk = sdk
    self.session = PutioSessionStore(
      sdk: sdk,
      tokenStore: tokenStore,
      callbackScheme: callbackScheme,
      deviceCodePollInterval: deviceCodePollInterval
    )
  }

  /// Reloads the account snapshot, for example to retry the refresh that
  /// follows a committed storage or preferences mutation. See
  /// `PutioSessionStore.isAccountStorageStale` and
  /// `PutioSessionStore.isAccountPreferencesStale`.
  public func refreshAccount() async -> Bool {
    await session.refreshAccount()
  }

  /// A committing operation keeps a decoded success even if the task was
  /// cancelled while the response was in flight: the server already applied
  /// it, and callers must reconcile rather than treat it as never sent.
  func performAuthenticatedOperation<Value>(
    commits: Bool = false,
    _ operation: () async throws -> Value
  ) async throws -> Value {
    guard case .signedIn = session.state else {
      throw currentSessionError
    }
    let authenticationGeneration = session.authenticationGeneration

    do {
      try Task.checkCancellation()
      let result = try await operation()
      if !commits { try Task.checkCancellation() }

      guard
        authenticationGeneration == session.authenticationGeneration,
        case .signedIn = session.state
      else {
        throw currentSessionError
      }
      return result
    } catch {
      let sdkError = error as? PutioSDKError
      // put.io rejected the credential even if the caller no longer wants the
      // result; the session still has to end.
      if sdkError?.isAuthenticationFailure == true,
        authenticationGeneration == session.authenticationGeneration,
        case .signedIn = session.state
      {
        session.expireSession()
        throw PutioRuntimeError.sessionExpired
      }

      if Task.isCancelled || isCancellation(error) {
        throw CancellationError()
      }

      guard
        authenticationGeneration == session.authenticationGeneration,
        case .signedIn = session.state
      else {
        throw currentSessionError
      }

      if let rejection = error as? PutioAccountSecurityError { throw rejection }
      guard let sdkError else {
        throw PutioRuntimeError.unknown
      }
      if sdkError.isNotFound {
        throw PutioRuntimeError.notFound
      }
      if sdkError.isRateLimited {
        throw PutioRuntimeError.rateLimited
      }
      if sdkError.isRetryable {
        throw PutioRuntimeError.transient
      }
      if sdkError.isDecodingFailure {
        throw PutioRuntimeError.invalidResponse
      }
      throw PutioRuntimeError.unknown
    }
  }

  /// Media URLs reach AVFoundation, AirPlay, Cast receivers, and other apps,
  /// so they carry the account's download token, which put.io accepts only
  /// for media and downloads, never the session token. A signed-in account
  /// without one is an invalid response, not a reason to fall back.
  func requireDownloadToken(_ token: String?) throws -> String {
    guard let token, !token.isEmpty, token != sdk.config.token else {
      throw PutioRuntimeError.invalidResponse
    }
    return token
  }

  /// Swaps the session token the SDK puts on playback URLs for the download token.
  func replacingMediaToken(in url: URL, with token: String) throws -> URL {
    guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
      throw PutioRuntimeError.invalidResponse
    }
    var items = (components.queryItems ?? []).filter { $0.name != "oauth_token" }
    items.append(URLQueryItem(name: "oauth_token", value: token))
    components.queryItems = items
    guard let replaced = components.url else { throw PutioRuntimeError.invalidResponse }
    return replaced
  }

  var currentSessionError: PutioRuntimeError {
    if case .signedOut(let reason) = session.state, reason == .sessionExpired {
      return .sessionExpired
    }
    return .authenticationRequired
  }

  func snapshot(_ file: PutioFile) -> PutioFileItem {
    PutioFileItem(
      id: PutioFileID(rawValue: file.id),
      parentID: PutioFileID(rawValue: file.parentID),
      name: file.name,
      kind: kind(for: file.type),
      sizeBytes: file.size,
      createdAt: file.createdAt,
      updatedAt: file.updatedAt,
      resumePositionSeconds: file.startFrom,
      isShared: file.isShared
    )
  }

  func kind(for type: PutioFileType) -> PutioFileKind {
    switch type {
    case .folder:
      .folder
    case .video:
      .video
    case .audio:
      .audio
    case .image:
      .image
    case .pdf:
      .pdf
    default:
      .other(type.rawValue)
    }
  }

  private func isCancellation(_ error: Error) -> Bool {
    if error is CancellationError {
      return true
    }
    if let urlError = error as? URLError, urlError.code == .cancelled {
      return true
    }
    if let sdkError = error as? PutioSDKError {
      return isCancellation(sdkError.underlyingError)
    }
    return false
  }
}
