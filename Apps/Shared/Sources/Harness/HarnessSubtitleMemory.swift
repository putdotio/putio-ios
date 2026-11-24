import Foundation
import PutioCore

#if DEBUG
  @MainActor
  enum HarnessSubtitleMemory {
    private static let suite = "io.put.harness.subtitle-memory"
    private static let launchDefaults: UserDefaults? = {
      UserDefaults(suiteName: suite).map { defaults in
        defaults.removePersistentDomain(forName: suite)
        return defaults
      }
    }()

    static func make() -> PutioSubtitleMemory {
      guard ProcessInfo.processInfo.arguments.contains(HarnessScenario.launchArgument),
        let defaults = launchDefaults
      else { return PutioSubtitleMemory() }
      return PutioSubtitleMemory(defaults: defaults)
    }
  }
#endif
