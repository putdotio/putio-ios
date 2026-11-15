import PutioCore
import SwiftUI

/// The Cast bar above the tab bar. The accessory slot reserves its height
/// whenever it is installed, so the bar is installed only while a receiver
/// has something of ours.
struct PutioCastPresentation: ViewModifier {
  let model: PutioCastModel
  var audio: PutioAudioMiniPlayerSlot? = nil
  let onOpen: () -> Void

  private var audioModel: PutioAudioPlayerModel? {
    guard let audio, !audio.placement.tabBarOnTop else { return nil }
    return audio.playback.model
  }

  private var hasAccessory: Bool { model.hasSession || audioModel != nil }

  @ViewBuilder
  private var accessory: some View {
    if let audio, let audioModel {
      PutioAudioMiniPlayer(
        model: audioModel, onOpen: { audio.playback.isPresented = true }, onStop: audio.onStop)
    } else if model.hasSession {
      PutioCastBar(model: model, onOpen: onOpen)
    }
  }

  func body(content: Content) -> some View {
    if #available(iOS 26.1, *) {
      content.tabViewBottomAccessory(isEnabled: hasAccessory) { accessory }
    } else if hasAccessory {
      content.tabViewBottomAccessory { accessory }
    } else {
      content
    }
  }
}
