import Foundation
import Observation

/// Runtime seam for the security and danger-zone screens so tests drive the
/// models with closures instead of a signed-in runtime.
public struct PutioAccountSecurityActions: Sendable {
  let listApps: @MainActor @Sendable () async throws -> [PutioAuthorizedApp]
  let revokeApp: @MainActor @Sendable (Int) async throws -> Void
  let appIcon: @MainActor @Sendable (Int) async throws -> Data
  let linkDevice: @MainActor @Sendable (String) async throws -> PutioAuthorizedApp
  let generateSecret: @MainActor @Sendable () async throws -> String
  let setTwoFactor:
    @MainActor @Sendable (Bool, String) async throws -> PutioAccountPreferencesMutationResult
  let recoveryCodes: @MainActor @Sendable () async throws -> [PutioTwoFactorRecoveryCode]
  let regenerateRecoveryCodes: @MainActor @Sendable () async throws -> [PutioTwoFactorRecoveryCode]
  let clearData: @MainActor @Sendable (Set<PutioAccountDataCategory>) async throws -> Bool
  let destroyAccount: @MainActor @Sendable (String) async throws -> Void
  public let refreshAccount: @MainActor @Sendable () async -> Bool
  public let account: @MainActor @Sendable () -> PutioAccountSnapshot?
  public let isStale: @MainActor @Sendable () -> Bool

  public init(runtime: PutioRuntime) {
    listApps = { try await runtime.listAuthorizedApps() }
    revokeApp = { try await runtime.revokeAuthorizedApp(id: $0) }
    appIcon = { try await runtime.authorizedAppIcon(id: $0) }
    linkDevice = { try await runtime.linkDevice(code: $0) }
    generateSecret = { try await runtime.generateTwoFactorSecret() }
    setTwoFactor = { try await runtime.setTwoFactorEnabled($0, code: $1) }
    recoveryCodes = { try await runtime.recoveryCodes() }
    regenerateRecoveryCodes = { try await runtime.regenerateRecoveryCodes() }
    clearData = { try await runtime.clearAccountData($0) }
    destroyAccount = { try await runtime.destroyAccount(password: $0) }
    refreshAccount = { await runtime.refreshAccount() }
    account = {
      if case .signedIn(let account) = runtime.session.state { return account }
      return nil
    }
    isStale = { runtime.session.isAccountPreferencesStale }
  }

