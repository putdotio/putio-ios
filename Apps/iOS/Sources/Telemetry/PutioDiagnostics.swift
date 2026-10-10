import PutioCore

/// Runs Sentry only while the account allows diagnostics (#139). The launch
/// starts it from the last known answer; every session change, including a
/// toggle in Account › Privacy, re-applies it in the running process.
@MainActor
enum PutioDiagnostics {
  private static let configuration = SentryConfiguration()
  private static let consent = PutioDiagnosticsConsent()

  static func start() {
    guard let configuration else { return }
    SentryTelemetry.setCapturing(consent.isEnabled, configuration: configuration)
  }

  static func sessionDidChange(_ state: PutioSessionState) {
    // The answer is kept even without a DSN, so a build that gains one starts
    // from the account's choice.
    guard consent.update(for: state), let configuration else { return }
    SentryTelemetry.setCapturing(consent.isEnabled, configuration: configuration)
  }
}
