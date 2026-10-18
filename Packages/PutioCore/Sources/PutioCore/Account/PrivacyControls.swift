import Foundation

/// The account-wide privacy controls every put.io app shares
/// (putdotio/support#95, putdotio/support#135). The copy is the
/// legal-approved set from putdotio/support#135, word for word.
public enum PutioPrivacyControls {
  public struct Control: Equatable, Sendable {
    public let title: String
    public let description: String
  }

  public static let title = "Privacy controls"

  public static let strictlyNecessary = Control(
    title: "Strictly necessary",
    description:
      "Needed for sign-in, security, transfers, downloads, playback, billing, and saving your choices."
  )

  public static let diagnostics = Control(
    title: "Diagnostics",
    description:
      "Crash reports, error details, and limited playback diagnostics, so we can fix problems."
  )

  public static let productAnalytics = Control(
    title: "Product analytics",
    description:
      "Limited usage, device, billing, and playback data that shows which apps and features work."
  )

  /// Shown once under the group, not repeated in each row.
  public static let groupFooter =
    "Diagnostics and product analytics never send filenames, media titles, URLs, search text, or tokens."

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
