import Foundation
import PutioSDK

extension PutioRuntime {
  public func listPublicLinks() async throws -> [PutioPublicLink] {
    let shares = try await performAuthenticatedOperation { try await sdk.listPublicShares() }
    var ids = Set<Int>()
    return shares.compactMap { share in
      guard share.id > 0, ids.insert(share.id).inserted,
        let url = PutioPublicLink.url(token: share.token.value)
      else { return nil }
      return PutioPublicLink(
        id: share.id,
        fileName: share.userFile.name,
        kind: kind(for: share.userFile.fileType),
        expiresAt: share.expirationDate.flatMap(PutioPublicLink.expiryDate),
        url: url)
    }
  }

  public func createPublicLink(fileID: PutioFileID) async throws -> URL {
    guard fileID.rawValue > 0 else { throw PutioRuntimeError.invalidResponse }
    let share = try await performAuthenticatedOperation {
      do {
        return try await sdk.createPublicShare(fileID: fileID.rawValue)
      } catch let error as PutioSDKError where error.publicShareRefusal != nil {
        if let refusal = PutioPublicLinkRefusal(apiErrorType: error.apiErrorType) {
          throw refusal
        }
        throw PutioRuntimeError.unknown
      }
    }
    guard share.id > 0, share.userFile.id == fileID.rawValue,
      let url = PutioPublicLink.url(token: share.token.value)
    else { throw PutioRuntimeError.invalidResponse }
    return url
  }

  public func revokePublicLink(id: Int) async throws {
    guard id > 0 else { throw PutioRuntimeError.invalidResponse }
    let response = try await performAuthenticatedOperation(commits: true) {
      try await sdk.deletePublicShare(id: id)
    }
    guard response.status == "OK" else { throw PutioRuntimeError.invalidResponse }
  }
}
