import Foundation
import Observation
import PutioCore

/// Runtime seam for the security and danger-zone screens so tests drive the
/// models with closures instead of a signed-in runtime.
struct PutioAccountSecurityActions: Sendable {
  let listApps: @MainActor @Sendable () async throws -> [PutioAuthorizedApp]
  let revokeApp: @MainActor @Sendable (Int) async throws -> Void
  let linkDevice: @MainActor @Sendable (String) async throws -> PutioAuthorizedApp
  let generateSecret: @MainActor @Sendable () async throws -> String
  let setTwoFactor:
    @MainActor @Sendable (Bool, String) async throws -> PutioAccountPreferencesMutationResult
  let recoveryCodes: @MainActor @Sendable () async throws -> [PutioTwoFactorRecoveryCode]
  let regenerateRecoveryCodes: @MainActor @Sendable () async throws -> [PutioTwoFactorRecoveryCode]
  let clearData: @MainActor @Sendable (Set<PutioAccountDataCategory>) async throws -> Bool
  let destroyAccount: @MainActor @Sendable (String) async throws -> Void
  let refreshAccount: @MainActor @Sendable () async -> Bool
  let account: @MainActor @Sendable () -> PutioAccountSnapshot?
  let isStale: @MainActor @Sendable () -> Bool

  init(runtime: PutioRuntime) {
    listApps = { try await runtime.listAuthorizedApps() }
    revokeApp = { try await runtime.revokeAuthorizedApp(id: $0) }
    linkDevice = { try await runtime.linkDevice(code: $0) }
    generateSecret = { try await runtime.generateTwoFactorSecret() }
    setTwoFactor = { try await runtime.setTwoFactorEnabled($0, code: $1) }
    recoveryCodes = { try await runtime.recoveryCodes() }
    regenerateRecoveryCodes = { try await runtime.regenerateRecoveryCodes() }
    clearData = { try await runtime.clearAccountData($0) }
    destroyAccount = { try await runtime.destroyAccount(password: $0) }
    refreshAccount = { await runtime.refreshAccountPreferences() }
    account = {
      if case .signedIn(let account) = runtime.session.state { return account }
      return nil
    }
    isStale = { runtime.session.isAccountPreferencesStale }
  }

  init(
    listApps: @escaping @MainActor @Sendable () async throws -> [PutioAuthorizedApp] = { [] },
    revokeApp: @escaping @MainActor @Sendable (Int) async throws -> Void = { _ in },
    linkDevice: @escaping @MainActor @Sendable (String) async throws -> PutioAuthorizedApp = {
      _ in throw PutioAccountSecurityError.invalidDeviceCode
    },
    generateSecret: @escaping @MainActor @Sendable () async throws -> String = { "" },
    setTwoFactor:
      @escaping @MainActor @Sendable (Bool, String) async throws ->
      PutioAccountPreferencesMutationResult = { _, _ in .init(accountRefreshed: true) },
    recoveryCodes: @escaping @MainActor @Sendable () async throws -> [PutioTwoFactorRecoveryCode] =
      { [] },
    regenerateRecoveryCodes:
      @escaping @MainActor @Sendable () async throws -> [PutioTwoFactorRecoveryCode] = { [] },
    clearData: @escaping @MainActor @Sendable (Set<PutioAccountDataCategory>) async throws -> Bool =
      { _ in true },
    destroyAccount: @escaping @MainActor @Sendable (String) async throws -> Void = { _ in },
    refreshAccount: @escaping @MainActor @Sendable () async -> Bool = { true },
    account: @escaping @MainActor @Sendable () -> PutioAccountSnapshot? = { nil },
    isStale: @escaping @MainActor @Sendable () -> Bool = { false }
  ) {
    self.listApps = listApps
    self.revokeApp = revokeApp
    self.linkDevice = linkDevice
    self.generateSecret = generateSecret
    self.setTwoFactor = setTwoFactor
    self.recoveryCodes = recoveryCodes
    self.regenerateRecoveryCodes = regenerateRecoveryCodes
    self.clearData = clearData
    self.destroyAccount = destroyAccount
    self.refreshAccount = refreshAccount
    self.account = account
    self.isStale = isStale
  }
}

