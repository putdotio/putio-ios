import Foundation
import PutioCore

extension PutioAudioSpeedStore {
  static func video(defaults: UserDefaults = .standard) -> PutioAudioSpeedStore {
    #if DEBUG
      HarnessPlaybackSpeed.resetUnlessKept(defaults)
    #endif
    return PutioAudioSpeedStore(defaults: defaults, key: videoKey)
  }
}
