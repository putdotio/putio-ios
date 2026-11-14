import PutioCore
import SwiftUI

struct PlaybackMethodView: View {
  let appConfig: PutioAppConfigModel

  var body: some View {
    List {
      PutioSettingsSection(String(localized: "Choose how this app plays videos.")) {
        PutioChoiceList(
          selection: appConfig.playbackMethod,
          options: PutioPlaybackMethod.allCases,
          save: { method in
            try await appConfig.setPlaybackMethod(method).requireSaved()
          }
        ) { method in
          PutioChoice(method.title, description: method.summary)
        }
        .disabled(!appConfig.canSave)
      }
      .listRowBackground(PutioTheme.Colors.surface)
    }
    .navigationTitle(String(localized: "Playback method"))
    .navigationBarTitleDisplayMode(.inline)
    .putioFont(PutioTheme.Typography.body)
    .putioContentBackground()
    .putioSettingSaveFailures()
  }
}

extension PutioPlaybackMethod {
  var title: String {
    switch self {
    case .standard: String(localized: "Standard")
    case .directPlay: String(localized: "Direct play")
    }
  }

  var playWithTitle: String {
    switch self {
    case .standard: String(localized: "Play with Standard")
    case .directPlay: String(localized: "Play with Direct play")
    }
  }

  fileprivate var summary: String {
    switch self {
    case .standard:
      String(localized: "Works on every device. Converted videos play at up to 1080p, stereo.")
    case .directPlay:
      UIDevice.current.userInterfaceIdiom == .pad
        ? String(
          localized:
            "Plays the original file, up to 4K and surround, when this iPad can. Converted otherwise."
        )
        : String(
          localized:
            "Plays the original file, up to 4K and surround, when this iPhone can. Converted otherwise."
        )
    }
  }
}

/// Plays one video once with the method that is not the account's, from a
/// file menu's "Play with" row.
struct PutioPlayWithOtherMethod {
  let method: PutioPlaybackMethod
  let play: @MainActor @Sendable (PutioFileRoute, PutioPlaybackMethod) -> Void

  @MainActor
  func action(for route: PutioFileRoute, isDisabled: Bool = false) -> PutioItemAction {
    let method = method
    let play = play
    return PutioItemAction(
      id: "play-with-other-method", title: method.playWithTitle, icon: .playCircle,
      isDisabled: isDisabled
    ) { play(route, method) }
  }
}

extension EnvironmentValues {
  @Entry var putioPlayWithOtherMethod: PutioPlayWithOtherMethod? = nil
}
