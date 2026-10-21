import Foundation
import PutioCore

// Harness launch arguments seed sessions, sign out automatically, and expose
// proof probes, so only Debug app builds honor them. The gate lives in the app
// target because PutioCore's DEBUG condition need not match the app's.
enum HarnessLaunch {
  #if DEBUG
    static let isEnabled = true
  #else
    static let isEnabled = false
  #endif

  static let arguments = honoredArguments(ProcessInfo.processInfo.arguments, isEnabled: isEnabled)
  static var scenario: HarnessScenario { HarnessScenario.parse(arguments: arguments) }

  /// Harness runs, live ones included, meet the product analytics prompt
  /// only when they ask for it.
  static let analyticsPromptArgument = "--putio-harness-analytics-prompt"
  static var allowsProductAnalyticsPrompt: Bool {
    !arguments.contains(HarnessScenario.launchArgument)
      || arguments.contains(analyticsPromptArgument)
  }

  static func honoredArguments(_ launchArguments: [String], isEnabled: Bool) -> [String] {
    isEnabled ? launchArguments : []
  }
}
