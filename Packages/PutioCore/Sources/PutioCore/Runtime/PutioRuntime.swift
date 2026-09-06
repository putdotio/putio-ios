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

  public func createFolder(name: String, parentID: PutioFileID) async throws -> PutioFileItem {
    let folder = try await performAuthenticatedOperation {
      try await sdk.createFolder(name: name, parentID: parentID.rawValue)
    }
    return snapshot(folder)
  }

  public func renameFile(fileID: PutioFileID, name: String) async throws {
    _ = try await performAuthenticatedOperation {
      try await sdk.renameFile(fileID: fileID.rawValue, name: name)
    }
  }

  public func moveFile(fileID: PutioFileID, to parentID: PutioFileID) async throws {
    let response = try await performAuthenticatedOperation {
      try await sdk.moveFiles(fileIDs: [fileID.rawValue], parentID: parentID.rawValue)
    }

    guard response.status == "OK" else {
      throw PutioRuntimeError.invalidResponse
    }
    guard !response.errors.isEmpty else { return }
    guard response.errors.count == 1, response.errors[0].id == fileID.rawValue else {
      throw PutioRuntimeError.invalidResponse
    }

    throw runtimeError(forStructuredStatusCode: response.errors[0].statusCode)
  }

  public func deleteFile(fileID: PutioFileID) async throws {
    _ = try await performAuthenticatedOperation {
      try await sdk.deleteFiles(fileIDs: [fileID.rawValue])
    }
  }

  public func listTrash(cursor: String? = nil) async throws -> PutioTrashPage {
    let result = try await performAuthenticatedOperation {
      if let cursor {
        return try await sdk.continueListTrash(cursor: cursor)
      }
      return try await sdk.listTrash()
    }

    return PutioTrashPage(
      items: result.files.map(trashSnapshot),
      nextCursor: result.cursor?.isEmpty == false ? result.cursor : nil,
      totalCount: result.total,
      sizeBytes: result.trashSize
    )
  }

  public func restoreTrashItem(fileID: PutioFileID) async throws -> PutioTrashRestoreResult {
    let response = try await performAuthenticatedOperation {
      try await sdk.restoreTrashFiles(fileIDs: [fileID.rawValue], cursor: nil)
    }
    guard response.status == "OK" else { throw PutioRuntimeError.invalidResponse }
    do {
      let restoredFile = try await performAuthenticatedOperation {
        try await sdk.getFile(fileID: fileID.rawValue)
      }
      return .restored(destinationID: snapshot(restoredFile).parentID)
    } catch {
      return .restoredDestinationUnknown
    }
  }

  public func permanentlyDeleteTrashItem(fileID: PutioFileID) async throws {
    let response = try await performAuthenticatedOperation {
      try await sdk.deleteTrashFiles(fileIDs: [fileID.rawValue], cursor: nil)
    }
    guard response.status == "OK" else { throw PutioRuntimeError.invalidResponse }
    await session.refreshAccount()
  }

  public func emptyTrash() async throws {
    let response = try await performAuthenticatedOperation {
      try await sdk.emptyTrash()
    }
    guard response.status == "OK" else { throw PutioRuntimeError.invalidResponse }
    await session.refreshAccount()
  }

  public func findNextVideo(after fileID: PutioFileID) async throws -> PutioNextVideo? {
    let nextFile = try await performAuthenticatedOperation {
      try await sdk.findNextFileIfAvailable(fileID: fileID.rawValue, fileType: .video)
    }
    guard let nextFile else { return nil }

    return PutioNextVideo(
      id: PutioFileID(rawValue: nextFile.id),
      parentID: PutioFileID(rawValue: nextFile.parentID),
      name: nextFile.name
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

  public func reportVideoPlaybackPosition(fileID: PutioFileID, seconds: Int) async throws {
    _ = try await performAuthenticatedOperation {
      try await sdk.setStartFrom(fileID: fileID.rawValue, time: seconds)
    }
  }

  public func startVideoConversion(fileID: PutioFileID) async throws {
    _ = try await performAuthenticatedOperation {
      try await sdk.startMp4Conversion(fileID: fileID.rawValue)
    }
  }

  public func videoConversionStatus(fileID: PutioFileID) async throws
    -> PutioVideoConversionStatus
  {
    let conversion = try await performAuthenticatedOperation {
      try await sdk.getMp4ConversionStatus(fileID: fileID.rawValue)
    }
    let progress = Double(conversion.percentDone)
    guard progress.isFinite, (0...1).contains(progress) else {
      throw PutioRuntimeError.invalidResponse
    }

    switch conversion.status {
    case .queued:
      return .queued
    case .converting:
      return .converting(progress: progress)
    case .completed:
      return .completed
    case .error, .notAvailable:
      return .failed
    default:
      throw PutioRuntimeError.invalidResponse
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

  private func runtimeError(forStructuredStatusCode statusCode: Int) -> PutioRuntimeError {
    switch statusCode {
    case 404:
      return .notFound
    case 429:
      return .rateLimited
    case 408, 500...599:
      return .transient
    default:
      return .unknown
    }
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

  private func trashSnapshot(_ file: PutioTrashFile) -> PutioTrashItem {
    PutioTrashItem(
      id: PutioFileID(rawValue: file.id),
      parentID: PutioFileID(rawValue: file.parentID),
      name: file.name,
      kind: kind(for: file.type),
      sizeBytes: file.size,
      deletedAt: file.deletedAt,
      expiresAt: file.expiresOn
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
