import PutioCore
import SwiftUI

/// The Cast surfaces that ride on the tab shell: the bar above the tab bar,
/// the expanded controls sheet, and the harness stub picker.
struct PutioCastPresentation: ViewModifier {
  let model: PutioCastModel
  var audioPlayback: PutioAudioPlaybackSession? = nil

  func body(content: Content) -> some View {
    content
      .modifier(PutioCastBarAccessory(model: model, audioPlayback: audioPlayback))
      .sheet(
        isPresented: Binding(
          get: { model.presentsControls }, set: { if !$0 { model.hideControls() } })
      ) {
        PutioCastControlsView(model: model)
          .preferredColorScheme(.dark)
      }
      #if DEBUG
        .modifier(PutioHarnessCastPresentation(model: model))
      #endif
  }
}

/// The accessory slot reserves its height whenever it is installed, so the
/// bar is installed only while a receiver has something of ours.
private struct PutioCastBarAccessory: ViewModifier {
  let model: PutioCastModel
  let audioPlayback: PutioAudioPlaybackSession?

  private var hasAccessory: Bool { model.hasSession || audioPlayback?.model != nil }

  @ViewBuilder
  private var accessory: some View {
    if let audioPlayback, let audio = audioPlayback.model {
      PutioAudioMiniPlayer(model: audio) { audioPlayback.isPresented = true }
    } else if model.hasSession {
      PutioCastBar(model: model)
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
