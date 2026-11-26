import Foundation

public struct PutioToast: Identifiable, Equatable, Sendable {
  public struct Action: Sendable {
    public let title: String
    package let perform: @MainActor @Sendable () -> Void

    public init(_ title: String, perform: @escaping @MainActor @Sendable () -> Void) {
      self.title = title
      self.perform = perform
    }
  }

  public enum Icon: Sendable {
    case warning
    case symbol(PutioIcon)
  }

  public enum Width: Sendable {
    case fill
    case fit
  }

  public let id = UUID()
  public let text: String
  public let icon: Icon?
  public let action: Action?
  public let width: Width
  public let staysUntilDismissed: Bool

  public init(
    _ text: String, icon: Icon? = nil, action: Action? = nil, width: Width = .fill,
    staysUntilDismissed: Bool = false
  ) {
    self.text = text
    self.icon = icon
    self.action = action
    self.width = width
    self.staysUntilDismissed = staysUntilDismissed
  }

  public static func == (lhs: PutioToast, rhs: PutioToast) -> Bool {
    lhs.id == rhs.id
  }
}