  init(
    listApps: @escaping @MainActor @Sendable () async throws -> [PutioAuthorizedApp] = { [] },
    revokeApp: @escaping @MainActor @Sendable (Int) async throws -> Void = { _ in },
    appIcon: @escaping @MainActor @Sendable (Int) async throws -> Data = { _ in
      throw PutioRuntimeError.notFound
    },
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
    self.appIcon = appIcon
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

public enum PutioAccountSecurityPresentation {
  /// Copy for a failed request, or nil when the session itself ended and the
  /// root view already reacts.
  static func message(for error: Error) -> String? {
    if error is CancellationError { return nil }
    switch error as? PutioAccountSecurityError {
    case .invalidTwoFactorCode:
      return String(
        localized: "That code is not valid. Check your authenticator app and try again.",
        bundle: .module)
    case .invalidDeviceCode:
      return String(
        localized: "That device code was not found. Check the code on the device and try again.",
        bundle: .module)
    case .invalidPassword:
      return String(
        localized: "That password does not match our records. Check it and try again.",
        bundle: .module)
    case nil: break
    }
    switch error as? PutioRuntimeError {
    case .authenticationRequired, .sessionExpired: return nil
    case .transient:
      return String(localized: "Check your connection and try again.", bundle: .module)
    case .rateLimited:
      return String(
        localized: "put.io is receiving too many requests. Try again shortly.", bundle: .module)
    case .invalidResponse:
      return String(localized: "put.io returned an invalid response. Try again.", bundle: .module)
    case .notFound:
      return String(
        localized: "put.io could not find what this action needs. Try again.", bundle: .module)
    case .unknown, nil:
      return String(localized: "Something went wrong. Try again.", bundle: .module)
    }
  }

  public static let refreshWarning =
    String(
      localized: "Saved, but the latest account settings could not be loaded. Refresh to continue.",
      bundle: .module)
}

/// One two-factor change: enrollment (secret, code, recovery codes) or
/// disabling (code only). A submit that started settles even if the sheet
/// goes away, because the server may already have committed it.
@MainActor
@Observable
public final class PutioTwoFactorChangeModel {
  public enum Step: Equatable {
    case loadingSecret
    case secret(String)
    case code
    case recoveryCodes([PutioTwoFactorRecoveryCode])
    case finished(accountRefreshed: Bool)
  }

  public let enabling: Bool
  public private(set) var step: Step
  public var code = ""
  public private(set) var secretFailure: String?
  public private(set) var codeFailure: String?
  public private(set) var isSubmitting = false
  public private(set) var isLoadingRecoveryCodes = false
  public private(set) var recoveryCodesFailure: String?
  @ObservationIgnored private let actions: PutioAccountSecurityActions
  @ObservationIgnored private var secretGeneration = 0
  // Whether the account reload after the save succeeded; the codes step
  // must carry it through to the finish so a stale warning is not dropped.
  @ObservationIgnored private var accountRefreshed = true

  public init(enabling: Bool, actions: PutioAccountSecurityActions) {
    self.enabling = enabling
    self.actions = actions
    step = enabling ? .loadingSecret : .code
  }

  var secret: String? {
    if case .secret(let secret) = step { return secret }
    return nil
  }

  public var canSubmit: Bool {
    !isSubmitting && !isLoadingRecoveryCodes && recoveryCodesFailure == nil
      && !code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
  }

  public func loadSecret() async {
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

  public func continueToCode() {
    guard secret != nil else { return }
    step = .code
  }

  public func submit() async {
    guard canSubmit, case .code = step else { return }
    isSubmitting = true
    codeFailure = nil
    let enabling = enabling
    let code = code
    let task = Task { @MainActor in
      defer { isSubmitting = false }
      do {
        let result = try await actions.setTwoFactor(enabling, code)
        accountRefreshed = result.accountRefreshed
        if enabling {
          await loadRecoveryCodes()
        } else {
          step = .finished(accountRefreshed: accountRefreshed)
        }
      } catch is CancellationError {
        // The save may have committed; the runtime reconciles on the retry.
        codeFailure = String(
          localized: "The change could not be confirmed. Try again.", bundle: .module)
      } catch {
        guard let message = PutioAccountSecurityPresentation.message(for: error) else { return }
        codeFailure = message
        if error as? PutioAccountSecurityError == .invalidTwoFactorCode { self.code = "" }
      }
    }
    await task.value
  }

  public func retryRecoveryCodes() async {
    guard case .code = step, !isSubmitting, recoveryCodesFailure != nil else { return }
    await loadRecoveryCodes()
  }

  public func finish() {
    guard case .recoveryCodes = step else { return }
    step = .finished(accountRefreshed: accountRefreshed)
  }

  /// Two-factor is already on but the codes never loaded; the Security screen
  /// keeps offering them, so leaving here is explicit rather than blocked.
  public func finishWithoutRecoveryCodes() {
    guard case .code = step, recoveryCodesFailure != nil, !isLoadingRecoveryCodes else { return }
    step = .finished(accountRefreshed: accountRefreshed)
  }

  // The previous failure stays visible until this attempt settles, so the
  // sheet never re-offers Enable for an account that already has 2FA on.
  private func loadRecoveryCodes() async {
    isLoadingRecoveryCodes = true
    defer { isLoadingRecoveryCodes = false }
    do {
      step = .recoveryCodes(try await actions.recoveryCodes())
      recoveryCodesFailure = nil
    } catch is CancellationError {
      // Two-factor is on either way; only a live session may skip the codes.
      recoveryCodesFailure = String(
        localized: "Your recovery codes could not be loaded. Try again.", bundle: .module)
    } catch {
      recoveryCodesFailure = PutioAccountSecurityPresentation.message(for: error)
      if recoveryCodesFailure == nil { step = .finished(accountRefreshed: accountRefreshed) }
    }
  }
}

extension PutioTwoFactorChangeModel: Identifiable {}

@MainActor
@Observable
public final class PutioRecoveryCodesModel {
  public private(set) var codes: [PutioTwoFactorRecoveryCode]?
  private(set) var isLoading = false
  public private(set) var isRegenerating = false
  public private(set) var failure: String?
  public private(set) var canRetryRegenerate = false
  @ObservationIgnored private let actions: PutioAccountSecurityActions
  @ObservationIgnored private var generation = 0

  public init(actions: PutioAccountSecurityActions) {
    self.actions = actions
  }

  public var isBusy: Bool { isLoading || isRegenerating }

  public func load() async {
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
      failure =
        error is CancellationError
        ? String(localized: "Your recovery codes could not be loaded. Try again.", bundle: .module)
        : PutioAccountSecurityPresentation.message(for: error)
    }
  }

  public func retryLoad() async {
    guard codes == nil else { return }
    await load()
  }

  public func regenerate() async {
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
        let message: String
        if error is CancellationError {
          message = String(
            localized: "Regenerating could not be completed. Try again.", bundle: .module)
        } else if let presented = PutioAccountSecurityPresentation.message(for: error) {
          message = presented
        } else {
          return
        }
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
          if let reloadMessage = PutioAccountSecurityPresentation.message(for: error) {
            codes = nil
            failure = reloadMessage
          } else {
            // Nothing is known either way; keep what was shown and let the
            // user try again rather than leaving an endless spinner.
            codes = previous
            failure = message
            canRetryRegenerate = true
          }
        }
      }
    }
    await task.value
  }

  /// Unused codes only; a used code has no value to the user.
  public var copyableText: String {
    Self.unusedText(codes ?? [])
  }

  public nonisolated static func unusedText(_ codes: [PutioTwoFactorRecoveryCode]) -> String {
    codes.filter { !$0.isUsed }.map(\.code).joined(separator: "\n")
  }

  /// put.io's web export name, stamped with milliseconds since 1970.
  public nonisolated static func exportFilename(at date: Date) -> String {
    let milliseconds = Int64((date.timeIntervalSince1970 * 1000).rounded(.down))
    return "putio-two-factor-recovery-codes_\(milliseconds).txt"
  }
}

