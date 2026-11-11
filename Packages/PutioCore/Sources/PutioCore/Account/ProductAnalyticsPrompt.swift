import Foundation
import Observation

/// Asks a signed-in account once whether it allows product analytics. The
/// copy matches the App Store app's prompt word for word.
public enum PutioProductAnalyticsPrompt {
  public static let title = String(localized: "Turn on product analytics?", bundle: .module)
  public static let intro =
    String(
      localized:
        "It helps us understand which apps and features work well. It stays off unless you allow it, and you can change it in Account → Privacy controls.",
      bundle: .module)
  public static let neverSentTitle = String(localized: "What we never send", bundle: .module)
  public static let neverSent = [
    String(localized: "Filenames or media titles", bundle: .module),
    String(localized: "URLs or search text", bundle: .module),
    String(localized: "Tokens", bundle: .module),
  ]
  public static let sentTitle = String(localized: "What we'd send", bundle: .module)
  public static let sent = [
    String(localized: "Features you use", bundle: .module),
    String(localized: "App and device type", bundle: .module),
    String(localized: "Playback and billing events", bundle: .module),
  ]

  /// An unset setting reads as off, so an account is asked until it turns
  /// analytics on or this app stores an answer. A launch that opens a link
  /// skips the ask so the sheet never covers the link; the next launch asks.
  public static func shouldAsk(
    productAnalyticsEnabled: Bool, promptAnswered: Bool, opensLaunchLink: Bool
  ) -> Bool {
    !productAnalyticsEnabled && !promptAnswered && !opensLaunchLink
  }
}

public struct PutioProductAnalyticsPromptActions: Sendable {
  let saveSetting: @MainActor @Sendable (Bool) async throws -> Void
  let markAnswered: @MainActor @Sendable () async throws -> Void

  public init(runtime: PutioRuntime) {
    saveSetting = { _ = try await runtime.setProductAnalyticsEnabled($0) }
    markAnswered = { try await runtime.markProductAnalyticsPromptAnswered() }
  }

  public init(
    saveSetting: @escaping @MainActor @Sendable (Bool) async throws -> Void,
    markAnswered: @escaping @MainActor @Sendable () async throws -> Void
  ) {
    self.saveSetting = saveSetting
    self.markAnswered = markAnswered
  }
}

/// The setting goes first, as the web app writes them: a failed setting
/// records no answer, and a retry after a failed answer sends both again.
@MainActor
@Observable
public final class PutioProductAnalyticsPromptModel {
  public private(set) var isSaving = false
  public private(set) var savingChoice: Bool?
  public private(set) var failure: String?
  public private(set) var isAnswered = false
  @ObservationIgnored private let actions: PutioProductAnalyticsPromptActions

  public init(actions: PutioProductAnalyticsPromptActions) {
    self.actions = actions
  }

  public func answer(_ enabled: Bool) async {
    guard !isSaving, !isAnswered else { return }
    isSaving = true
    savingChoice = enabled
    failure = nil
    // Closing the sheet mid-save must not cancel a write already sent.
    let task = Task { @MainActor in
      defer {
        isSaving = false
        savingChoice = nil
      }
      do {
        try await actions.saveSetting(enabled)
        try await actions.markAnswered()
        isAnswered = true
      } catch {
        failure = Self.message(for: error)
      }
    }
    await task.value
  }

  private static func message(for error: Error) -> String? {
    guard !(error is CancellationError) else { return nil }
    switch error as? PutioRuntimeError {
    case .authenticationRequired, .sessionExpired: return nil
    case .transient:
      return String(localized: "Check your connection and try again.", bundle: .module)
    case .rateLimited:
      return String(
        localized: "put.io is receiving too many requests. Try again shortly.", bundle: .module)
    case .invalidResponse:
      return String(localized: "put.io returned an invalid response. Try again.", bundle: .module)
    case .notFound, .unknown, nil:
      return String(localized: "Could not save your choice. Try again.", bundle: .module)
    }
  }
}
