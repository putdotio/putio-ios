import Foundation

/// Where and as what the app reports, read from build settings through
/// Info.plist. Nil is the kill switch: `PUTIO_SENTRY_ENABLED` other than `YES`,
/// or an empty or malformed `PUTIO_SENTRY_DSN`, which the checked-in default is.
struct SentryConfiguration: Equatable {
  /// put.io's tunnel to Sentry ingest (putio-web `infra/telemetry.ts`). Some
  /// networks reset connections to Sentry's own ingest host, and the tunnel
  /// forwards only allowlisted project ids.
  static let relayHost = "relay.put.io"

  let dsn: String
  let environment: String
  let releaseName: String

  init?(bundle: Bundle = .main) {
    self.init(info: bundle.infoDictionary ?? [:])
  }

  init?(info: [String: Any]) {
    func value(_ key: String) -> String {
      (info[key] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }
    guard value("PUTIO_SENTRY_ENABLED") == "YES",
      let dsn = Self.relayDSN(value("PUTIO_SENTRY_DSN")),
      let bundleID = info["CFBundleIdentifier"] as? String,
      let version = info["CFBundleShortVersionString"] as? String,
      let build = info["CFBundleVersion"] as? String
    else { return nil }
    let environment = value("PUTIO_SENTRY_ENVIRONMENT")
    self.dsn = dsn
    self.environment = environment.isEmpty ? "production" : environment
    // Sentry's own release format, spelled out so the app identity is explicit.
    releaseName = "\(bundleID)@\(version)+\(build)"
  }

  /// Rewrites `https://<key>@<host>/<projectId>` to post through the relay.
  /// Anything else, including an unexpanded `$(PUTIO_SENTRY_DSN)`, is nil.
  static func relayDSN(_ dsn: String) -> String? {
    guard let components = URLComponents(string: dsn),
      components.scheme == "https" || components.scheme == "http",
      let key = components.user, !key.isEmpty,
      components.host?.isEmpty == false,
      let projectID = components.path.split(separator: "/").last,
      projectID.allSatisfy(\.isASCIIDigit)
    else { return nil }
    return "https://\(key)@\(relayHost)/\(projectID)"
  }
}

extension Character {
  fileprivate var isASCIIDigit: Bool { isASCII && isNumber }
}
