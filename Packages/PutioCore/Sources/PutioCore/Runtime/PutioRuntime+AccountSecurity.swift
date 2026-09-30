import Foundation
import PutioSDK

extension PutioRuntime {
  /// Grants the account has issued, with this app's own grant flagged so it
  /// is never offered for revocation.
  public func listAuthorizedApps() async throws -> [PutioAuthorizedApp] {
    let (grants, clientID) = try await performAuthenticatedOperation {
      (try await sdk.getGrants(), sdk.config.clientID)
    }
    var ids = Set<Int>()
    return try grants.map { grant in
      guard grant.id > 0, ids.insert(grant.id).inserted else {
        throw PutioRuntimeError.invalidResponse
      }
      return PutioAuthorizedApp(
        id: grant.id, name: grant.name, description: grant.description,
        isCurrentClient: String(grant.id) == clientID)
    }
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
      id: grant.id, name: grant.name, description: grant.description, isCurrentClient: false)
  }

  /// Starts two-factor enrollment. The returned secret goes into an
  /// authenticator app; enrollment completes with `setTwoFactorEnabled`.
  public func generateTwoFactorSecret() async throws -> String {
    let result = try await performAuthenticatedOperation(commits: true) {
      try await sdk.generateTOTP()
    }
    let secret = result.secret.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !secret.isEmpty else { throw PutioRuntimeError.invalidResponse }
    return secret
  }

  /// Enables or disables two-factor authentication with a current code. The
  /// acknowledged value lands in the snapshot even if the account reload that
  /// follows fails; the result reports whether the reload succeeded.
  public func setTwoFactorEnabled(_ enabled: Bool, code: String) async throws
    -> PutioAccountPreferencesMutationResult
  {
    let trimmed = code.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { throw PutioAccountSecurityError.invalidTwoFactorCode }
    guard case .signedIn = session.state else { throw currentSessionError }
    guard !session.isUpdatingAccountPreferences else { throw PutioRuntimeError.transient }
    let generation = session.authenticationGeneration
    session.beginAccountPreferencesUpdate()
    defer { session.endAccountPreferencesUpdate(generation: generation) }
    do {
      let response = try await performAuthenticatedOperation(commits: true) {
        do {
          return try await sdk.saveAccountSettings(
            .twoFactor(PutioTwoFactorSettings(code: trimmed, enable: enabled)))
        } catch let error as PutioSDKError where Self.isCodeRejection(error) {
          throw PutioAccountSecurityError.invalidTwoFactorCode
        }
      }
      guard response.status == "OK" else { throw PutioRuntimeError.invalidResponse }
    } catch {
      guard generation == session.authenticationGeneration, case .signedIn = session.state else {
        throw error
      }
      // A lost response does not establish whether the write committed, and
      // a retry of a committed write can only fail as a stale code; the
      // account is the only truth before the user is asked for another code.
      let refreshed = await session.refreshAccountAfterPreferencesMutation(storageChanged: false)
      if refreshed, case .signedIn(let account) = session.state,
        generation == session.authenticationGeneration, account.twoFactorEnabled == enabled
      {
        return PutioAccountPreferencesMutationResult(accountRefreshed: true)
      }
      throw error
    }
    session.applyAcknowledgedPreferences(twoFactorEnabled: enabled)
    return PutioAccountPreferencesMutationResult(
      accountRefreshed: await session.refreshAccountAfterPreferencesMutation(
        storageChanged: false))
  }

  public func recoveryCodes() async throws -> [PutioTwoFactorRecoveryCode] {
    let codes = try await performAuthenticatedOperation { try await sdk.getRecoveryCodes() }
    return try Self.recoveryCodes(codes)
  }

  public func regenerateRecoveryCodes() async throws -> [PutioTwoFactorRecoveryCode] {
    let codes = try await performAuthenticatedOperation(commits: true) {
      try await sdk.regenerateRecoveryCodes()
    }
    return try Self.recoveryCodes(codes)
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

  /// Destroys the account after password confirmation and ends the local
  /// session without a revocation call, since the token dies with the account.
  /// Trimming only detects a blank field; the password itself is sent as
  /// typed, since put.io may accept surrounding whitespace as part of it.
  public func destroyAccount(password: String) async throws {
    guard !password.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      throw PutioAccountSecurityError.invalidPassword
    }
    let generation = session.authenticationGeneration
    let response: PutioOKResponse
    do {
      response = try await performAuthenticatedOperation(commits: true) {
        do {
          return try await sdk.destroyAccount(currentPassword: password)
        } catch let error as PutioSDKError
          where error.apiErrorType == "INVALID_CURRENT_PASSWORD"
        {
          throw PutioAccountSecurityError.invalidPassword
        }
      }
    } catch let error as PutioAccountSecurityError {
      throw error
    } catch {
      // A lost response may follow a committed destroy. A dead credential is
      // the only proof; anything else keeps the session for a retry.
      guard generation == session.authenticationGeneration, case .signedIn = session.state else {
        throw error
      }
      let credentialIsDead = await Self.credentialIsDead(sdk)
      guard generation == session.authenticationGeneration, case .signedIn = session.state else {
        throw error
      }
      if credentialIsDead {
        session.endDestroyedSession()
        return
      }
      throw error
    }
    guard response.status == "OK" else { throw PutioRuntimeError.invalidResponse }
    session.endDestroyedSession()
  }

  private static func credentialIsDead(_ sdk: PutioSDK) async -> Bool {
    do {
      _ = try await sdk.getAccountInfo()
      return false
    } catch {
      return (error as? PutioSDKError)?.isAuthenticationFailure == true
    }
  }

  private static func recoveryCodes(_ codes: PutioTwoFactorRecoveryCodes) throws
    -> [PutioTwoFactorRecoveryCode]
  {
    // A blank or repeated code would be shown as a backup that cannot
    // recover the account.
    var seen = Set<String>()
    let mapped = try codes.codes.map { code in
      let value = code.code.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !value.isEmpty, seen.insert(value).inserted else {
        throw PutioRuntimeError.invalidResponse
      }
      return PutioTwoFactorRecoveryCode(code: value, isUsed: !(code.usedAt ?? "").isEmpty)
    }
    guard !mapped.isEmpty else { throw PutioRuntimeError.invalidResponse }
    return mapped
  }

  // put.io reports a wrong or expired code with these types across the 2FA
  // and device-link endpoints.
  private static func isCodeRejection(_ error: PutioSDKError) -> Bool {
    ["invalid_code", "INVALID_VALUE", "code_not_found", "INVALID_CODE"].contains(
      error.apiErrorType ?? "")
  }
}