enum PutioAccountSecurityPresentation {
  /// Copy for a failed request, or nil when the session itself ended and the
  /// root view already reacts.
  static func message(for error: Error) -> String? {
    if error is CancellationError { return nil }
    switch error as? PutioAccountSecurityError {
    case .invalidTwoFactorCode:
      return "That code is not valid. Check your authenticator app and try again."
    case .invalidDeviceCode:
      return "That device code was not found. Check the code on the device and try again."
    case .invalidPassword:
      return "That password does not match our records. Check it and try again."
    case nil: break
    }
    switch error as? PutioRuntimeError {
    case .authenticationRequired, .sessionExpired: return nil
    case .transient: return "Check your connection and try again."
    case .rateLimited: return "put.io is receiving too many requests. Try again shortly."
    case .invalidResponse: return "put.io returned an invalid response. Try again."
    case .notFound: return "put.io could not find what this action needs. Try again."
    case .unknown, nil: return "Something went wrong. Try again."
    }
  }

  static let refreshWarning =
    "Saved, but the latest account settings could not be loaded. Refresh to continue."
}

/// One two-factor change: enrollment (secret, code, recovery codes) or
/// disabling (code only). A submit that started settles even if the sheet
/// goes away, because the server may already have committed it.
@MainActor
@Observable
final class PutioTwoFactorChangeModel {
  enum Step: Equatable {
    case loadingSecret
    case secret(String)
    case code
    case recoveryCodes([PutioTwoFactorRecoveryCode])
    case finished(accountRefreshed: Bool)
  }

  let enabling: Bool
  private(set) var step: Step
  var code = ""
  private(set) var secretFailure: String?
  private(set) var codeFailure: String?
  private(set) var isSubmitting = false
  private(set) var isLoadingRecoveryCodes = false
  private(set) var recoveryCodesFailure: String?
  @ObservationIgnored private let actions: PutioAccountSecurityActions
  @ObservationIgnored private var secretGeneration = 0

  init(enabling: Bool, actions: PutioAccountSecurityActions) {
    self.enabling = enabling
    self.actions = actions
    step = enabling ? .loadingSecret : .code
  }

  var secret: String? {
    if case .secret(let secret) = step { return secret }
    return nil
  }

  var canSubmit: Bool {
    !isSubmitting && !code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
  }

  func loadSecret() async {
    guard enabling, secret == nil else { return }
    secretGeneration += 1
    let generation = secretGeneration
    step = .loadingSecret
    secretFailure = nil
    do {
      let secret = try await actions.generateSecret()
      guard generation == secretGeneration else { return }
      step = .secret(secret)
    } catch {
      guard generation == secretGeneration, !Task.isCancelled else { return }
      secretFailure = PutioAccountSecurityPresentation.message(for: error)
    }
  }

  func continueToCode() {
    guard secret != nil else { return }
    step = .code
  }

  func submit() async {
    guard canSubmit, case .code = step else { return }
    isSubmitting = true
    codeFailure = nil
    let enabling = enabling
    let code = code
    let task = Task { @MainActor in
      defer { isSubmitting = false }
      do {
        let result = try await actions.setTwoFactor(enabling, code)
        if enabling {
          await loadRecoveryCodes(accountRefreshed: result.accountRefreshed)
        } else {
          step = .finished(accountRefreshed: result.accountRefreshed)
        }
      } catch {
        guard let message = PutioAccountSecurityPresentation.message(for: error) else { return }
        codeFailure = message
        if error as? PutioAccountSecurityError == .invalidTwoFactorCode { self.code = "" }
      }
    }
    await task.value
  }

  func retryRecoveryCodes() async {
    guard case .code = step, !isSubmitting, recoveryCodesFailure != nil else { return }
    await loadRecoveryCodes(accountRefreshed: true)
  }

  func finish() {
    guard case .recoveryCodes = step else { return }
    step = .finished(accountRefreshed: true)
  }

  private func loadRecoveryCodes(accountRefreshed: Bool) async {
    isLoadingRecoveryCodes = true
    recoveryCodesFailure = nil
    defer { isLoadingRecoveryCodes = false }
    do {
      step = .recoveryCodes(try await actions.recoveryCodes())
    } catch is CancellationError {
      // Two-factor is on either way; only a live session may skip the codes.
      recoveryCodesFailure = "Your recovery codes could not be loaded. Try again."
    } catch {
      recoveryCodesFailure = PutioAccountSecurityPresentation.message(for: error)
      if recoveryCodesFailure == nil { step = .finished(accountRefreshed: accountRefreshed) }
    }
  }
}

