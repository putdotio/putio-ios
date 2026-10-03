import Foundation
import PutioCore
import SwiftUI

#if DEBUG
  /// The journey's loopback media server, named by the test runner.
  struct TVHarnessMedia {
    let baseURL: URL

    static var current: TVHarnessMedia? {
      guard
        let raw = ProcessInfo.processInfo.environment["PUTIO_HARNESS_MEDIA_BASE_URL"],
        let url = URL(string: raw), url.scheme == "http", url.host == "127.0.0.1"
      else { return nil }
      return TVHarnessMedia(baseURL: url)
    }

    /// Seeded positions exceed the 20-second subtitled fixture, so it starts
    /// at the beginning; the plain fixture keeps the seeded position.
    func substituting(
      _ resolution: PutioPlaybackResolution, account: PutioAccountSnapshot
    ) -> PutioPlaybackResolution {
      guard case .ready(let source) = resolution else { return resolution }
      let subtitled = HarnessSubtitledStream.path(for: account)
      return .ready(
        PutioPlaybackSource(
          url: baseURL.appending(path: subtitled ?? "runtime-proof.m3u8"),
          startFromSeconds: subtitled == nil ? source.startFromSeconds : 0))
    }
  }
#endif

/// What a harness journey reads off the screen. Only debug harness runs
/// render it.
@MainActor
@Observable
final class TVPlaybackProbes {
  var resumePosition: Int?
  var isReady = false
  var currentPosition: Int?
  var audioLanguage: String?
  var subtitle: String?
  var speed: Float?
  var rate: Float?
  var ended = false
  var reportedPosition: String?
  var speeds: [String]?
  private(set) var conversionHistory: [String] = []

  func record(_ state: PutioVideoPlaybackState) {
    let phase: String
    switch state {
    case .conversionQueued: phase = "queued"
    case .converting: phase = "converting"
    case .conversionCompleted: phase = "completed"
    case .loading, .ready, .conversionRequired, .failed: return
    }
    guard conversionHistory.last != phase else { return }
    conversionHistory.append(phase)
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
    if !conversionHistory.isEmpty {
      values.append(
        Probe(
          "video.conversion-history", "Observed conversion states",
          conversionHistory.joined(separator: ",")))
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
