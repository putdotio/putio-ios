#if canImport(AetherEngine)
  import AetherEngine
  import CoreGraphics
  import PutioCore

  enum PutioEngineTracks {
    static func audio(_ tracks: [TrackInfo], active: Int?) -> (
      tracks: [PutioVideoAudioTrack], selected: Int?
    ) {
      let decodable = tracks.enumerated().filter {
        PutioDirectPlayDecoders.canDecodeAudio(codec: $0.element.codec)
      }
      let titles = PutioTrackLabel.distinct(
        decodable.map { index, track in
          PutioTrackLabel.audioTitle(language: track.language, name: track.name, index: index)
        })
      let audio = zip(decodable, titles).map { entry, title in
        PutioVideoAudioTrack(
          id: entry.element.id, title: title,
          detail: PutioTrackLabel.audioDetail(
            codec: entry.element.codec, profile: entry.element.profile,
            channels: entry.element.channels),
          languageTag: entry.element.language)
      }
      return (audio, active.flatMap { id in audio.contains { $0.id == id } ? id : nil })
    }

    static func subtitles(_ tracks: [TrackInfo]) -> [PutioSubtitleTrack] {
      tracks.enumerated().map { index, track in
        PutioSubtitleTrack(
          id: track.id,
          title: track.isExternal
            ? track.name
            : PutioTrackLabel.subtitleTitle(
              language: track.language, name: track.name, index: index),
          languageTag: track.language)
      }
    }

    static func showing(_ cues: [SubtitleCue], at time: Double, delay: Double) -> [SubtitleCue] {
      let shifted = time - delay
      return cues.filter { $0.startTime <= shifted && shifted < $0.endTime }
    }

    static func picture(
      width: Int32, height: Int32, display: CGSize?, pixelAspectRatio: Double
    ) -> PutioVideoPicture {
      let coded = CGSize(width: Int(width), height: Int(height))
      return PutioVideoPicture(
        coded: coded,
        display: display ?? CGSize(width: coded.width * pixelAspectRatio, height: coded.height))
    }
  }
#endif
