import PutioCore
import SwiftUI
import UIKit

enum PutioOfflineQueueFactory {
  @MainActor
  static func make(
    runtime: PutioRuntime, accountID: Int, scenario: HarnessScenario,
    onOriginalsRequested: @escaping @MainActor () -> Void
  ) -> PutioOfflineQueue {
    #if DEBUG
      let harness = scenario == .filesBrowser
    #else
      let harness = false
    #endif
    let seeded = harness ? seededQueue() : nil
    let seededFreeBytes = seeded?.freeBytes
    var directory: URL?
    if harness {
      directory = FileManager.default.temporaryDirectory.appending(
        path: seeded == nil ? "harness-offline" : "harness-offline-fixture")
      // `--putio-harness-offline-writes-fail` puts the store under a regular
      // file, so every queue write fails and the shell reports it.
      if ProcessInfo.processInfo.arguments.contains("--putio-harness-offline-writes-fail") {
        let blocker = FileManager.default.temporaryDirectory.appending(
          path: "harness-offline-blocked")
        FileManager.default.createFile(atPath: blocker.path, contents: Data())
        directory = blocker.appending(path: "store")
      }
    }
    // A queue outlived by its shell must not write to the next shell's document.
    let sessionGeneration = runtime.session.authenticationGeneration
    return PutioOfflineQueue(
      store: PutioOfflineStore(directory: directory, accountID: accountID),
      engine: seeded?.engine ?? PutioSystemOfflineDownloadEngine(accountID: accountID),
      conversionPollInterval: harness ? .milliseconds(1_200) : .seconds(3),
      availableStorage: { seededFreeBytes ?? PutioOfflineQueue.deviceAvailableBytes() },
      notifyCompletion: { item in
        guard !harness else { return }
        PutioOfflineNotifications.notifyCompletion(item)
      },
      notifyOriginalsRequested: { _ in onOriginalsRequested() },
      resolve: { fileID, kind in
        switch kind {
        case .audio:
          let source = try await runtime.resolveAudioPlaybackSource(fileID: fileID)
          return .ready(PutioOfflineQueueFactory.swap(source, scenario: scenario, kind: kind))
        case .video:
          let resolution = try await runtime.resolveVideoPlaybackSource(fileID: fileID)
          guard case .ready(let source) = resolution else { return resolution }
          return .ready(PutioOfflineQueueFactory.swap(source, scenario: scenario, kind: kind))
        }
      },
      startConversion: { fileID in try await runtime.startVideoConversion(fileID: fileID) },
      conversionStatus: { fileID in try await runtime.videoConversionStatus(fileID: fileID) },
      reportPosition: { fileID, seconds in
        try await runtime.reportPlaybackPosition(fileID: fileID, seconds: seconds)
      },
      deleteOriginal: { fileID in
        // Never run under another account; the original stays owed to this one.
        guard case .signedIn(let current) = runtime.session.state, current.id == accountID
        else { throw PutioRuntimeError.transient }
        try await runtime.deleteFile(fileID: fileID)
      },
      trashSetting: {
        // The cached snapshot can lag another client; ask the server first.
        guard await runtime.refreshAccount(),
          case .signedIn(let current) = runtime.session.state,
          !runtime.session.isAccountPreferencesStale,
          !runtime.session.isUpdatingAccountPreferences
        else { return nil }
        return current.trashEnabled
      },
      isLive: { runtime.session.authenticationGeneration == sessionGeneration },
      seed: seeded?.seed
    )
  }

  private struct SeededQueue {
    let seed: PutioOfflineQueueSeed
    let engine: any PutioOfflineDownloadEngine
    let freeBytes: Int64
  }

  @MainActor
  private static func seededQueue() -> SeededQueue? {
    #if DEBUG
      guard let fixture = HarnessDownloadsFixture.parse(HarnessLaunch.arguments) else {
        return nil
      }
      return SeededQueue(
        seed: fixture.seed(now: .now, mediaBaseURL: harnessMediaBaseURL),
        engine: HarnessFrozenOfflineEngine(),
        freeBytes: fixture.freeBytes(isPad: UIDevice.current.userInterfaceIdiom == .pad))
    #else
      return nil
    #endif
  }

