import AetherEngine
import PutioCore
import SwiftUI

struct PutioDirectPlayerView: UIViewRepresentable {
  let fileID: PutioFileID
  let source: PutioPlaybackSource
  let transport: PutioVideoTransport
  let preferredAudioLanguages: [String]
  let remembersPlaybackPosition: Bool
  let subtitlePolicy: PutioSubtitleStartupPolicy
  let subtitleMemory: PutioSubtitleMemory?
  let positionPipeline: PutioPlaybackPositionPipeline
  let reportPosition: PutioPlaybackPositionReport
  let callbacks: PutioVideoPlayerCallbacks

  func makeCoordinator() -> PutioDirectPlayCoordinator {
    PutioDirectPlayCoordinator(positionPipeline: positionPipeline)
  }

  func makeUIView(context: Context) -> AetherPlayerView {
    let view = AetherPlayerView()
    view.backgroundColor = .black
    context.coordinator.start(
      fileID: fileID, source: source, transport: transport,
      preferredAudioLanguages: preferredAudioLanguages,
      remembersPlaybackPosition: remembersPlaybackPosition,
      subtitles: PutioDirectPlayCoordinator.SubtitleStart(
        policy: subtitlePolicy, remembered: { subtitleMemory?.remembered }),
      reportPosition: { try await reportPosition($0, $1) }, in: view, callbacks: callbacks)
    return view
  }

  func updateUIView(_ view: AetherPlayerView, context: Context) {}

  static func dismantleUIView(_ view: AetherPlayerView, coordinator: PutioDirectPlayCoordinator) {
    coordinator.stop()
  }
}

extension PutioVideoTransport: PutioDirectPlayTransport {}
