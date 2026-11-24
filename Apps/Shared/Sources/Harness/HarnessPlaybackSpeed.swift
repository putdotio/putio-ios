import Foundation
import PutioCore

#if DEBUG
  @MainActor
  enum HarnessPlaybackSpeed {
    static let keepArgument = "--putio-harness-keep-playback-speed"
    private static var reset = false

    static func resetUnlessKept(_ defaults: UserDefaults) {
      let arguments = HarnessLaunch.arguments
      guard !reset, arguments.contains(HarnessScenario.launchArgument),
        !arguments.contains(keepArgument)
      else { return }
      reset = true
      defaults.removeObject(forKey: PutioAudioSpeedStore.videoKey)
    }
  }
#endif
