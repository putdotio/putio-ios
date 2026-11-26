import SwiftUI

#if os(iOS)
  import UIKit
#endif

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
            if action.children.isEmpty {
              PutioItemActionButton(action: action)
            } else {
              Menu {
                ForEach(action.children) { child in
                  PutioItemActionButton(action: child)
                }
              } label: {
                PutioItemActionLabel(action: action)
              }
              .menuOrder(.fixed)
              .tint(PutioTheme.Colors.textPrimary)
              .disabled(action.isDisabled)
              .accessibilityIdentifier("item-action.\(action.id)")
            }
          }
        }
      }
    }
  }

  private struct PutioItemActionButton: View {
    let action: PutioItemAction

    var body: some View {
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

  private struct PutioItemActionLabel: View {
    let action: PutioItemAction
    @PutioScaledMetric(PutioMetricRole(value: 22, relativeTo: .body)) private var iconSide: CGFloat

    var body: some View {
      if let subtitle = action.subtitle {
        Text(action.title)
        Text(subtitle)
        icon
      } else {
        Label {
          Text(action.title)
        } icon: {
          icon
        }
      }
    }

    private var icon: Image {
      guard let source = UIImage(named: action.icon.rawValue, in: .module, with: nil) else {
        return Image(putioIcon: action.icon)
      }
      let bounds = CGRect(x: 0, y: 0, width: iconSide.rounded(), height: iconSide.rounded())
      let image = UIGraphicsImageRenderer(bounds: bounds).image { _ in source.draw(in: bounds) }
      guard action.role == .destructive, action.isDisabled else {
        return Image(uiImage: image.withRenderingMode(.alwaysTemplate))
      }
      return Image(uiImage: image.fixed(Self.dimmedDestructive))
    }

    private static let dimmedDestructive = PutioTheme.Colors.destructive
      .opacity(PutioDisabledRole.opacity)
  }

  extension View {
    public func putioItemActions(
      _ menu: PutioItemMenu,
      leading: [PutioItemAction] = [],
      trailing: [PutioItemAction] = [],
      preview: AnyView? = nil
    ) -> some View {
      modifier(
        PutioItemActionsModifier(
          menu: menu, leading: leading, trailing: trailing, preview: preview))
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
    let preview: AnyView?

    @ViewBuilder
    func body(content: Content) -> some View {
      if let preview {
        swipes(
          content.contextMenu {
            PutioItemMenuContent(menu)
          } preview: {
            preview
          })
      } else {
        swipes(content.contextMenu { PutioItemMenuContent(menu) })
      }
    }

    private func swipes(_ content: some View) -> some View {
      content
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
              Text(String(localized: "More", bundle: .putioCore))
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
      Button(role: action.role == .destructive && !action.asksFirst ? .destructive : nil) {
        action.perform()
      } label: {
        Label {
          Text(action.title)
        } icon: {
          Image(putioIcon: action.icon)
        }
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
            action: PutioToast.Action(String(localized: "Try again", bundle: .putioCore)) {
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
        .putioAlert(
          presented?.title ?? String(),
          isPresented: isPresented,
          message: presented?.message,
          field: presented.map {
            PutioAlertField(
              label: $0.title, text: $text, accessibilityIdentifier: "text-alert.field")
          },
          actions: actions
        )
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

    private var actions: [PutioAlertAction] {
      guard let presented else { return [] }
      let name = text.trimmingCharacters(in: .whitespacesAndNewlines)
      return [
        PutioAlertAction(String(localized: "Cancel", bundle: .putioCore), tier: .cancel),
        PutioAlertAction(
          presented.submitTitle, tier: .primary, id: "text-alert.submit",
          isDisabled: !PutioTextAlert.canSubmit(text, replacing: presented.initialText)
        ) { [sender] in
          sender.send(presented, text: name)
        },
      ]
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
      content.putioAlert(
        request?.title ?? String(),
        isPresented: isPresented,
        message: request?.message,
        actions: actions
      )
    }

    private var actions: [PutioAlertAction] {
      guard let request else { return [] }
      return [
        PutioAlertAction(String(localized: "Cancel", bundle: .putioCore), tier: .cancel),
        PutioAlertAction(
          request.confirmTitle, tier: .destructive, id: "confirm-alert.confirm",
          perform: request.confirm),
      ]
    }

    private var isPresented: Binding<Bool> {
      Binding(
        get: { request != nil },
        set: { if !$0 { request = nil } }
      )
    }
  }
#endif
