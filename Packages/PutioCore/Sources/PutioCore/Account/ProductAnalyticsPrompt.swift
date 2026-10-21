import Foundation
import Observation

/// Asks a signed-in account once whether it allows product analytics. The
/// copy matches the App Store app's prompt word for word.
public enum PutioProductAnalyticsPrompt {
  public static let title = "Turn on product analytics?"
  public static let intro =
    "It helps us understand which apps and features work well. It stays off unless you allow it, and you can change it in Account → Privacy controls."
  public static let neverSentTitle = "What we never send"
  public static let neverSent = ["Filenames or media titles", "URLs or search text", "Tokens"]
  public static let sentTitle = "What we'd send"
  public static let sent = [
    "Features you use", "App and device type", "Playback and billing events",
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
    case .transient: return "Check your connection and try again."
    case .rateLimited: return "put.io is receiving too many requests. Try again shortly."
    case .invalidResponse: return "put.io returned an invalid response. Try again."
    case .notFound, .unknown, nil: return "Could not save your choice. Try again."
    }
  }
}
