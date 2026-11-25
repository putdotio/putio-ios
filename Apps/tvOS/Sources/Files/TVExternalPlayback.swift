import Foundation
import PutioCore
import SwiftUI
import UIKit

struct TVSystemURLOpener: PutioExternalURLOpening {
  @MainActor func canOpen(_ url: URL) -> Bool {
    UIApplication.shared.canOpenURL(url)
  }

  @MainActor func open(_ url: URL) async -> Bool {
    await UIApplication.shared.open(url)
  }
}

enum TVExternalPlayback {
  @MainActor static func model(runtime: PutioRuntime) -> PutioExternalPlaybackModel {
    PutioExternalPlaybackModel(opener: opener()) {
      try await runtime.resolveFileDownloadSource(fileID: $0)
    }
  }

  static func opener(arguments: [String] = HarnessLaunch.arguments) -> PutioExternalURLOpening {
    #if DEBUG
      if arguments.contains(HarnessScenario.launchArgument) {
        return HarnessExternalURLOpener.launchArguments(arguments)
      }
    #endif
    return TVSystemURLOpener()
  }
}

struct TVExternalPlaybackPresentation: ViewModifier {
  let model: PutioExternalPlaybackModel?
  @Binding var toast: PutioToast?

  func body(content: Content) -> some View {
    content
      .alert(
        PutioVLCHandoff.missingTitle,
        isPresented: Binding(
          get: { model?.missingVLCRoute != nil },
          set: { if !$0 { model?.dismissMissingVLC() } })
      ) {
        Button(String(localized: "OK", bundle: .putioCore), role: .cancel) {}
          .accessibilityIdentifier("vlc.ok")
      } message: {
        Text(
          String(
            localized: "Install VLC from the App Store on Apple TV to stream this file there.",
            bundle: .putioCore))
      }
      .onChange(of: model?.toast?.text) { _, text in
        guard let text else { return }
        toast = PutioToast(text, icon: .warning, width: .fit)
        model?.toast = nil
      }
  }
}
