import SwiftUI

#if os(iOS)
  import UIKit
#endif

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
  let perform: @MainActor @Sendable () -> Void

  public init(
    id: String,
    title: String,
    icon: PutioIcon,
    role: Role = .standard,
    isDisabled: Bool = false,
    subtitle: String? = nil,
    perform: @escaping @MainActor @Sendable () -> Void
  ) {
    self.id = id
    self.title = title
    self.icon = icon
    self.role = role
    self.isDisabled = isDisabled
    self.subtitle = subtitle
    self.perform = perform
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
  let submit: @MainActor @Sendable (String) async throws -> Void

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
  let confirm: @MainActor @Sendable () -> Void

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

#if os(iOS)
  public struct PutioItemMenuContent: View {
    private let menu: PutioItemMenu

    public init(_ menu: PutioItemMenu) {
      self.menu = menu
    }

    public var body: some View {
      ForEach(Array(menu.sections.enumerated()), id: \.offset) { _, section in
        Section {
          ForEach(section) { action in
            Button(role: action.role == .destructive ? .destructive : nil) {
              action.perform()
            } label: {
              PutioItemActionLabel(action: action)
            }
            .tint(action.role == .destructive ? nil : PutioTheme.Colors.textPrimary)
            .disabled(action.isDisabled)
            .accessibilityIdentifier("item-action.\(action.id)")
          }
        }
      }
    }
  }

  private struct PutioItemActionLabel: View {
    let action: PutioItemAction

    var body: some View {
      Label {
        Text(action.title)
        if let subtitle = action.subtitle {
          Text(subtitle)
        }
      } icon: {
        Image(putioIcon: action.icon)
      }
    }
  }

  extension View {
    public func putioItemActions(
      _ menu: PutioItemMenu,
      leading: [PutioItemAction] = [],
      trailing: [PutioItemAction] = []
    ) -> some View {
      modifier(PutioItemActionsModifier(menu: menu, leading: leading, trailing: trailing))
    }

    public func putioTextAlert(_ alert: Binding<PutioTextAlert?>) -> some View {
      modifier(PutioTextAlertPresenter(request: alert))
    }

    public func putioConfirmAlert(_ alert: Binding<PutioConfirmAlert?>) -> some View {
      modifier(PutioConfirmAlertPresenter(request: alert))
    }
  }

  private struct PutioItemActionsModifier: ViewModifier {
    let menu: PutioItemMenu
    let leading: [PutioItemAction]
    let trailing: [PutioItemAction]

    func body(content: Content) -> some View {
      content
        .contextMenu { PutioItemMenuContent(menu) }
        .swipeActions(edge: .leading, allowsFullSwipe: false) {
          ForEach(leading) { action in
            swipeButton(action)
          }
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
          ForEach(trailing) { action in
            swipeButton(action)
          }
          Menu {
            PutioItemMenuContent(menu)
          } label: {
            Label {
              Text(String(localized: "More", bundle: .module))
            } icon: {
              Image(putioIcon: .dotsThree)
            }
            .labelStyle(.iconOnly)
          }
          .menuOrder(.fixed)
          .tint(PutioTheme.Components.Button.secondaryBackground)
          .accessibilityIdentifier("item-swipe.more")
        }
        .menuOrder(.fixed)
    }

    private func swipeButton(_ action: PutioItemAction) -> some View {
      Button(role: action.role == .destructive ? .destructive : nil) {
        action.perform()
      } label: {
        PutioItemActionLabel(action: action)
          .labelStyle(.iconOnly)
      }
      .disabled(action.isDisabled)
      .tint(
        action.role == .destructive
          ? PutioTheme.Colors.destructive : PutioTheme.Components.Button.secondaryBackground
      )
      .accessibilityIdentifier("item-swipe.\(action.id)")
    }
  }

  @MainActor @Observable
  final class PutioTextAlertSender {
    var toast: PutioToast?

    func send(_ alert: PutioTextAlert, text: String) {
      Task {
        do {
          try await alert.submit(text)
        } catch {
          toast = PutioToast(
            alert.failureText,
            action: PutioToast.Action(String(localized: "Try again", bundle: .module)) {
              [self] in
              send(alert, text: text)
            }
          )
        }
      }
    }
  }

  private struct PutioTextAlertPresenter: ViewModifier {
    @Binding var request: PutioTextAlert?
    @State private var presented: PutioTextAlert?
    @State private var text = String()
    @State private var sender = PutioTextAlertSender()

    func body(content: Content) -> some View {
      @Bindable var failures = sender
      content
        .alert(
          Text(presented?.title ?? String()),
          isPresented: isPresented,
          presenting: presented
        ) { alert in
          TextField(alert.title, text: $text)
            .autocorrectionDisabled()
            .textInputAutocapitalization(.never)
            .accessibilityIdentifier("text-alert.field")
          Button(String(localized: "Cancel", bundle: .module), role: .cancel) {}
          Button(alert.submitTitle) {
            sender.send(alert, text: text.trimmingCharacters(in: .whitespacesAndNewlines))
          }
          .keyboardShortcut(.defaultAction)
          .disabled(!PutioTextAlert.canSubmit(text, replacing: alert.initialText))
          .accessibilityIdentifier("text-alert.submit")
        } message: { alert in
          if let message = alert.message {
            Text(message)
          }
        }
        .onChange(of: request?.id, initial: true) {
          if let request {
            text = request.initialText
          }
          presented = request
        }
        .onReceive(
          NotificationCenter.default.publisher(for: UITextField.textDidBeginEditingNotification)
        ) { notification in
          guard let presented, let field = notification.object as? UITextField,
            field.text == presented.initialText
          else { return }
          let length = PutioTextAlert.selectedLength(of: presented.initialText)
          Task {
            let start = field.beginningOfDocument
            guard let end = field.position(from: start, offset: length) else { return }
            field.selectedTextRange = field.textRange(from: start, to: end)
          }
        }
        .putioToast($failures.toast)
    }

    private var isPresented: Binding<Bool> {
      Binding(
        get: { presented != nil },
        set: { shown in
          guard !shown else { return }
          presented = nil
          request = nil
        }
      )
    }
  }

  private struct PutioConfirmAlertPresenter: ViewModifier {
    @Binding var request: PutioConfirmAlert?

    func body(content: Content) -> some View {
      content.alert(
        Text(request?.title ?? String()),
        isPresented: isPresented,
        presenting: request
      ) { alert in
        Button(String(localized: "Cancel", bundle: .module), role: .cancel) {}
        Button(alert.confirmTitle, role: .destructive) {
          alert.confirm()
        }
        .accessibilityIdentifier("confirm-alert.confirm")
      } message: { alert in
        if let message = alert.message {
          Text(message)
        }
      }
    }

    private var isPresented: Binding<Bool> {
      Binding(
        get: { request != nil },
        set: { if !$0 { request = nil } }
      )
    }
  }
#endif
