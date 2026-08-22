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
    HarnessScenario.parse(arguments: arguments) == .exercised
  }

  public static func signalHarnessExercise() {
    try? Data().write(
      to: FileManager.default.temporaryDirectory.appending(path: harnessExerciseMarkerFilename),
      options: .atomic
    )
  }

  public var isHarnessExercise: Bool {
    self == Self.harnessExercise
  }

  public static let harnessExerciseMarkerFilename = "putio-harness-exercise-complete"

  private static let harnessExercise = SignedOutPresentation(
    title: "put.io",
    message: "Harness exercise complete"
  )
}
