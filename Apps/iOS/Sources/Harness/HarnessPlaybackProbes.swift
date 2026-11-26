#if DEBUG
  import PutioCore
  import SwiftUI

  struct HarnessVideoProbeValues {
    var source: PutioPlaybackSource?
    var playerIsReady = false
    var selectedAudioLanguage: String?
    var shownSubtitleText: String?
    var shownCaption: String?
    var selectedSubtitle: String?
    var playbackPosition: Int?
    var playbackReachedEnd = false
    var conversionHistory: String?
    var fallbacks = 0
    var reportedFaults: [PutioVideoPlayerFault] = []
    var nextVideoLookup: String?

    var probes: [HarnessProbe] {
      var probes: [HarnessProbe] = []
      if let source {
        probes.append(
          HarnessProbe("video.resume-position", "Resume position", "\(source.startFromSeconds)"))
      }
      if playerIsReady { probes.append(HarnessProbe("video.ready", "Video ready")) }
      if let source {
        probes.append(HarnessProbe("video.source", "Video source", Self.sourceName(source)))
      }
      if let selectedAudioLanguage {
        probes.append(
          HarnessProbe("video.audio-language", "Selected audio language", selectedAudioLanguage))
      }
      if let shownSubtitleText {
        probes.append(HarnessProbe("video.subtitle-text", "Shown subtitle text", shownSubtitleText))
      }
      if let shownCaption {
        probes.append(HarnessProbe("video.caption-shown", "Shown caption", shownCaption))
      }
      if let selectedSubtitle {
        probes.append(HarnessProbe("video.subtitle", "Selected subtitle", selectedSubtitle))
      }
      if let playbackPosition {
        probes.append(
          HarnessProbe("video.current-position", "Current playback position", "\(playbackPosition)")
        )
      }
      if playbackReachedEnd { probes.append(HarnessProbe("video.ended", "Playback reached end")) }
      if let conversionHistory {
        probes.append(
          HarnessProbe("video.conversion-history", "Observed conversion states", conversionHistory))
      }
      if fallbacks > 0 {
        probes.append(HarnessProbe("video.fallbacks", "Converted fallbacks", "\(fallbacks)"))
      }
      if !reportedFaults.isEmpty {
        probes.append(
          HarnessProbe(
            "video.reported-failures", "Reported player failures",
            reportedFaults.map(\.rawValue).joined(separator: ",")))
      }
      if let nextVideoLookup {
        probes.append(HarnessProbe("video.next-lookup", "Next video lookup", nextVideoLookup))
      }
      return probes
    }

    private static func sourceName(_ source: PutioPlaybackSource) -> String {
      switch source.original?.player {
      case .engine?: "original-engine"
      case .avPlayer?: "original-avplayer"
      case nil: "stream"
      }
    }
  }

  struct HarnessProbe: Identifiable {
    let id: String
    let label: String
    let value: String?

    init(_ id: String, _ label: String, _ value: String? = nil) {
      self.id = id
      self.label = label
      self.value = value
    }

    static func audioState(_ value: String) -> HarnessProbe {
      HarnessProbe("audio.state", "Audio player state", value)
    }
  }

  struct HarnessProbesView: View {
    let probes: [HarnessProbe]

    var body: some View {
      ZStack {
        ForEach(probes) { probe in
          if let value = probe.value {
            marker(probe).accessibilityValue(Text(verbatim: value))
          } else {
            marker(probe)
          }
        }
      }
      .allowsHitTesting(false)
    }

    private func marker(_ probe: HarnessProbe) -> some View {
      Color.clear
        .frame(width: 1, height: 1)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: probe.label))
        .accessibilityIdentifier(probe.id)
        .allowsHitTesting(false)
    }
  }
#endif