@MainActor
@Observable
public final class PutioAuthorizedAppsModel {
  public enum State: Equatable {
    case loading
    case loaded([PutioAuthorizedApp])
    case failed(String)
  }

  public private(set) var state: State = .loading
  /// A failed reload while rows are shown; the rows stay, but they are no
  /// longer known to be current.
  public private(set) var refreshFailure: String?
  public private(set) var revokingID: Int?
  public private(set) var revokeFailures: [Int: String] = [:]
  public private(set) var isSigningOutOthers = false
  @ObservationIgnored private let actions: PutioAccountSecurityActions
  @ObservationIgnored private var generation = 0
  @ObservationIgnored private var icons: [Int: Data?] = [:]
  @ObservationIgnored private var iconRequests: [Int: Task<Data?, Never>] = [:]

  public init(actions: PutioAccountSecurityActions) {
    self.actions = actions
  }

  var apps: [PutioAuthorizedApp] {
    if case .loaded(let apps) = state { return apps }
    return []
  }

  public var isBusy: Bool { revokingID != nil || isSigningOutOthers }

  public var canSignOutOthers: Bool { apps.contains { !$0.isCurrentClient } }

  public func load() async {
    generation += 1
    let generation = generation
    if apps.isEmpty { state = .loading }
    refreshFailure = nil
    do {
      let loaded = try await actions.listApps()
      guard generation == self.generation else { return }
      state = .loaded(loaded)
      let listed = Set(loaded.map(\.id))
      revokeFailures = revokeFailures.filter { listed.contains($0.key) }
    } catch {
      guard generation == self.generation, !Task.isCancelled,
        let message = PutioAccountSecurityPresentation.message(for: error)
      else { return }
      if apps.isEmpty { state = .failed(message) } else { refreshFailure = message }
    }
  }

  public func revoke(id: Int) async {
    guard !isBusy else { return }
    await runRevoke(id: id)
  }

  public func signOutOthers() async {
    guard !isBusy, canSignOutOthers else { return }
    isSigningOutOthers = true
    defer { isSigningOutOthers = false }
    for app in apps where !app.isCurrentClient {
      guard await runRevoke(id: app.id) else { return }
    }
  }

  public func icon(for app: PutioAuthorizedApp) async -> Data? {
    guard app.hasIcon else { return nil }
    if let icon = icons[app.id] { return icon }
    if let pending = iconRequests[app.id] { return await pending.value }
    let actions = actions
    let request = Task { @MainActor in try? await actions.appIcon(app.id) }
    iconRequests[app.id] = request
    let icon = await request.value
    icons[app.id] = icon
    return icon
  }

