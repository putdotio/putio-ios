import SwiftUI

public struct PutioToast: Identifiable, Equatable, Sendable {
  public struct Action: Sendable {
    public let title: String
    let perform: @MainActor @Sendable () -> Void

    public init(_ title: String, perform: @escaping @MainActor @Sendable () -> Void) {
      self.title = title
      self.perform = perform
    }
  }

  public let id = UUID()
  public let text: String
  public let action: Action?

  public init(_ text: String, action: Action? = nil) {
    self.text = text
    self.action = action
  }

  public static func == (lhs: PutioToast, rhs: PutioToast) -> Bool {
    lhs.id == rhs.id
  }
}

public struct PutioToastView: View {
  private enum Focus: Hashable {
    case text
    case action
  }

  private let toast: PutioToast
  private let onAction: @MainActor () -> Void
  private let onVoiceOverFocusChange: (Bool) -> Void

  @AccessibilityFocusState private var focus: Focus?

  public init(_ toast: PutioToast) {
    self.init(toast, onAction: { toast.action?.perform() }, onVoiceOverFocusChange: { _ in })
  }

  init(
    _ toast: PutioToast,
    onAction: @escaping @MainActor () -> Void,
    onVoiceOverFocusChange: @escaping (Bool) -> Void
  ) {
    self.toast = toast
    self.onAction = onAction
    self.onVoiceOverFocusChange = onVoiceOverFocusChange
  }

  public var body: some View {
    HStack(spacing: PutioToastLayout.contentGap) {
      Text(toast.text)
        .putioFont(PutioToastLayout.textFont)
        .foregroundStyle(PutioToastLayout.textColor)
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, PutioToastLayout.textVerticalPadding)
        .accessibilityFocused($focus, equals: .text)
      if let action = toast.action {
        Button(action: onAction) {
          Text(action.title)
            .putioFont(PutioToastLayout.actionFont)
            .foregroundStyle(PutioToastLayout.textColor)
        }
        .buttonStyle(.bordered)
        .buttonBorderShape(.capsule)
        .tint(PutioToastLayout.textColor)
        .accessibilityFocused($focus, equals: .action)
      }
    }
    .padding(.leading, PutioToastLayout.leadingPadding)
    .padding(
      .trailing,
      toast.action == nil ? PutioToastLayout.leadingPadding : PutioToastLayout.actionInset
    )
    .padding(.vertical, PutioToastLayout.actionInset)
    .modifier(PutioToastSurface())
    .accessibilityElement(children: .contain)
    .onChange(of: focus != nil) { _, focused in
      onVoiceOverFocusChange(focused)
    }
  }
}

private struct PutioToastSurface: ViewModifier {
  @ViewBuilder func body(content: Content) -> some View {
    #if os(tvOS)
      content.background(
        RoundedRectangle(cornerRadius: PutioTheme.TV.radius)
          .fill(PutioTheme.Components.Notification.background)
          .stroke(PutioTheme.Components.Notification.border, lineWidth: PutioTheme.Border.width)
      )
    #elseif os(iOS)
      if HarnessRendering.usesRasterFallback {
        content.background(.regularMaterial, in: Capsule())
      } else {
        content.glassEffect(.regular, in: Capsule())
      }
    #else
      content.background(.regularMaterial, in: Capsule())
    #endif
  }
}

extension View {
  /// Shows one toast at a time: setting a new one replaces the current one.
  public func putioToast(_ toast: Binding<PutioToast?>) -> some View {
    modifier(PutioToastPresenter(toast: toast))
  }
}

private struct PutioToastPresenter: ViewModifier {
  @Binding var toast: PutioToast?
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @State private var timedOut: PutioToast.ID?
  @State private var holdsVoiceOverFocus = false
  @State private var dragOffset: CGFloat = 0

  func body(content: Content) -> some View {
    content.overlay(alignment: .bottom) {
      if let toast {
        PutioToastView(
          toast,
          onAction: { perform(toast) },
          onVoiceOverFocusChange: { focused in
            holdsVoiceOverFocus = focused
            dismissIfTimedOut(toast)
          }
        )
        .id(toast.id)
        .offset(y: dragOffset)
        .modifier(PutioToastSwipe(offset: $dragOffset) { dismiss(toast) })
        .padding(PutioToastLayout.presentationPadding)
        .transition(reduceMotion ? .opacity : .move(edge: .bottom).combined(with: .opacity))
        .zIndex(PutioToastLayout.zIndex)
      }
    }
    .animation(
      PutioTheme.Motion.easingOut.animation(duration: PutioTheme.Motion.durationBase),
      value: toast
    )
    .task(id: toast?.id) {
      dragOffset = 0
      holdsVoiceOverFocus = false
      guard let presented = toast else { return }
      AccessibilityNotification.Announcement(presented.text).post()
      try? await Task.sleep(for: PutioToastLayout.duration)
      guard !Task.isCancelled else { return }
      timedOut = presented.id
      dismissIfTimedOut(presented)
    }
  }

  private func dismissIfTimedOut(_ presented: PutioToast) {
    guard timedOut == presented.id, !holdsVoiceOverFocus else { return }
    dismiss(presented)
  }

  private func dismiss(_ presented: PutioToast) {
    guard toast?.id == presented.id else { return }
    toast = nil
  }

  private func perform(_ presented: PutioToast) {
    guard toast?.id == presented.id, let action = presented.action else { return }
    toast = nil
    action.perform()
  }
}

private struct PutioToastSwipe: ViewModifier {
  @Binding var offset: CGFloat
  let dismiss: @MainActor () -> Void

  func body(content: Content) -> some View {
    #if os(tvOS)
      content
    #else
      content
        .gesture(
          DragGesture(minimumDistance: PutioTheme.Spacing.space2)
            .onChanged { value in
              offset = max(0, value.translation.height)
            }
            .onEnded { value in
              if max(value.translation.height, value.predictedEndTranslation.height)
                > PutioToastLayout.swipeDistance
              {
                dismiss()
              } else {
                withAnimation(
                  PutioTheme.Motion.easingOut.animation(duration: PutioTheme.Motion.durationFast)
                ) {
                  offset = 0
                }
              }
            }
        )
        .accessibilityAction(.escape) { dismiss() }
    #endif
  }
}

enum PutioToastLayout {
  #if os(tvOS)
    static let textFont = PutioTheme.TV.Typography.label
    static let actionFont = PutioTheme.TV.Typography.label
    static let textColor = PutioTheme.Components.Notification.foreground
    static let contentGap = PutioTheme.TV.Spacing.small
    static let leadingPadding = PutioTheme.TV.Spacing.medium
    static let actionInset = PutioTheme.TV.Spacing.small
    static let textVerticalPadding = PutioTheme.TV.Spacing.small
    static let presentationPadding = PutioTheme.TV.Spacing.large
    static let zIndex = PutioTheme.TV.ZIndex.toast
    static let duration = Duration.seconds(3)
  #else
    static let textFont = PutioTheme.Typography.body
    static let actionFont = PutioButtonSize.regular.brandLabel
    static let textColor = PutioTheme.Colors.textPrimary
    static let contentGap = PutioTheme.Spacing.space2
    static let leadingPadding = PutioTheme.Spacing.space3
    static let actionInset = PutioTheme.Spacing.space2
    static let textVerticalPadding = PutioTheme.Spacing.space2
    static let presentationPadding = PutioTheme.Spacing.space3
    static let zIndex = 1.0
    static let duration = Duration.seconds(5)
    static let swipeDistance = PutioTheme.Spacing.space4
  #endif
}
