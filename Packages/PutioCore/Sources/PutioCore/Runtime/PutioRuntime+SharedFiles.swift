import Foundation
import PutioSDK

/// Why put.io refused to start a copy of a shared file.
public enum PutioSharedFileCopyRefusal: Error, Equatable, Sendable {
  case concurrentLimit
  case tooManyFiles
  /// put.io answered and declined, so the copy did not start.
  case rejected
}

public enum PutioSharedFileCopyProgress: Equatable, Sendable {
  case running
  case done
  case failed
}

extension PutioRuntime {
  /// Starts copying a file shared with this account into `parentID` and
  /// returns the copy's id for `sharedFileCopyProgress(copyID:)`.
  public func copySharedFile(fileID: PutioFileID, to parentID: PutioFileID) async throws -> Int {
    enum Start {
      case started(Int)
      case refused(PutioSharedFileCopyRefusal)
    }
    let start = try await performAuthenticatedOperation(commits: true) { () async throws -> Start in
      do {
        return .started(
          try await sdk.cloneSharedFiles(fileIDs: [fileID.rawValue], parentID: parentID.rawValue))
      } catch let error as PutioSDKError {
        guard let refusal = Self.copyRefusal(error) else { throw error }
        return .refused(refusal)
      }
    }
    switch start {
    case .started(let copyID): return copyID
    case .refused(let refusal): throw refusal
    }
  }

  public func sharedFileCopyProgress(copyID: Int) async throws -> PutioSharedFileCopyProgress {
    let info = try await performAuthenticatedOperation {
      try await sdk.getCloneInfo(cloneID: copyID)
    }
    switch info.status {
    case .done: return .done
    case .error: return .failed
    default: return .running
    }
  }

  static func copyRefusal(_ error: PutioSDKError) -> PutioSharedFileCopyRefusal? {
    switch error.sharedFileCloneLimit {
    case .concurrentCopies: return .concurrentLimit
    case .tooManyFiles, .tooManyChildren: return .tooManyFiles
    case nil: break
    }
    guard let statusCode = error.statusCode, (400..<500).contains(statusCode),
      !error.isAuthenticationFailure, !error.isRateLimited, !error.isNotFound
    else { return nil }
    return .rejected
  }
}
