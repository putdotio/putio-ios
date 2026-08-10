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

  public static func harnessInitialPresentation(arguments: [String]) -> SignedOutPresentation {
    isHarnessExercise(arguments: arguments) ? harnessExercise : .putio
  }

  public static func isHarnessExercise(arguments: [String]) -> Bool {
    guard let scenarioIndex = arguments.firstIndex(of: "--putio-harness-scenario") else {
      return false
    }
    return arguments.indices.contains(scenarioIndex + 1)
      && arguments[scenarioIndex + 1] == "exercised"
  }

  public static func signalHarnessExercise() {
    try? Data().write(
      to: FileManager.default.temporaryDirectory.appending(path: harnessExerciseMarkerFilename),
      options: .atomic
    )
  }

  public static let harnessExerciseMarkerFilename = "putio-harness-exercise-complete"

  private static let harnessExercise = SignedOutPresentation(
    title: "put.io",
    message: "Harness exercise complete"
  )
}
