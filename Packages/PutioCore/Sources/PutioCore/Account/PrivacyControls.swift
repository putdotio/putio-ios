import Foundation

/// The account-wide privacy controls every put.io app shares
/// (putdotio/support#95, putdotio/support#135). The descriptions are today's
/// contract copy, word for word, until legal approves new copy.
public enum PutioPrivacyControls {
  public struct Control: Equatable, Sendable {
    public let title: String
    public let description: String
  }

  public static let title = "Privacy controls"

  public static let strictlyNecessary = Control(
    title: "Strictly necessary",
    description:
      "Required for login, security, account access, transfers, downloads, playback, billing operations, and remembering your choices. These cannot be turned off."
  )

  public static let diagnostics = Control(
    title: "Diagnostics",
    description:
      "Send crash reports, error details, and limited playback diagnostics so we can find and fix problems. We do not send filenames, media titles, URLs, search text, or tokens."
  )

  public static let productAnalytics = Control(
    title: "Product analytics",
    description:
      "Help us understand which apps and features work well by sending limited usage, device, billing, and playback information. We never send filenames, media titles, URLs, search text, or tokens."
  )

  public static let privacyPolicyURL = URL(string: "https://put.io/privacy-policy/")!
  public static let servicesWeUseURL = URL(string: "https://put.io/services-we-use/")!

  /// The Account row's state line, such as "Diagnostics on · Product analytics off".
  public static func summary(for account: PutioAccountSnapshot) -> String {
    func state(_ control: Control, _ enabled: Bool) -> String {
      "\(control.title) \(enabled ? "on" : "off")"
    }
    return [
      state(diagnostics, account.diagnosticsEnabled),
      state(productAnalytics, account.productAnalyticsEnabled),
    ].joined(separator: " · ")
  }
}
