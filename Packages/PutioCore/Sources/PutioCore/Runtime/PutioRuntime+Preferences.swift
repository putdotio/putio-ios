import Foundation
import PutioSDK

extension PutioRuntime {
  public func setDefaultFolderSort(_ sort: PutioFolderSort) async throws
    -> PutioAccountPreferencesMutationResult
  {
    try await savePreferences(.init(sortBy: sort.rawValue), defaultSort: sort)
  }

  public func setTrashEnabled(_ enabled: Bool) async throws
    -> PutioAccountPreferencesMutationResult
  {
    try await savePreferences(.init(trashEnabled: enabled), storageChanged: !enabled)
  }

  public func setHistoryEnabled(_ enabled: Bool) async throws
    -> PutioAccountPreferencesMutationResult
  {
    try await savePreferences(.init(historyEnabled: enabled))
  }

  public func listPlaybackRoutes() async throws -> [PutioPlaybackRoute] {
    let routes = try await performAuthenticatedOperation { try await sdk.getRoutes() }
    var names = Set<String>()
    return try routes.map { route in
      guard !route.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
        names.insert(route.name).inserted
      else { throw PutioRuntimeError.invalidResponse }
      return PutioPlaybackRoute(name: route.name, description: route.description)
    }
  }

  public func setPlaybackRoute(name: String) async throws -> PutioAccountPreferencesMutationResult {
    guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      throw PutioRuntimeError.invalidResponse
    }
    return try await savePreferences(.init(tunnelRouteName: name))
  }

  public func setSubtitlesVisible(_ visible: Bool) async throws
    -> PutioAccountPreferencesMutationResult
  {
    try await savePreferences(.init(hideSubtitles: !visible))
  }

  public func setSubtitleAutoSelectionDisabled(_ disabled: Bool) async throws
    -> PutioAccountPreferencesMutationResult
  {
    try await savePreferences(.init(dontAutoSelectSubtitles: disabled))
  }

  public func resetFolderSorts() async throws -> PutioAccountPreferencesMutationResult {
    guard case .signedIn = session.state else { throw currentSessionError }
    guard !session.isUpdatingAccountPreferences else { throw PutioRuntimeError.transient }
    let generation = session.authenticationGeneration
    session.beginAccountPreferencesUpdate()
    defer {
      session.invalidateFolderSorts(generation: generation)
      session.endAccountPreferencesUpdate(generation: generation)
    }
    let response = try await performAuthenticatedOperation(commits: true) {
      try await sdk.resetFileSpecificSortSettings()
    }
    guard response.status == "OK" else { throw PutioRuntimeError.invalidResponse }
    return await preferencesMutationResult(storageChanged: false)
  }

  private func savePreferences(
    _ patch: PutioAccountSettingsPatch, storageChanged: Bool = false,
    defaultSort: PutioFolderSort? = nil
  ) async throws -> PutioAccountPreferencesMutationResult {
    guard case .signedIn = session.state else { throw currentSessionError }
    guard !session.isUpdatingAccountPreferences else { throw PutioRuntimeError.transient }
    let generation = session.authenticationGeneration
    session.beginAccountPreferencesUpdate()
    defer { session.endAccountPreferencesUpdate(generation: generation) }
    do {
      let response = try await performAuthenticatedOperation(commits: true) {
        try await sdk.saveAccountSettings(.patch(patch))
      }
      guard response.status == "OK" else { throw PutioRuntimeError.invalidResponse }
    } catch {
      guard generation == session.authenticationGeneration, case .signedIn = session.state else {
        throw error
      }
      // A lost response does not establish whether the server committed the
      // write. Reconcile before offering another potentially destructive save.
      let refreshed = await session.refreshAccountAfterPreferencesMutation(
        storageChanged: storageChanged)
      if refreshed, case .signedIn(let account) = session.state,
        generation == session.authenticationGeneration,
        defaultSort.map({ account.defaultSort == $0 }) ?? true,
        patch.trashEnabled.map({ account.trashEnabled == $0 }) ?? true,
        patch.historyEnabled.map({ account.historyEnabled == $0 }) ?? true,
        patch.tunnelRouteName.map({ account.routeName == $0 }) ?? true,
        patch.hideSubtitles.map({ account.hideSubtitles == $0 }) ?? true,
        patch.dontAutoSelectSubtitles.map({ account.dontAutoSelectSubtitles == $0 }) ?? true
      {
        return PutioAccountPreferencesMutationResult(accountRefreshed: true)
      }
      throw error
    }
    // These values are acknowledged by the write, even if the following account
    // reload fails. In particular, stale Trash copy must not promise recovery.
    session.applyAcknowledgedPreferences(
      defaultSort: defaultSort, trashEnabled: patch.trashEnabled,
      historyEnabled: patch.historyEnabled, routeName: patch.tunnelRouteName,
      hideSubtitles: patch.hideSubtitles, dontAutoSelectSubtitles: patch.dontAutoSelectSubtitles)
    return await preferencesMutationResult(storageChanged: storageChanged)
  }

  private func preferencesMutationResult(storageChanged: Bool) async
    -> PutioAccountPreferencesMutationResult
  {
    PutioAccountPreferencesMutationResult(
      accountRefreshed: await session.refreshAccountAfterPreferencesMutation(
        storageChanged: storageChanged))
  }
}
