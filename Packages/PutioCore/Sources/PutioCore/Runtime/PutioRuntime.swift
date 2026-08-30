import Foundation
import PutioSDK

@MainActor
public final class PutioRuntime {
  public let session: PutioSessionStore

  private let sdk: PutioSDK

  public init(
    clientID: String,
    clientName: String,
    callbackScheme: String = "putio",
    tokenStore: PutioTokenStore = PutioKeychainTokenStore(),
    urlSession: URLSession = .shared
  ) {
    let sdk = PutioSDK(
      config: PutioSDKConfig(clientID: clientID, clientName: clientName),
      urlSession: urlSession
    )
    self.sdk = sdk
    self.session = PutioSessionStore(
      sdk: sdk,
      tokenStore: tokenStore,
      callbackScheme: callbackScheme
    )
  }

  public func listFiles(parentID: PutioFileID = .root) async throws -> PutioFolderContents {
    let result = try await performAuthenticatedOperation {
      let result = try await sdk.getFiles(parentID: parentID.rawValue)
      return result
    }

    return PutioFolderContents(
      folder: result.parent.map(snapshot),
      items: result.children.map(snapshot),
      hasMore: result.cursor?.isEmpty == false
    )
  }

  public func resolveVideoPlaybackSource(fileID: PutioFileID) async throws
    -> PutioPlaybackResolution
  {
    let resolution = try await performAuthenticatedOperation {
      try await sdk.resolveVideoPlaybackSource(fileID: fileID.rawValue)
    }

    switch resolution {
    case .ready(let source):
      return .ready(
        PutioPlaybackSource(url: source.url, startFromSeconds: source.startFrom)
      )
    case .conversionRequired:
      return .conversionRequired
    }
  }

  private func performAuthenticatedOperation<Value>(
    _ operation: () async throws -> Value
  ) async throws -> Value {
    guard case .signedIn = session.state else {
      throw currentSessionError
    }
    let authenticationGeneration = session.authenticationGeneration

    do {
      try Task.checkCancellation()
      let result = try await operation()
      try Task.checkCancellation()

      guard
        authenticationGeneration == session.authenticationGeneration,
        case .signedIn = session.state
      else {
        throw currentSessionError
      }
      return result
    } catch {
      if Task.isCancelled || isCancellation(error) {
        throw CancellationError()
      }

      guard
        authenticationGeneration == session.authenticationGeneration,
        case .signedIn = session.state
      else {
        throw currentSessionError
      }

      guard let sdkError = error as? PutioSDKError else {
        throw PutioRuntimeError.unknown
      }
      if sdkError.isAuthenticationFailure {
        session.expireSession()
        throw PutioRuntimeError.sessionExpired
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

  private var currentSessionError: PutioRuntimeError {
    if case .signedOut(let reason) = session.state, reason == .sessionExpired {
      return .sessionExpired
    }
    return .authenticationRequired
  }

  private func snapshot(_ file: PutioFile) -> PutioFileItem {
    PutioFileItem(
      id: PutioFileID(rawValue: file.id),
      parentID: PutioFileID(rawValue: file.parentID),
      name: file.name,
      kind: kind(for: file.type),
      sizeBytes: file.size,
      createdAt: file.createdAt,
      updatedAt: file.updatedAt,
      resumePositionSeconds: file.startFrom
    )
  }

  private func kind(for type: PutioFileType) -> PutioFileKind {
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