  private static var harnessMediaBaseURL: URL? {
    #if DEBUG
      guard
        let baseURLString = ProcessInfo.processInfo.environment["PUTIO_HARNESS_MEDIA_BASE_URL"],
        let baseURL = URL(string: baseURLString), baseURL.scheme == "http",
        baseURL.host == "127.0.0.1"
      else { return nil }
      return baseURL
    #else
      return nil
    #endif
  }

  /// The seeded scenario pins preferred languages so the journey is
  /// independent of the simulator's locale.
  static func preferredLanguages(scenario: HarnessScenario) -> [String] {
    #if DEBUG
      let arguments = ProcessInfo.processInfo.arguments
      if scenario == .filesBrowser,
        let index = arguments.firstIndex(of: "--putio-harness-preferred-languages"),
        arguments.indices.contains(index + 1)
      {
        return arguments[index + 1].split(separator: ",").map(String.init)
      }
    #endif
    return Locale.preferredLanguages
  }

  /// The seeded scenario downloads local fixtures instead of api.put.io streams.
  static func swap(
    _ source: PutioPlaybackSource, scenario: HarnessScenario, kind: PutioOfflineItem.Kind
  )
    -> PutioPlaybackSource
  {
    #if DEBUG
      guard scenario == .filesBrowser, let baseURL = harnessMediaBaseURL else { return source }
      let path = kind == .audio ? "runtime-proof-audio.m4a" : "multi-audio/runtime-proof-multi.m3u8"
      return PutioPlaybackSource(
        url: baseURL.appending(path: path), startFromSeconds: source.startFromSeconds)
    #else
      return source
    #endif
  }
}

enum PutioExternalPlaybackOpener {
  static func make(scenario: HarnessScenario) -> PutioExternalURLOpening {
    #if DEBUG
      if scenario == .filesBrowser {
        let arguments = ProcessInfo.processInfo.arguments
        return HarnessExternalURLOpener(
          vlcInstalled: arguments.contains("--putio-harness-vlc-installed"),
          removesVLCAfterFirstCheck: arguments.contains("--putio-harness-vlc-removed"),
          refusesFirstHandoff: arguments.contains("--putio-harness-vlc-refuses-once"))
      }
    #endif
    return PutioSystemURLOpener()
  }
}

enum PutioCastControllerFactory {
  static func usesGoogleCast(scenario: HarnessScenario) -> Bool {
    #if DEBUG
      scenario != .filesBrowser && scenario != .gallery && scenario != .exercised
    #else
      true
    #endif
  }

  @MainActor
  static func makeModel(runtime: PutioRuntime, scenario: HarnessScenario) -> PutioCastModel {
    let controller: any PutioCastControlling
    #if DEBUG
      let harness = scenario == .filesBrowser
      if !usesGoogleCast(scenario: scenario) {
        controller = PutioHarnessCastController(
          failLoadsBeforeSuccess: ProcessInfo.processInfo.arguments.contains(
            "--putio-harness-cast-load-fails-once") ? 1 : 0,
          hasReceiver: harness)
      } else {
        controller = PutioGoogleCastController()
      }
    #else
      let harness = false
      controller = PutioGoogleCastController()
    #endif
    return PutioCastModel(
      controller: controller,
      positionReportInterval: harness ? .seconds(3) : .seconds(15),
      conversionPollInterval: harness ? .milliseconds(1_200) : .seconds(3),
      resolve: { fileID, playbackType in
        try await runtime.resolveCastMedia(fileID: fileID, playbackType: playbackType)
      },
      loadPlaybackType: { try await runtime.castPlaybackType() },
      savePlaybackType: { try await runtime.setCastPlaybackType($0) },
      startConversion: { try await runtime.startVideoConversion(fileID: $0) },
      loadConversionStatus: { try await runtime.videoConversionStatus(fileID: $0) },
      remembersPlaybackPosition: { runtime.remembersPlaybackPosition },
      reportPosition: { fileID, seconds in
        try await runtime.reportPlaybackPosition(fileID: fileID, seconds: seconds)
      }
    )
  }
}

extension PutioRuntime {
  /// The signed-in account's remember-position setting as of now.
  var remembersPlaybackPosition: Bool {
    guard case .signedIn(let account) = session.state else { return false }
    return account.rememberVideoTime
  }
}