  @discardableResult
  private func runRevoke(id: Int) async -> Bool {
    guard revokingID == nil, let app = apps.first(where: { $0.id == id }), !app.isCurrentClient
    else { return true }
    revokingID = id
    revokeFailures[id] = nil
    let task = Task { @MainActor in
      defer { revokingID = nil }
      do {
        try await actions.revokeApp(id)
        generation += 1
        state = .loaded(apps.filter { $0.id != id })
        return true
      } catch {
        guard let message = PutioAccountSecurityPresentation.message(for: error) else {
          return false
        }
        revokeFailures[id] = message
        return true
      }
    }
    return await task.value
  }
}

@MainActor
@Observable
public final class PutioLinkDeviceModel {
  /// Activation codes are six characters, as put.io's web linking form requires.
  static let codeLength = 6
  static let codeLengthFailure = String(localized: "Must be exactly 6 characters.", bundle: .module)

  public var code: String
  public private(set) var isLinking = false
  public private(set) var failure: String?
  public private(set) var linkedApp: PutioAuthorizedApp?
  @ObservationIgnored private let actions: PutioAccountSecurityActions

  public init(actions: PutioAccountSecurityActions, code: String? = nil) {
    self.actions = actions
    self.code = code.map(Self.normalized) ?? ""
  }

  public nonisolated static func normalized(_ code: String) -> String {
    code.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
  }

  public var canLink: Bool {
    !isLinking && !Self.normalized(code).isEmpty
  }

  public func link() async {
    guard canLink else { return }
    let code = Self.normalized(code)
    guard code.count == Self.codeLength else {
      failure = Self.codeLengthFailure
      return
    }
    isLinking = true
    failure = nil
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

  public func acknowledgeLink() {
    linkedApp = nil
    code = ""
  }
}

@MainActor
@Observable
public final class PutioClearDataModel {
  public var selection: Set<PutioAccountDataCategory> = []
  public private(set) var isClearing = false
  public private(set) var failure: String?
  public private(set) var didClear = false
  public private(set) var refreshWarning: String?
  @ObservationIgnored private let actions: PutioAccountSecurityActions
  /// Tells the shell which categories may be gone so mounted Files and
  /// History screens reload instead of showing deleted rows. Runs after every
  /// attempt, since a lost response can follow a committed clear; only a
  /// confirmed clear may discard local copies.
  @ObservationIgnored private let onCleared:
    @MainActor (_ categories: Set<PutioAccountDataCategory>, _ committed: Bool) -> Void

  public init(
    actions: PutioAccountSecurityActions,
    onCleared: @escaping @MainActor (Set<PutioAccountDataCategory>, Bool) -> Void = { _, _ in }
  ) {
    self.actions = actions
    self.onCleared = onCleared
  }

  public var canClear: Bool { !isClearing && !selection.isEmpty }

  public func clear() async {
    guard canClear else { return }
    isClearing = true
    failure = nil
    didClear = false
    refreshWarning = nil
    let selection = selection
    let task = Task { @MainActor in
      defer { isClearing = false }
      var committed = false
      do {
        let refreshed = try await actions.clearData(selection)
        committed = true
        didClear = true
        self.selection = []
        refreshWarning = refreshed ? nil : PutioAccountSecurityPresentation.refreshWarning
      } catch {
        failure = PutioAccountSecurityPresentation.message(for: error)
      }
      onCleared(selection, committed)
    }
    await task.value
  }

  public func refreshAccount() async {
    guard refreshWarning != nil, !isClearing else { return }
    isClearing = true
    defer { isClearing = false }
    if await actions.refreshAccount() { refreshWarning = nil }
  }
}

@MainActor
@Observable
public final class PutioDestroyAccountModel {
  public var password = ""
  public private(set) var isDestroying = false
  public private(set) var failure: String?
  @ObservationIgnored private let actions: PutioAccountSecurityActions
  /// Runs once the account is gone, before the signed-in shell unmounts, so
  /// the shell can purge account-scoped local state such as offline media.
  @ObservationIgnored private let onDestroyed: @MainActor () -> Void

  public init(
    actions: PutioAccountSecurityActions, onDestroyed: @escaping @MainActor () -> Void = {}
  ) {
    self.actions = actions
    self.onDestroyed = onDestroyed
  }

  public var canDestroy: Bool {
    !isDestroying && !password.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
  }

  /// A blank password is reported rather than ignored, since the alert has
  /// already closed by the time this runs. The password is sent as typed and
  /// never outlives its one request.
  public func destroy() async {
    guard !isDestroying else { return }
    guard canDestroy else {
      password = ""
      failure = String(localized: "Enter your password to confirm.", bundle: .module)
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
