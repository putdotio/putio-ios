import Foundation
import Observation

/// Runtime seam for the security and danger-zone screens so tests drive the
/// models with closures instead of a signed-in runtime.
public struct PutioAccountSecurityActions: Sendable {
  let listApps: @MainActor @Sendable () async throws -> [PutioAuthorizedApp]
  let revokeApp: @MainActor @Sendable (Int) async throws -> Void
  let appIcon: @MainActor @Sendable (Int) async throws -> Data
  let linkDevice: @MainActor @Sendable (String) async throws -> PutioAuthorizedApp
  let clearData: @MainActor @Sendable (Set<PutioAccountDataCategory>) async throws -> Bool
  public let refreshAccount: @MainActor @Sendable () async -> Bool

  public init(runtime: PutioRuntime) {
    listApps = { try await runtime.listAuthorizedApps() }
    revokeApp = { try await runtime.revokeAuthorizedApp(id: $0) }
    appIcon = { try await runtime.authorizedAppIcon(id: $0) }
    linkDevice = { try await runtime.linkDevice(code: $0) }
    clearData = { try await runtime.clearAccountData($0) }
    refreshAccount = { await runtime.refreshAccount() }
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
    clearData: @escaping @MainActor @Sendable (Set<PutioAccountDataCategory>) async throws -> Bool =
      { _ in true },
    refreshAccount: @escaping @MainActor @Sendable () async -> Bool = { true }
  ) {
    self.listApps = listApps
    self.revokeApp = revokeApp
    self.appIcon = appIcon
    self.linkDevice = linkDevice
    self.clearData = clearData
    self.refreshAccount = refreshAccount
  }
}

public enum PutioAccountSecurityPresentation {
  /// Copy for a failed request, or nil when the session itself ended and the
  /// root view already reacts.
  static func message(for error: Error) -> String? {
    if error is CancellationError { return nil }
    switch error as? PutioAccountSecurityError {
    case .invalidDeviceCode:
      return String(
        localized: "That device code was not found. Check the code on the device and try again.",
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
  @ObservationIgnored private var linking: Task<Void, Never>?

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

  public func codeEdited() {
    failure = nil
    let uppercased = code.uppercased()
    if uppercased != code { code = uppercased }
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
      do {
        let app = try await actions.linkDevice(code)
        guard !Task.isCancelled else { return }
        linkedApp = app
      } catch {
        guard !Task.isCancelled else { return }
        failure = PutioAccountSecurityPresentation.message(for: error)
      }
      isLinking = false
    }
    linking = task
    await task.value
    if linking == task { linking = nil }
  }

  public func cancel() {
    linking?.cancel()
    linking = nil
    isLinking = false
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
