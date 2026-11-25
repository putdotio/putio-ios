import Foundation
import PutioCore
import SwiftUI

#if DEBUG
  /// The journey's loopback media server, named by the test runner.
  struct TVHarnessMedia {
    let baseURL: URL

    static var current: TVHarnessMedia? {
      HarnessMediaServer.baseURL().map(TVHarnessMedia.init(baseURL:))
    }

    /// Seeded positions exceed the 20-second subtitled fixture, so it starts
    /// at the beginning; the plain fixture keeps the seeded position.
    func substituting(
      _ resolution: PutioPlaybackResolution, account: PutioAccountSnapshot
    ) -> PutioPlaybackResolution {
      guard case .ready(let source) = resolution else { return resolution }
      if let original = source.original { return .ready(direct(source, original: original)) }
      guard !HarnessSeededAPI.refusesPlayback else {
        return .ready(
          PutioPlaybackSource(
            url: HarnessVideoFaults.url(for: .forbidden, mediaBaseURL: baseURL),
            startFromSeconds: source.startFromSeconds))
      }
      let subtitled = HarnessSubtitledStream.path(for: account)
      return .ready(
        PutioPlaybackSource(
          url: baseURL.appending(path: subtitled ?? "runtime-proof.m3u8"),
          startFromSeconds: subtitled == nil ? source.startFromSeconds : 0))
    }

    /// Direct play swaps the original for the MKV fixture and every put.io
    /// subtitle for the SRT fixture, as the iOS journey does.
    private func direct(
      _ source: PutioPlaybackSource, original: PutioOriginalPlayback
    ) -> PutioPlaybackSource {
      let subtitles = original.subtitles.map { subtitle in
        PutioCastSubtitle(
          key: subtitle.key, language: subtitle.language, languageCode: subtitle.languageCode,
          name: subtitle.name, source: subtitle.source,
          url: baseURL.appending(path: "runtime-proof-subtitles.srt"))
      }
      return PutioPlaybackSource(
        url: baseURL.appending(path: "runtime-proof-direct.mkv"),
        startFromSeconds: 0,
        original: original.subtitles(subtitles, defaultKey: original.defaultSubtitleKey))
    }
  }
#endif

/// What a harness journey reads off the screen. Only debug harness runs
/// render it.
@MainActor
@Observable
final class TVPlaybackProbes {
  var resumePosition: Int?
  var source: String?
  var isReady = false
  var currentPosition: Int?
  var audioLanguage: String?
  var subtitle: String?
  var speed: Float?
  var rate: Float?
  var ended = false
  var reportedPosition: String?
  var speeds: [String]?
  var failureReport: PutioPlaybackFailureReport?
  private(set) var conversionHistory = HarnessConversionHistory()

  func record(_ state: PutioVideoPlaybackState) {
    conversionHistory.record(state)
  }

  struct Probe: Identifiable {
    let id: String
    let label: String
    let value: String

    init(_ id: String, _ label: String, _ value: String) {
      self.id = id
      self.label = label
      self.value = value
    }
  }

  var values: [Probe] {
    var values: [Probe] = []
    if let resumePosition {
      values.append(Probe("video.resume-position", "Resume position", "\(resumePosition)"))
    }
    if isReady { values.append(Probe("video.ready", "Video ready", "")) }
    if let source { values.append(Probe("video.source", "Playback source", source)) }
    if let currentPosition {
      values.append(
        Probe("video.current-position", "Current playback position", "\(currentPosition)"))
    }
    if let audioLanguage {
      values.append(Probe("video.audio-language", "Selected audio language", audioLanguage))
    }
    if let subtitle { values.append(Probe("video.subtitle", "Selected subtitle", subtitle)) }
    if let speed { values.append(Probe("video.speed", "Selected speed", Self.format(speed))) }
    if let rate { values.append(Probe("video.rate", "Current rate", Self.format(rate))) }
    if ended { values.append(Probe("video.ended", "Playback reached end", "")) }
    if let speeds {
      values.append(Probe("video.speeds", "Offered speeds", speeds.joined(separator: ",")))
    }

    if let reportedPosition {
      values.append(Probe("video.position-reported", "Reported position", reportedPosition))
    }
    if let failureReport {
      let keys = [
        "platform", "player", "playback_outcome", "failure_mode", "source_request_status",
      ]
      values.append(
        Probe(
          "video.failure-report", "Playback failure report",
          keys.map { "\($0)=\(failureReport.tags[$0] ?? "")" }.joined(separator: ";")))
    }
    if let conversionHistory = conversionHistory.value {
      values.append(
        Probe("video.conversion-history", "Observed conversion states", conversionHistory))
    }
    return values
  }

  static func format(_ rate: Float) -> String {
    rate.formatted(.number.precision(.fractionLength(0...2)).locale(Locale(identifier: "en_US")))
  }
}

struct TVPlaybackProbeView: View {
  let probes: TVPlaybackProbes

  var body: some View {
    ZStack {
      ForEach(probes.values) { probe in
        Color.clear
          .frame(width: 1, height: 1)
          .accessibilityElement(children: .ignore)
          .accessibilityLabel(probe.label)
          .accessibilityValue(probe.value)
          .accessibilityIdentifier(probe.id)
          .allowsHitTesting(false)
      }
    }
    .allowsHitTesting(false)
  }
}
