import Foundation

/// Whether crash and error reports may leave the device. It follows the
/// signed-in account's `diagnostics_enabled`; signed out, or with no account
/// answer yet, diagnostics are on. The last answer is kept so a cold launch
/// honors an opt-out before the session restores.
@MainActor
public final class PutioDiagnosticsConsent {
  static let defaultsKey = "io.put.diagnostics-enabled"

  public private(set) var isEnabled: Bool
  private let defaults: UserDefaults

  public init(defaults: UserDefaults = .standard) {
    self.defaults = defaults
    isEnabled = defaults.object(forKey: Self.defaultsKey) as? Bool ?? true
  }

  /// Applies the session's answer and returns whether `isEnabled` changed.
  /// Transitional states keep the current answer: restore has not resolved,
  /// or the account is still on the device while signing out.
  @discardableResult
  public func update(for state: PutioSessionState) -> Bool {
    let enabled: Bool
    switch state {
    case .unknown, .signingOut, .signOutFailed:
      return false
    case .signedOut, .authenticating:
      enabled = true
      defaults.removeObject(forKey: Self.defaultsKey)
    case .signedIn(let account):
      enabled = account.diagnosticsEnabled
      defaults.set(enabled, forKey: Self.defaultsKey)
    }
    guard enabled != isEnabled else { return false }
    isEnabled = enabled
    return true
  }
}
