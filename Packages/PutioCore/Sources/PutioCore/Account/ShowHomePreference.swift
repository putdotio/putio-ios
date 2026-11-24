import Foundation
import Observation

/// Whether this device shows the Home tab for an account. Turned off, the
/// app hides Home and opens on Files. It is a device choice, so it lives in
/// this device's defaults and leaves with the account on sign-out.
@MainActor
@Observable
public final class PutioShowHomePreference {
  public private(set) var isShown: Bool
  @ObservationIgnored private let defaults: UserDefaults
  @ObservationIgnored private let key: String

  public init(defaults: UserDefaults = .standard, accountID: Int) {
    self.defaults = defaults
    key = Self.key(accountID: accountID)
    isShown = defaults.object(forKey: key) as? Bool ?? true
  }

  public func set(_ shown: Bool) {
    defaults.set(shown, forKey: key)
    isShown = shown
  }

  public static func clear(defaults: UserDefaults = .standard, accountID: Int) {
    defaults.removeObject(forKey: key(accountID: accountID))
  }

  public static var title: String { String(localized: "Show Home", bundle: .module) }

  public static var offDescription: String {
    String(localized: "Off: the Home tab hides and the app opens on Files.", bundle: .module)
  }

  private static func key(accountID: Int) -> String {
    "putio.home.shown.\(accountID)"
  }
}
