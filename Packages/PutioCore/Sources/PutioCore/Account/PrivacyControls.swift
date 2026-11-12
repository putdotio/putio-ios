import Foundation

/// The account-wide privacy controls every put.io app shares
/// (putdotio/support#95, putdotio/support#135). The copy is the
/// legal-approved set from putdotio/support#135, word for word.
public enum PutioPrivacyControls {
  public struct Control: Equatable, Sendable {
    public let title: String
    public let description: String
  }

  public static let title = String(localized: "Privacy controls", bundle: .module)

  public static let strictlyNecessary = Control(
    title: String(localized: "Strictly necessary", bundle: .module),
    description:
      String(
        localized:
          "Needed for sign-in, security, transfers, downloads, playback, billing, and saving your choices.",
        bundle: .module)
  )

  public static let diagnostics = Control(
    title: String(localized: "Diagnostics", bundle: .module),
    description:
      String(
        localized:
          "Crash reports, error details, and limited playback diagnostics, so we can fix problems.",
        bundle: .module)
  )

  public static let productAnalytics = Control(
    title: String(localized: "Product analytics", bundle: .module),
    description:
      String(
        localized:
          "Limited usage, device, billing, and playback data that shows which apps and features work.",
        bundle: .module)
  )

  /// Shown once under the group, not repeated in each row.
  public static let groupFooter =
    String(
      localized:
        "Diagnostics and product analytics never send filenames, media titles, URLs, search text, or tokens.",
      bundle: .module)

  public static let privacyPolicyURL = URL(string: "https://put.io/privacy-policy/")!
  public static let servicesWeUseURL = URL(string: "https://put.io/services-we-use/")!

  public static func summary(for account: PutioAccountSnapshot) -> String {
    let diagnostics =
      account.diagnosticsEnabled
      ? String(localized: "Diagnostics on", bundle: .module)
      : String(localized: "Diagnostics off", bundle: .module)
    let analytics =
      account.productAnalyticsEnabled
      ? String(localized: "Analytics on", bundle: .module)
      : String(localized: "Analytics off", bundle: .module)
    return String(localized: "\(diagnostics) · \(analytics)", bundle: .module)
  }
}
