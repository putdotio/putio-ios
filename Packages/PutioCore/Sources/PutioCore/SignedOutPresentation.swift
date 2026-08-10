import Foundation

public struct SignedOutPresentation: Equatable, Sendable {
  public let title: String
  public let message: String

  public init(title: String, message: String) {
    self.title = title
    self.message = message
  }

  public static let putio = SignedOutPresentation(
    title: "put.io",
    message: "Sign in to continue"
  )

  public static func harnessExercise(for url: URL) -> SignedOutPresentation? {
    guard url.scheme == "putio-harness", url.host == "exercise" else { return nil }
    return harnessExercise
  }

  public static func harnessInitialPresentation(arguments: [String]) -> SignedOutPresentation {
    guard
      let scenarioIndex = arguments.firstIndex(of: "--putio-harness-scenario"),
      arguments.indices.contains(scenarioIndex + 1),
      arguments[scenarioIndex + 1] == "exercised"
    else { return .putio }
    return harnessExercise
  }

  private static let harnessExercise = SignedOutPresentation(
    title: "put.io",
    message: "Harness exercise complete"
  )
}
