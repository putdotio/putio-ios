import Foundation
import Observation

public struct PutioAppConfigActions: Sendable {
  let load: @MainActor @Sendable () async throws -> PutioAppConfig
  let save: @MainActor @Sendable (PutioAppConfigWrite) async throws -> Void

  public init(runtime: PutioRuntime) {
    load = { try await runtime.appConfig() }
    save = { write in
      switch write {
      case .autoplayNextVideo(let enabled): try await runtime.setAutoplayNextVideo(enabled)
      case .autoRotateVideo(let enabled): try await runtime.setAutoRotateVideo(enabled)
      }
    }
  }

  init(
    load: @escaping @MainActor @Sendable () async throws -> PutioAppConfig,
    save: @escaping @MainActor @Sendable (PutioAppConfigWrite) async throws -> Void
  ) {
    self.load = load
    self.save = save
  }
}

/// One app-owned setting written to the config document.
public enum PutioAppConfigWrite: Equatable, Sendable {
  case autoplayNextVideo(Bool)
  case autoRotateVideo(Bool)
}

/// The per-user config document behind app-owned playback settings. The
/// account snapshot owns `next_episode` (the suggestion); this document owns
/// `autoplay_next_video` and `auto_rotate_video`. A value flips locally only after the server
/// acknowledges the write, so a failed save keeps showing the authoritative
/// value with a retry.
@MainActor
@Observable
public final class PutioAppConfigModel {
  public private(set) var config: PutioAppConfig?
  public private(set) var isLoading = false
  public private(set) var isSaving = false
  public private(set) var failure: String?
  private(set) var failedWrite: PutioAppConfigWrite?
  @ObservationIgnored private let actions: PutioAppConfigActions
  @ObservationIgnored private var loadGeneration: UInt64 = 0
  @ObservationIgnored private var activeLoad: Task<Void, Never>?

  public init(actions: PutioAppConfigActions) {
    self.actions = actions
  }

  /// `false` until the document loads, matching the server default.
  public var autoplayNextVideo: Bool { config?.autoplayNextVideo ?? false }
  /// `true` until the document loads, matching the server default.
  public var autoRotateVideo: Bool { config?.autoRotateVideo ?? true }
  public var isBusy: Bool { isLoading || isSaving }
  public var canSave: Bool { config != nil && !isBusy }

  /// A load already in flight is awaited rather than duplicated, so every
  /// caller observes the same settled document.
  public func loadIfNeeded(force: Bool = false) async {
    if let activeLoad {
      await activeLoad.value
      return
    }
    guard force || config == nil, !isBusy else { return }
    loadGeneration &+= 1
    let generation = loadGeneration
    isLoading = true
    failure = nil
    failedWrite = nil
    let load = Task { @MainActor in
      defer {
        if generation == loadGeneration {
          isLoading = false
          activeLoad = nil
        }
      }
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
    activeLoad = load
    await load.value
  }

  /// The autoplay decision at end of video. A document still loading, or one
  /// whose load failed earlier, is awaited or retried first so a value that
  /// arrives late still counts; only an unreachable document reads as off.
  public func resolveAutoplayNextVideo() async -> Bool {
    if config == nil { await loadIfNeeded() }
    return autoplayNextVideo
  }

  public func setAutoplayNextVideo(_ enabled: Bool) async {
    guard enabled != autoplayNextVideo else { return }
    await save(.autoplayNextVideo(enabled))
  }

  public func setAutoRotateVideo(_ enabled: Bool) async {
    guard enabled != autoRotateVideo else { return }
    await save(.autoRotateVideo(enabled))
  }

  /// Repeats the failed write when one is pending; otherwise reloads the
  /// document, which is the only recovery after a failed read.
  public func retry() async {
    if let failedWrite {
      await save(failedWrite)
    } else {
      await loadIfNeeded(force: true)
    }
  }

  private func save(_ write: PutioAppConfigWrite) async {
    guard canSave else { return }
    isSaving = true
    failure = nil
    failedWrite = nil
    // A save must settle even when the settings screen disappears mid-flight.
    let task = Task { @MainActor in
      defer { isSaving = false }
      do {
        try await actions.save(write)
        switch write {
        case .autoplayNextVideo(let enabled): config?.autoplayNextVideo = enabled
        case .autoRotateVideo(let enabled): config?.autoRotateVideo = enabled
        }
      } catch {
        guard let message = Self.message(for: error, verb: "save") else { return }
        failure = message
        failedWrite = write
      }
    }
    await task.value
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
