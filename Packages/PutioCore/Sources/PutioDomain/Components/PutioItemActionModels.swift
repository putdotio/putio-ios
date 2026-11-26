import Foundation

public struct PutioItemAction: Identifiable, Sendable {
  public enum Role: Sendable {
    case standard
    case destructive
  }

  public let id: String
  public let title: String
  public let icon: PutioIcon
  public let role: Role
  public let isDisabled: Bool
  public let subtitle: String?
  public let asksFirst: Bool
  public let children: [PutioItemAction]
  package let perform: @MainActor @Sendable () -> Void

  public init(
    id: String,
    title: String,
    icon: PutioIcon,
    role: Role = .standard,
    isDisabled: Bool = false,
    subtitle: String? = nil,
    asksFirst: Bool = false,
    perform: @escaping @MainActor @Sendable () -> Void
  ) {
    self.id = id
    self.title = title
    self.icon = icon
    self.role = role
    self.isDisabled = isDisabled
    self.subtitle = subtitle
    self.asksFirst = asksFirst
    children = []
    self.perform = perform
  }

  public init(submenu id: String, title: String, icon: PutioIcon, children: [PutioItemAction]) {
    self.id = id
    self.title = title
    self.icon = icon
    role = .standard
    isDisabled = children.allSatisfy(\.isDisabled)
    subtitle = nil
    asksFirst = false
    self.children = children
    perform = {}
  }
}

public struct PutioItemMenu: Sendable {
  public let sections: [[PutioItemAction]]

  public init(_ groups: [[PutioItemAction]]) {
    let kept = groups.map { group in group.filter { $0.role == .standard } }
    let destructive = groups.flatMap { group in group.filter { $0.role == .destructive } }
    sections = (kept + [destructive]).filter { !$0.isEmpty }
  }
}

public struct PutioTextAlert: Identifiable, Sendable {
  public let id = UUID()
  public let title: String
  public let message: String?
  public let initialText: String
  public let submitTitle: String
  public let failureText: String
  package let submit: @MainActor @Sendable (String) async throws -> Void

  public init(
    title: String,
    message: String? = nil,
    initialText: String,
    submitTitle: String,
    failureText: String,
    submit: @escaping @MainActor @Sendable (String) async throws -> Void
  ) {
    self.title = title
    self.message = message
    self.initialText = initialText
    self.submitTitle = submitTitle
    self.failureText = failureText
    self.submit = submit
  }

  public static func canSubmit(_ text: String, replacing initialText: String) -> Bool {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    return !trimmed.isEmpty && trimmed != initialText
  }

  public static func selectedLength(of name: String) -> Int {
    guard let dot = name.lastIndex(of: "."), dot != name.startIndex else {
      return name.utf16.count
    }
    return name[..<dot].utf16.count
  }
}

public struct PutioConfirmAlert: Identifiable, Sendable {
  public let id = UUID()
  public let title: String
  public let message: String?
  public let confirmTitle: String
  package let confirm: @MainActor @Sendable () -> Void

  public init(
    title: String,
    message: String? = nil,
    confirmTitle: String,
    confirm: @escaping @MainActor @Sendable () -> Void
  ) {
    self.title = title
    self.message = message
    self.confirmTitle = confirmTitle
    self.confirm = confirm
  }
}
