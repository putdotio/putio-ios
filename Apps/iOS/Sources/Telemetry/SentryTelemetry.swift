import Foundation
import Sentry
import os

/// The app's only Sentry entry point. `scripts/test.sh` rejects `import Sentry`
/// anywhere else, so only the SDK fills the contexts and user that
/// `allowlisted` keeps. `PutioDiagnostics` decides when it runs.
enum SentryTelemetry {
  private static let capturing = OSAllocatedUnfairLock(initialState: false)

  /// Also read by the SDK's callbacks, so a report racing a switch-off is dropped.
  static var isCapturing: Bool {
    get { capturing.withLock { $0 } }
    set { capturing.withLock { $0 = newValue } }
  }

  static let cacheDirectory = URL.cachesDirectory.appending(path: "io.put.diagnostics")

  /// The SDK holds its session delegate weakly.
  private static let transportGate = SentryTransportGate()

  /// `SentrySDK.close()` uploads cached envelopes and a final session without
  /// `beforeSend`. The transport gate cancels those uploads and the cache is
  /// deleted, so nothing recorded before a switch-off leaves later either.
  static func setCapturing(_ enabled: Bool, configuration: SentryConfiguration) {
    isCapturing = enabled
    if enabled {
      guard !SentrySDK.isEnabled else { return }
      SentrySDK.start { options in
        options.dsn = configuration.dsn
        options.environment = configuration.environment
        options.enableAutoSessionTracking = true
        options.sessionTrackingIntervalMillis = 60000
        configure(options)
      }
    } else {
      if SentrySDK.isEnabled { SentrySDK.close() }
      try? FileManager.default.removeItem(at: cacheDirectory)
    }
  }

  static func configure(_ options: Options) {
    options.cacheDirectoryPath = cacheDirectory.path
    options.urlSessionDelegate = transportGate
    options.maxBreadcrumbs = 0
    options.beforeSend = { isCapturing ? allowlisted($0) : nil }
  }

  /// Copies listed fields into a new event, so anything else, including
  /// fields a Sentry upgrade adds, stays on the device.
  static func allowlisted(_ event: Event) -> Event {
    let sent = Event(level: event.level)
    sent.eventId = event.eventId
    sent.timestamp = event.timestamp
    sent.releaseName = event.releaseName
    sent.dist = event.dist
    sent.environment = event.environment
    sent.sdk = event.sdk
    sent.threads = event.threads
    sent.debugMeta = event.debugMeta
    sent.context = event.context?.filter { ["app", "device", "os", "runtime"].contains($0.key) }
    sent.user = event.user?.userId.map(Sentry.User.init(userId:))
    sent.exceptions = event.exceptions?.map { exception in
      let kept = Exception(value: nil, type: exception.type)
      kept.threadId = exception.threadId
      kept.stacktrace = exception.stacktrace
      kept.mechanism = exception.mechanism.map { mechanism in
        let kept = Mechanism(type: mechanism.type)
        kept.handled = mechanism.handled
        kept.synthetic = mechanism.synthetic
        kept.meta = mechanism.meta
        return kept
      }
      return kept
    }
    return sent
  }
}

final class SentryTransportGate: NSObject, URLSessionTaskDelegate, Sendable {
  func urlSession(_ session: URLSession, didCreateTask task: URLSessionTask) {
    if !SentryTelemetry.isCapturing { task.cancel() }
  }
}
