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
}
