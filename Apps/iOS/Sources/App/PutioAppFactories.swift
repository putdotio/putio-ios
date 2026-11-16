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
    let writesFail = ProcessInfo.processInfo.arguments.contains(
      "--putio-harness-offline-writes-fail")
    let seeded = harness ? seededQueue(accountID: accountID, writesFail: writesFail) : nil
    let seededFreeBytes = seeded?.freeBytes
    var directory: URL?
    if harness {
      let scratch = FileManager.default.temporaryDirectory.appending(path: "harness-offline")
      directory = seeded?.directory ?? scratch
      // `--putio-harness-offline-writes-fail` puts the store under a regular
      // file, so every queue write fails and the shell reports it.
      if writesFail, seeded == nil {
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
      resolve: seeded?.resolve ?? { fileID, kind in
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
      resolveOriginal: { fileID in
        let original = try await runtime.resolveOfflineOriginal(fileID: fileID)
        return PutioOfflineQueueFactory.swap(original, scenario: scenario)
      },
      startConversion: seeded?.startConversion ?? { fileID in
        try await runtime.startVideoConversion(fileID: fileID)
      },
      conversionStatus: seeded?.conversionStatus ?? { fileID in
        try await runtime.videoConversionStatus(fileID: fileID)
      },
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
      playbackURL: seeded?.playbackURL ?? PutioOfflineQueue.localURL(for:)
    )
  }

  private struct SeededQueue {
    let directory: URL
    let engine: any PutioOfflineDownloadEngine
    let freeBytes: Int64
    let playbackURL: @MainActor (String) -> URL
    let resolve: PutioOfflineResolve
    let startConversion: PutioOfflineConversionStart
    let conversionStatus: PutioOfflineConversionStatus
  }

  @MainActor
  private static func seededQueue(accountID: Int, writesFail: Bool) -> SeededQueue? {
    #if DEBUG
      guard let fixture = HarnessDownloadsFixture.parse(HarnessLaunch.arguments) else {
        return nil
      }
      let now = Date.now
      let directory = FileManager.default.temporaryDirectory.appending(
        path: "harness-offline-fixture")
      fixture.writeStore(at: directory, accountID: accountID, now: now, locked: writesFail)
      let conversions = fixture.conversionProgress(now: now)
      return SeededQueue(
        directory: directory,
        engine: HarnessFrozenOfflineEngine(transferring: fixture.transferringIDs(now: now)),
        freeBytes: fixture.freeBytes(isPad: UIDevice.current.userInterfaceIdiom == .pad),
        playbackURL: HarnessDownloadsFixture.playbackURL(mediaBaseURL: harnessMediaBaseURL),
        resolve: { fileID, _ in
          if conversions[fileID] != nil { return .conversionRequired }
          while !Task.isCancelled { try await Task.sleep(for: .seconds(3_600)) }
          throw CancellationError()
        },
        startConversion: { _ in },
        conversionStatus: { fileID in .converting(progress: conversions[fileID] ?? 0) })
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
      let path = kind == .audio ? "runtime-proof-audio.m4a" : "multi-audio/multi-subtitles.m3u8"
      return PutioPlaybackSource(
        url: baseURL.appending(path: path), startFromSeconds: source.startFromSeconds)
    #else
      return source
    #endif
  }
}

extension PutioOfflineQueueFactory {
  static func swap(_ original: PutioOfflineOriginal, scenario: HarnessScenario)
    -> PutioOfflineOriginal
  {
    #if DEBUG
      guard scenario == .filesBrowser,
        let baseURLString = ProcessInfo.processInfo.environment["PUTIO_HARNESS_MEDIA_BASE_URL"],
        let baseURL = URL(string: baseURLString), baseURL.scheme == "http",
        baseURL.host == "127.0.0.1"
      else { return original }
      return PutioOfflineOriginal(
        file: PutioFileDownloadSource(
          id: original.file.id, kind: original.file.kind, name: original.file.name,
          url: baseURL.appending(path: "runtime-proof-direct.mkv")),
        subtitles: original.subtitles.map {
          PutioCastSubtitle(
            key: $0.key, language: $0.language, languageCode: $0.languageCode, name: $0.name,
            source: $0.source,
            url: baseURL.appending(path: "multi-audio/multi-subtitle-\($0.language).vtt"))
        },
        startFromSeconds: original.startFromSeconds)
    #else
      return original
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

  #if DEBUG
    private static func harnessCastConnection(_ arguments: [String]) -> PutioCastConnection {
      if arguments.contains("--putio-harness-cast-no-device") { return .unavailable }
      if arguments.contains("--putio-harness-cast-local-network-denied") {
        return .localNetworkDenied
      }
      return .disconnected
    }
  #endif

  @MainActor
  static func makeModel(runtime: PutioRuntime, scenario: HarnessScenario) -> PutioCastModel {
    let controller: any PutioCastControlling
    #if DEBUG
      let harness = scenario == .filesBrowser
      if !usesGoogleCast(scenario: scenario) {
        let arguments = ProcessInfo.processInfo.arguments
        controller = PutioHarnessCastController(
          failLoadsBeforeSuccess: arguments.contains("--putio-harness-cast-load-fails-once")
            ? 1 : 0,
          holdsLoads: arguments.contains("--putio-harness-cast-load-held"),
          connection: harness ? harnessCastConnection(arguments) : .unavailable)
      } else {
        controller = PutioGoogleCastController()
      }
    #else
      let harness = false
      controller = PutioGoogleCastController()
    #endif
    #if DEBUG
      let subtitleMemory = HarnessSubtitleMemory.make()
    #else
      let subtitleMemory = PutioSubtitleMemory()
    #endif
    return PutioCastModel(
      controller: controller,
      conversionPollInterval: harness ? .milliseconds(1_200) : .seconds(3),
      resolve: { try await runtime.resolveCastMedia(fileID: $0) },
      startConversion: { try await runtime.startVideoConversion(fileID: $0) },
      loadConversionStatus: { try await runtime.videoConversionStatus(fileID: $0) },
      subtitleMemory: subtitleMemory
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
