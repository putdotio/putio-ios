import Foundation
import Observation
import PutioCore

struct PutioAppConfigActions: Sendable {
  let load: @MainActor @Sendable () async throws -> PutioAppConfig
  let saveAutoplayNextVideo: @MainActor @Sendable (Bool) async throws -> Void

  init(runtime: PutioRuntime) {
    load = { try await runtime.appConfig() }
    saveAutoplayNextVideo = { try await runtime.setAutoplayNextVideo($0) }
  }

  init(
    load: @escaping @MainActor @Sendable () async throws -> PutioAppConfig,
    saveAutoplayNextVideo: @escaping @MainActor @Sendable (Bool) async throws -> Void
  ) {
    self.load = load
    self.saveAutoplayNextVideo = saveAutoplayNextVideo
  }
}

/// The per-user config document behind app-owned playback settings. The
/// account snapshot owns `next_episode` (the suggestion); this document owns
/// `autoplay_next_video`. A value flips locally only after the server
/// acknowledges the write, so a failed save keeps showing the authoritative
/// value with a retry.
@MainActor
@Observable
final class PutioAppConfigModel {
  private(set) var config: PutioAppConfig?
  private(set) var isLoading = false
  private(set) var isSaving = false
  private(set) var failure: String?
  private(set) var failedAutoplayNextVideo: Bool?
  @ObservationIgnored private let actions: PutioAppConfigActions
  @ObservationIgnored private var loadGeneration: UInt64 = 0

  init(actions: PutioAppConfigActions) {
    self.actions = actions
  }

  /// `false` until the document loads, matching the server default.
  var autoplayNextVideo: Bool { config?.autoplayNextVideo ?? false }
  var isBusy: Bool { isLoading || isSaving }
  var canSave: Bool { config != nil && !isBusy }

  func loadIfNeeded(force: Bool = false) async {
    guard force || config == nil, !isBusy else { return }
    loadGeneration &+= 1
    let generation = loadGeneration
    isLoading = true
    failure = nil
    failedAutoplayNextVideo = nil
    defer { if generation == loadGeneration { isLoading = false } }
    do {
      let loaded = try await actions.load()
      guard generation == loadGeneration else { return }
      config = loaded
    } catch {
      guard generation == loadGeneration, let message = Self.message(for: error, verb: "load")
      else { return }
      failure = message
    }
  }

  func setAutoplayNextVideo(_ enabled: Bool) async {
    guard canSave, enabled != autoplayNextVideo else { return }
    isSaving = true
    failure = nil
    failedAutoplayNextVideo = nil
    // A save must settle even when the settings screen disappears mid-flight.
    let task = Task { @MainActor in
      defer { isSaving = false }
      do {
        try await actions.saveAutoplayNextVideo(enabled)
        config?.autoplayNextVideo = enabled
      } catch {
        guard let message = Self.message(for: error, verb: "save") else { return }
        failure = message
        failedAutoplayNextVideo = enabled
      }
    }
    await task.value
  }

  /// Repeats the failed write when one is pending; otherwise reloads the
  /// document, which is the only recovery after a failed read.
  func retry() async {
    if let failedAutoplayNextVideo {
      await setAutoplayNextVideo(failedAutoplayNextVideo)
    } else {
      await loadIfNeeded(force: true)
    }
  }

  private static func message(for error: Error, verb: String) -> String? {
    guard !(error is CancellationError) else { return nil }
    switch error as? PutioRuntimeError {
    case .authenticationRequired, .sessionExpired: return nil
    case .transient: return "Check your connection and try again."
    case .rateLimited: return "put.io is receiving too many requests. Try again shortly."
    case .invalidResponse: return "put.io returned an invalid response. Try again."
    case .notFound, .unknown, nil: return "Could not \(verb) playback settings. Try again."
    }
  }
}
