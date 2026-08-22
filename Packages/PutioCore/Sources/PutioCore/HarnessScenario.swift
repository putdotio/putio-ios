import Foundation

public enum HarnessScenario: String, CaseIterable, Sendable {
  case signedOut = "signed-out"
  case exercised
  case gallery

  public static let launchArgument = "--putio-harness-scenario"

  public static func parse(arguments: [String]) -> HarnessScenario {
    guard
      let flagIndex = arguments.firstIndex(of: launchArgument),
      arguments.indices.contains(flagIndex + 1),
      let scenario = HarnessScenario(rawValue: arguments[flagIndex + 1])
    else {
      return .signedOut
    }
    return scenario
  }
}
