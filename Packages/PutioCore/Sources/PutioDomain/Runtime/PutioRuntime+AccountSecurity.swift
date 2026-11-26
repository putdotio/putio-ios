import Foundation
import PutioSDK

extension PutioRuntime {
  /// Grants the account has issued, with this app's own grant flagged so it
  /// is never offered for revocation.
  public func listAuthorizedApps() async throws -> [PutioAuthorizedApp] {
    let (grants, clientID) = try await performAuthenticatedOperation {
      (try await sdk.getGrants(), sdk.config.clientID)
    }
    let clients =
      (try? await performAuthenticatedOperation { try await sdk.getClients() }) ?? []
    let sessions = Dictionary(grouping: clients, by: \.appID)
    var ids = Set<Int>()
    let apps = try grants.map { grant in
      guard grant.id > 0, ids.insert(grant.id).inserted else {
        throw PutioRuntimeError.invalidResponse
      }
      let appSessions = sessions[grant.id] ?? []
      let name =
        grant.name.isEmpty
        ? appSessions.lazy.compactMap(\.appName).first { !$0.isEmpty } ?? "" : grant.name
      return PutioAuthorizedApp(
        id: grant.id, name: name,
        lastUsedAt: appSessions.compactMap {
          $0.lastUsedAt.flatMap(PutioAccountSnapshot.timestamp)
        }.max(),
        hasIcon: grant.hasIcon == true,
        isCurrentClient: String(grant.id) == clientID)
    }
    return apps.sorted { lhs, rhs in
      if lhs.isCurrentClient != rhs.isCurrentClient { return lhs.isCurrentClient }
      if lhs.lastUsedAt != rhs.lastUsedAt {
        return (lhs.lastUsedAt ?? .distantPast) > (rhs.lastUsedAt ?? .distantPast)
      }
      return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
    }
  }

  public func authorizedAppIcon(id: Int) async throws -> Data {
    guard id > 0 else { throw PutioRuntimeError.invalidResponse }
    return try await performAuthenticatedOperation { try await sdk.getAppIcon(appID: id) }
  }

  public func revokeAuthorizedApp(id: Int) async throws {
    guard id > 0 else { throw PutioRuntimeError.invalidResponse }
    let response = try await performAuthenticatedOperation(commits: true) {
      try await sdk.revokeGrant(id: id)
    }
    guard response.status == "OK" else { throw PutioRuntimeError.invalidResponse }
  }

  /// Approves a device code shown by a TV or another put.io client.
  public func linkDevice(code: String) async throws -> PutioAuthorizedApp {
    let trimmed = code.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { throw PutioAccountSecurityError.invalidDeviceCode }
    let grant = try await performAuthenticatedOperation(commits: true) {
      do {
        return try await sdk.linkDevice(code: trimmed)
      } catch let error as PutioSDKError where Self.isCodeRejection(error) {
        throw PutioAccountSecurityError.invalidDeviceCode
      }
    }
    return PutioAuthorizedApp(
      id: grant.id, name: grant.name, hasIcon: grant.hasIcon == true, isCurrentClient: false)
  }

  /// Clears the selected categories server-side, then reloads the account so
  /// storage reflects the change. Returns whether that reload succeeded.
  public func clearAccountData(_ categories: Set<PutioAccountDataCategory>) async throws -> Bool {
    guard !categories.isEmpty else { throw PutioRuntimeError.invalidResponse }
    let generation = session.authenticationGeneration
    let response: PutioOKResponse
    do {
      response = try await performAuthenticatedOperation(commits: true) {
        try await sdk.clearAccountData(
          options: PutioAccountClearOptions(
            files: categories.contains(.files),
            finishedTransfers: categories.contains(.finishedTransfers),
            activeTransfers: categories.contains(.activeTransfers),
            rssFeeds: categories.contains(.rssFeeds),
            rssLogs: categories.contains(.rssLogs),
            history: categories.contains(.history),
            trash: categories.contains(.trash),
            friends: categories.contains(.friends)))
      }
    } catch {
      // A lost response may follow a committed clear; the snapshot is stale
      // either way until it reloads.
      if generation == session.authenticationGeneration, case .signedIn = session.state {
        await session.refreshAccountAfterStorageMutation()
      }
      throw error
    }
    guard response.status == "OK" else { throw PutioRuntimeError.invalidResponse }
    return await session.refreshAccountAfterStorageMutation()
  }

  // put.io reports a wrong or expired device code with these types.
  private static func isCodeRejection(_ error: PutioSDKError) -> Bool {
    ["invalid_code", "INVALID_VALUE", "code_not_found", "INVALID_CODE"].contains(
      error.apiErrorType ?? "")
  }
}
