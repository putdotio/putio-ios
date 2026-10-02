import Foundation
import Observation

public enum PutioAccountPreferenceMutation: Equatable, Sendable {
  case defaultSort(PutioFolderSort)
  case resetFolderSorts
  case trash(Bool)
  case history(Bool)
  case route(String)
  case showSubtitles(Bool)
  case dontAutoSelectSubtitles(Bool)
}

public struct PutioAccountPreferenceActions: Sendable {
  let save:
    @MainActor @Sendable (PutioAccountPreferenceMutation) async throws ->
      PutioAccountPreferencesMutationResult
  let refresh: @MainActor @Sendable () async -> Bool
  let account: @MainActor @Sendable () -> PutioAccountSnapshot?
  let isStale: @MainActor @Sendable () -> Bool
  let isUpdating: @MainActor @Sendable () -> Bool

  public init(runtime: PutioRuntime) {
    save = { mutation in
      switch mutation {
      case .defaultSort(let sort): try await runtime.setDefaultFolderSort(sort)
      case .resetFolderSorts: try await runtime.resetFolderSorts()
      case .trash(let enabled): try await runtime.setTrashEnabled(enabled)
      case .history(let enabled): try await runtime.setHistoryEnabled(enabled)
      case .route(let name): try await runtime.setPlaybackRoute(name: name)
      case .showSubtitles(let show): try await runtime.setSubtitlesVisible(show)
      case .dontAutoSelectSubtitles(let disabled):
        try await runtime.setSubtitleAutoSelectionDisabled(disabled)
      }
    }
    refresh = { await runtime.refreshAccount() }
    account = {
      if case .signedIn(let account) = runtime.session.state { return account }
      return nil
    }
    isStale = { runtime.session.isAccountPreferencesStale }
    isUpdating = { runtime.session.isUpdatingAccountPreferences }
  }

  init(
    save:
      @escaping @MainActor @Sendable (PutioAccountPreferenceMutation) async throws ->
      PutioAccountPreferencesMutationResult,
    refresh: @escaping @MainActor @Sendable () async -> Bool,
    account: @escaping @MainActor @Sendable () -> PutioAccountSnapshot?,
    isStale: @escaping @MainActor @Sendable () -> Bool,
    isUpdating: @escaping @MainActor @Sendable () -> Bool
  ) {
    self.save = save
    self.refresh = refresh
    self.account = account
    self.isStale = isStale
    self.isUpdating = isUpdating
  }
}

@MainActor
@Observable
public final class PutioAccountPreferencesModel {
  private(set) var saving: PutioAccountPreferenceMutation?
  public private(set) var isRefreshing = false
  public private(set) var failure: String?
  public private(set) var failedMutation: PutioAccountPreferenceMutation?
  @ObservationIgnored private let actions: PutioAccountPreferenceActions
  public init(actions: PutioAccountPreferenceActions) {
    self.actions = actions
  }

  public var account: PutioAccountSnapshot? { actions.account() }
  public var isStale: Bool { actions.isStale() }
  public var isSaving: Bool { saving != nil || actions.isUpdating() }
  public var isBusy: Bool { isSaving || isRefreshing }
  public var canSave: Bool { !isBusy && !isStale && account != nil }

  public func save(_ mutation: PutioAccountPreferenceMutation) async {
    guard canSave else { return }
    saving = mutation
    failure = nil
    failedMutation = nil
    // The view can disappear while disabling History or signing out. Once
    // started, a mutation must settle even when its calling task is cancelled.
    let task = Task { @MainActor in
      defer { saving = nil }
      do {
        let result = try await actions.save(mutation)
        if !result.accountRefreshed {
          failure =
            "Saved, but the latest account settings could not be loaded. Refresh to continue."
        }
      } catch {
        guard let message = Self.message(for: error) else { return }
        if isStale {
          failure = "Could not confirm your change. Refresh account settings before continuing."
        } else {
          failure = message
          failedMutation = mutation
        }
      }
    }
    await task.value
  }

  public func retrySave() async {
    guard let failedMutation else { return }
    await save(failedMutation)
  }

  public func retryRefresh() async {
    guard !isBusy, account != nil else { return }
    isRefreshing = true
    failure = nil
    let task = Task { @MainActor in
      defer { isRefreshing = false }
      if !(await actions.refresh()), account != nil {
        failure = "Could not refresh account settings. Try again."
      }
    }
    await task.value
  }

  func clearFailure() {
    failure = nil
    failedMutation = nil
  }

  private static func message(for error: Error) -> String? {
    guard !(error is CancellationError) else { return nil }
    switch error as? PutioRuntimeError {
    case .authenticationRequired, .sessionExpired: return nil
    case .transient: return "Check your connection and try again."
    case .rateLimited: return "put.io is receiving too many requests. Try again shortly."
    case .invalidResponse: return "put.io returned an invalid response. Try again."
    case .notFound, .unknown, nil: return "Could not save account settings. Try again."
    }
  }
}

/// Account changes can arrive after the settings screen has been dismissed,
/// including through a storage refresh following an uncertain settings write.
public enum PutioAccountPreferencesReconciliation {
  @MainActor
  public static func apply(
    previous: PutioAccountSnapshot, current: PutioAccountSnapshot,
    folders: PutioFolderRefreshRequests, trash: PutioTrashReconciliation
  ) {
    guard previous.id == current.id else { return }
    if previous.defaultSort != current.defaultSort || previous.trashEnabled != current.trashEnabled
    {
      folders.requestAllLoadedFolders()
    }
    if previous.trashEnabled && !current.trashEnabled {
      trash.recordEmptied()
    }
  }
}