@MainActor
@Observable
final class PutioRecoveryCodesModel {
  private(set) var codes: [PutioTwoFactorRecoveryCode]?
  private(set) var isLoading = false
  private(set) var isRegenerating = false
  private(set) var failure: String?
  private(set) var canRetryRegenerate = false
  @ObservationIgnored private let actions: PutioAccountSecurityActions
  @ObservationIgnored private var generation = 0

  init(actions: PutioAccountSecurityActions) {
    self.actions = actions
  }

  var isBusy: Bool { isLoading || isRegenerating }

  func load() async {
    guard codes == nil, !isBusy else { return }
    generation += 1
    let generation = generation
    isLoading = true
    failure = nil
    defer { if generation == self.generation { isLoading = false } }
    do {
      let loaded = try await actions.recoveryCodes()
      guard generation == self.generation else { return }
      codes = loaded
    } catch {
      guard generation == self.generation, !Task.isCancelled else { return }
      failure = PutioAccountSecurityPresentation.message(for: error)
    }
  }

  func retryLoad() async {
    guard codes == nil else { return }
    await load()
  }

  func regenerate() async {
    guard !isBusy else { return }
    generation += 1
    let generation = generation
    isRegenerating = true
    failure = nil
    canRetryRegenerate = false
    let task = Task { @MainActor in
      defer { if generation == self.generation { isRegenerating = false } }
      do {
        let regenerated = try await actions.regenerateRecoveryCodes()
        guard generation == self.generation else { return }
        codes = regenerated
      } catch {
        guard generation == self.generation else { return }
        guard let message = PutioAccountSecurityPresentation.message(for: error) else { return }
        // The server may have rotated the codes before the response was lost.
        // The reloaded list is the truth: a changed list means the rotation
        // committed, so no retry may rotate it again.
        let previous = codes
        do {
          let current = try await actions.recoveryCodes()
          guard generation == self.generation else { return }
          codes = current
          if current == previous {
            failure = message
            canRetryRegenerate = true
          }
        } catch {
          guard generation == self.generation else { return }
          codes = nil
          failure = PutioAccountSecurityPresentation.message(for: error)
        }
      }
    }
    await task.value
  }

  /// Unused codes only; a used code has no value to the user.
  var copyableText: String {
    (codes ?? []).filter { !$0.isUsed }.map(\.code).joined(separator: "\n")
  }
}

@MainActor
@Observable
final class PutioAuthorizedAppsModel {
  enum State: Equatable {
    case loading
    case loaded([PutioAuthorizedApp])
    case failed(String)
  }

  private(set) var state: State = .loading
  private(set) var revokingID: Int?
  private(set) var failedRevokeID: Int?
  private(set) var revokeFailure: String?
  @ObservationIgnored private let actions: PutioAccountSecurityActions
  @ObservationIgnored private var generation = 0

  init(actions: PutioAccountSecurityActions) {
    self.actions = actions
  }

  var apps: [PutioAuthorizedApp] {
    if case .loaded(let apps) = state { return apps }
    return []
  }

  func load() async {
    generation += 1
    let generation = generation
    if apps.isEmpty { state = .loading }
    do {
      let loaded = try await actions.listApps()
      guard generation == self.generation else { return }
      state = .loaded(loaded)
      // A grant that is gone from the authoritative list has nothing to retry.
      if let failedRevokeID, !loaded.contains(where: { $0.id == failedRevokeID }) {
        self.failedRevokeID = nil
        revokeFailure = nil
      }
    } catch {
      guard generation == self.generation, !Task.isCancelled,
        let message = PutioAccountSecurityPresentation.message(for: error)
      else { return }
      if apps.isEmpty { state = .failed(message) }
    }
  }

  func revoke(id: Int) async {
    guard revokingID == nil, let app = apps.first(where: { $0.id == id }), !app.isCurrentClient
    else { return }
    revokingID = id
    revokeFailure = nil
    failedRevokeID = nil
    let task = Task { @MainActor in
      defer { revokingID = nil }
      do {
        try await actions.revokeApp(id)
        // A list request that started before the revoke must not bring the
        // grant back when it lands.
        generation += 1
        state = .loaded(apps.filter { $0.id != id })
      } catch {
        guard let message = PutioAccountSecurityPresentation.message(for: error) else { return }
        revokeFailure = message
        failedRevokeID = id
      }
    }
    await task.value
  }

