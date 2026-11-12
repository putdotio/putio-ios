import Foundation
import PutioSDK

extension PutioRuntime {
  public func listPublicLinks() async throws -> [PutioPublicLink] {
    let shares = try await performAuthenticatedOperation { try await sdk.listPublicShares() }
    var ids = Set<Int>()
    return try shares.map { share in
      guard share.id > 0, ids.insert(share.id).inserted,
        let url = PutioPublicLink.url(token: share.token.value)
      else { throw PutioRuntimeError.invalidResponse }
      return PutioPublicLink(
        id: share.id,
        fileName: share.userFile.name,
        kind: kind(for: share.userFile.fileType),
        expiresAt: share.expirationDate.flatMap(PutioPublicLink.expiryDate),
        url: url)
    }
  }

  public func revokePublicLink(id: Int) async throws {
    guard id > 0 else { throw PutioRuntimeError.invalidResponse }
    let response = try await performAuthenticatedOperation(commits: true) {
      try await sdk.deletePublicShare(id: id)
    }
    guard response.status == "OK" else { throw PutioRuntimeError.invalidResponse }
  }
}
