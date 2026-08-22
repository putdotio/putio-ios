import SwiftUI

public struct PutioSheetScaffold<Content: View>: View {
  private let title: String
  private let content: Content

  public init(title: String, @ViewBuilder content: () -> Content) {
    self.title = title
    self.content = content()
  }

  public var body: some View {
    VStack(spacing: 0) {
      Text(title)
        .putioFont(PutioSheetLayout.titleFont)
        .foregroundStyle(PutioTheme.Colors.textPrimary)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(PutioSheetLayout.contentPadding)
      Rectangle()
        .fill(PutioTheme.Components.Sheet.border)
        .frame(height: PutioTheme.Border.width)
      content
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(PutioSheetLayout.contentPadding)
    }
    .background(PutioTheme.Components.Sheet.background, in: PutioSheetLayout.shape)
    .overlay(
      PutioSheetLayout.shape.strokeBorder(
        PutioTheme.Components.Sheet.border,
        lineWidth: PutioTheme.Border.width
      )
    )
  }
}

extension View {
  // Centered token-surface modal over a scrim; on TV this is the one modal
  // presentation (menus are centered modals, solid colors, no materials).
  public func putioModal<Content: View>(
    isPresented: Binding<Bool>,
    title: String,
    @ViewBuilder content: @escaping () -> Content
  ) -> some View {
    modifier(PutioModalPresenter(isPresented: isPresented, title: title, modal: content))
  }
}

private struct PutioModalPresenter<Modal: View>: ViewModifier {
  @Binding var isPresented: Bool
  let title: String
  @ViewBuilder let modal: () -> Modal

  func body(content: Content) -> some View {
    content.overlay {
      if isPresented {
        ZStack {
          PutioTheme.Components.Sheet.scrim.ignoresSafeArea()
          PutioSheetScaffold(title: title) { modal() }
            .padding(PutioSheetLayout.presentationPadding)
        }
        .transition(.opacity)
        .zIndex(PutioSheetLayout.zIndex)
      }
    }
    .animation(
      PutioTheme.Motion.easingInOut.animation(duration: PutioTheme.Motion.durationBase),
      value: isPresented
    )
  }
}

enum PutioSheetLayout {
  #if os(tvOS)
    static let titleFont = PutioTheme.TV.Typography.label
    static let contentPadding = PutioTheme.TV.Spacing.medium
    static let presentationPadding = PutioTheme.TV.Spacing.xl
    static let zIndex = PutioTheme.TV.ZIndex.modal
    static let shape = RoundedRectangle(cornerRadius: PutioTheme.TV.radius)
  #else
    static let titleFont = PutioTheme.Typography.subheading
    static let contentPadding = PutioTheme.Spacing.space3
    static let presentationPadding = PutioTheme.Spacing.space3
    static let zIndex = 1.0
    static let shape = RoundedRectangle(cornerRadius: PutioTheme.Radius.large)
  #endif
}