  func retryRevoke() async {
    guard let failedRevokeID else { return }
    await revoke(id: failedRevokeID)
  }
}

@MainActor
@Observable
final class PutioLinkDeviceModel {
  var code = ""
  private(set) var isLinking = false
  private(set) var failure: String?
  private(set) var linkedApp: PutioAuthorizedApp?
  @ObservationIgnored private let actions: PutioAccountSecurityActions

  init(actions: PutioAccountSecurityActions) {
    self.actions = actions
  }

  var canLink: Bool {
    !isLinking && !code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
  }

  func link() async {
    guard canLink else { return }
    isLinking = true
    failure = nil
    let code = code
    let task = Task { @MainActor in
      defer { isLinking = false }
      do {
        linkedApp = try await actions.linkDevice(code)
      } catch {
        guard let message = PutioAccountSecurityPresentation.message(for: error) else { return }
        failure = message
        if error as? PutioAccountSecurityError == .invalidDeviceCode { self.code = "" }
      }
    }
    await task.value
  }

  func acknowledgeLink() {
    linkedApp = nil
    code = ""
  }
}

@MainActor
@Observable
final class PutioClearDataModel {
  var selection: Set<PutioAccountDataCategory> = []
  private(set) var isClearing = false
  private(set) var failure: String?
  private(set) var didClear = false
  private(set) var refreshWarning: String?
  @ObservationIgnored private let actions: PutioAccountSecurityActions
  /// Tells the shell which categories are gone so mounted Files and History
  /// screens reload instead of showing deleted rows.
  @ObservationIgnored private let onCleared: @MainActor (Set<PutioAccountDataCategory>) -> Void

  init(
    actions: PutioAccountSecurityActions,
    onCleared: @escaping @MainActor (Set<PutioAccountDataCategory>) -> Void = { _ in }
  ) {
    self.actions = actions
    self.onCleared = onCleared
  }

  var canClear: Bool { !isClearing && !selection.isEmpty }

  func clear() async {
    guard canClear else { return }
    isClearing = true
    failure = nil
    didClear = false
    refreshWarning = nil
    let selection = selection
    let task = Task { @MainActor in
      defer { isClearing = false }
      do {
        let refreshed = try await actions.clearData(selection)
        didClear = true
        self.selection = []
        refreshWarning = refreshed ? nil : PutioAccountSecurityPresentation.refreshWarning
        onCleared(selection)
      } catch {
        failure = PutioAccountSecurityPresentation.message(for: error)
      }
    }
    await task.value
  }

  func refreshAccount() async {
    guard refreshWarning != nil, !isClearing else { return }
    isClearing = true
    defer { isClearing = false }
    if await actions.refreshAccount() { refreshWarning = nil }
  }
}

@MainActor
@Observable
final class PutioDestroyAccountModel {
  var password = ""
  private(set) var isDestroying = false
  private(set) var failure: String?
  @ObservationIgnored private let actions: PutioAccountSecurityActions
  /// Runs once the account is gone, before the signed-in shell unmounts, so
  /// the shell can purge account-scoped local state such as offline media.
  @ObservationIgnored private let onDestroyed: @MainActor () -> Void

  init(actions: PutioAccountSecurityActions, onDestroyed: @escaping @MainActor () -> Void = {}) {
    self.actions = actions
    self.onDestroyed = onDestroyed
  }

  var canDestroy: Bool {
    !isDestroying && !password.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
  }

  /// A blank password is reported rather than ignored, since the alert has
  /// already closed by the time this runs. The password never outlives its
  /// one request.
  func destroy() async {
    guard !isDestroying else { return }
    guard canDestroy else {
      password = ""
      failure = "Enter your password to confirm."
      return
    }
    isDestroying = true
    failure = nil
    let password = password
    self.password = ""
    let task = Task { @MainActor in
      defer { isDestroying = false }
      do {
        try await actions.destroyAccount(password)
        onDestroyed()
      } catch {
        failure = PutioAccountSecurityPresentation.message(for: error)
      }
    }
    await task.value
  }
}
