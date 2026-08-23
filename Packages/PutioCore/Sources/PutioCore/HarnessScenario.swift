import Foundation

// Liquid Glass cannot be rasterized by off-screen rendering, so the snapshot
// lane sets this flag and glass surfaces drop to their bordered/material
// fallbacks; the harness gallery captures review the real glass appearance.
public enum HarnessRendering {
  public static let usesRasterFallback =
    ProcessInfo.processInfo.environment["PUTIO_SNAPSHOT_RASTER"] == "1"
}

public enum HarnessScenario: String, CaseIterable, Sendable {
  case signedOut = "signed-out"
  case exercised
  case gallery
  case signedIn = "signed-in"

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
