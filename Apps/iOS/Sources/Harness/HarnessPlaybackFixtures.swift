import Observation
import PutioCore
import SwiftUI

#if DEBUG
  enum HarnessPlaybackFixtureError: Error {
    case invalidResource
    case missingResource
  }

  @MainActor
  enum HarnessSubtitleSize {
    private static var reset = false

    static func resetOnLaunch(_ defaults: UserDefaults) {
      guard !reset, HarnessLaunch.arguments.contains(HarnessScenario.launchArgument) else {
        return
      }
      reset = true
      defaults.removeObject(forKey: PutioSubtitleSizeMemory.key)
    }
  }

  struct HarnessFileSelectionProbe: View {
    let route: PutioFileRoute

    var body: some View {
      Color.clear
        .frame(width: 1, height: 1)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Selected file route")
        .accessibilityValue(selectionValue)
        .accessibilityIdentifier("files.selection")
        .allowsHitTesting(false)
    }

    private var selectionValue: String {
      "id=\(route.id.rawValue);parent=\(route.item.parentID.rawValue);kind=\(kindName)"
    }

    private var kindName: String {
      switch route.item.kind {
      case .folder: "folder"
      case .video: "video"
      case .audio: "audio"
      case .image: "image"
      case .pdf: "pdf"
      case .text: "text"
      case .other: "other"
      }
    }
  }

  /// Re-renders on every handed-off URL so the recorded summary stays current.
  struct HarnessExternalPlaybackProbe: View {
    // periphery:ignore - a changed count is what makes SwiftUI re-render the probe
    let requestCount: Int

    var body: some View {
      Color.clear
        .frame(width: 1, height: 1)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("External playback requests")
        .accessibilityValue(HarnessExternalURLOpener.summary())
        .accessibilityIdentifier("vlc.requests")
        .allowsHitTesting(false)
    }
  }

  @MainActor
  @Observable
  final class HarnessPreviewRequests {
    enum Outcome: String {
      case loaded
      case shared
      case failed
      case cancelled
    }

    private(set) var entries: [String] = []

    func record(_ fileID: PutioFileID, _ outcome: Outcome) {
      entries.append("\(fileID.rawValue):\(outcome.rawValue)")
    }
  }

  struct HarnessPreviewRequestsProbe: View {
    let requests: HarnessPreviewRequests

    var body: some View {
      Color.clear
        .frame(width: 1, height: 1)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Preview requests")
        .accessibilityValue(requests.entries.joined(separator: ","))
        .accessibilityIdentifier("preview.requests")
        .allowsHitTesting(false)
    }
  }

  struct HarnessConversionReadsProbe: View {
    var body: some View {
      TimelineView(.periodic(from: .now, by: 0.25)) { _ in
        Color.clear
          .frame(width: 1, height: 1)
          .accessibilityElement(children: .ignore)
          .accessibilityLabel("Conversion status reads")
          .accessibilityValue("\(HarnessSeededAPI.episodeConversionReadCount())")
          .accessibilityIdentifier("video.conversion-reads")
          .allowsHitTesting(false)
      }
    }
  }

  struct HarnessSearchRequestsProbe: View {
    var body: some View {
      TimelineView(.periodic(from: .now, by: 0.25)) { _ in
        Color.clear
          .frame(width: 1, height: 1)
          .accessibilityElement(children: .ignore)
          .accessibilityLabel("Search requests")
          .accessibilityValue(HarnessSeededAPI.searchRequestSummary())
          .accessibilityIdentifier("search.requests")
          .allowsHitTesting(false)
      }
    }
  }

  struct HarnessPasteboardProbe: View {
    @State private var text = ""

    var body: some View {
      Color.clear
        .frame(width: 1, height: 1)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Pasteboard")
        .accessibilityValue(text)
        .accessibilityIdentifier("harness.pasteboard")
        .allowsHitTesting(false)
        .onReceive(NotificationCenter.default.publisher(for: UIPasteboard.changedNotification)) {
          _ in text = UIPasteboard.general.string ?? ""
        }
    }
  }

  struct HarnessPresentedVideoProbe: View {
    let route: PutioVideoRoute

    var body: some View {
      Color.clear
        .frame(width: 1, height: 1)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Presented video route")
        .accessibilityValue("id=\(route.id.rawValue)")
        .accessibilityIdentifier("video.presented-route")
        .allowsHitTesting(false)
    }
  }

  struct HarnessPlaybackPositionProbe: View {
    let fileID: PutioFileID
    let seconds: Int

    var body: some View {
      Color.clear
        .frame(width: 1, height: 1)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Playback position reported")
        .accessibilityValue("id=\(fileID.rawValue);seconds=\(seconds)")
        .accessibilityIdentifier("video.position-reported")
        .allowsHitTesting(false)
    }
  }

  struct HarnessAudioSavesProbe: View {
    let saves: [(fileID: PutioFileID, seconds: Int)]

    var body: some View {
      Color.clear
        .frame(width: 1, height: 1)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Audio positions saved")
        .accessibilityValue(
          saves.map { "\($0.fileID.rawValue)@\($0.seconds)" }.joined(separator: ",")
        )
        .accessibilityIdentifier("audio.position-saves")
        .allowsHitTesting(false)
    }
  }

  @MainActor
  enum HarnessDirectPlay {
    private static var forgotFallbacks = false

    static func forgetFallbacks(scenario: HarnessScenario, accountID: Int) {
      guard scenario == .filesBrowser, !forgotFallbacks else { return }
      forgotFallbacks = true
      PutioConvertedFallbacks.clear(accountID: accountID)
    }

    static func source(for source: PutioPlaybackSource, fileID: PutioFileID) throws
      -> PutioPlaybackSource
    {
      guard let original = source.original else {
        throw HarnessPlaybackFixtureError.missingResource
      }
      let baseURL = try mediaBaseURL()
      let subtitles = original.subtitles.map { subtitle in
        PutioCastSubtitle(
          key: subtitle.key, language: subtitle.language, languageCode: subtitle.languageCode,
          name: subtitle.name, source: subtitle.source,
          url: baseURL.appending(path: "runtime-proof-subtitles.srt"))
      }
      let fails = fileID.rawValue == HarnessSeededAPI.failingOriginalFileID
      return PutioPlaybackSource(
        url: baseURL.appending(
          path: fails ? "runtime-proof-undecodable.mkv" : "runtime-proof-direct.mkv"),
        startFromSeconds: source.startFromSeconds,
        original: original.subtitles(subtitles, defaultKey: original.defaultSubtitleKey))
    }

    static func isConverted(_ source: PutioPlaybackSource) -> Bool {
      source.url.path.hasSuffix("/mp4/stream")
    }

    static func converted(_ source: PutioPlaybackSource) throws -> PutioPlaybackSource {
      PutioPlaybackSource(
        url: try mediaBaseURL().appending(path: "runtime-proof.m3u8"),
        startFromSeconds: source.startFromSeconds)
    }

    private static func mediaBaseURL() throws -> URL {
      guard let baseURL = HarnessMediaServer.baseURL() else {
        throw HarnessPlaybackFixtureError.missingResource
      }
      return baseURL
    }
  }

#endif
