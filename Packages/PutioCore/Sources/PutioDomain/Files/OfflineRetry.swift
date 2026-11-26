import Foundation

/// Retries an offline screen on its own: 3, 6, 12, 24, then every 30 seconds
/// while the screen stays offline.
public struct PutioOfflineRetry: Sendable {
  public typealias Sleep = @Sendable (Duration) async throws -> Void

  private let sleep: Sleep

  public init(sleep: @escaping Sleep = { try await Task.sleep(for: $0) }) {
    self.sleep = sleep
  }

  public static func delay(attempt: Int) -> Duration {
    .seconds(min(3 << min(max(attempt, 0), 4), 30))
  }

  /// Returns when `isOffline` turns false or the task is cancelled.
  @MainActor
  public func run(
    while isOffline: @autoclosure @MainActor () -> Bool, retry: @MainActor () async -> Void
  ) async {
    var attempt = 0
    while isOffline() {
      do {
        try await sleep(Self.delay(attempt: attempt))
      } catch {
        return
      }
      guard isOffline(), !Task.isCancelled else { return }
      await retry()
      attempt += 1
    }
  }
}
