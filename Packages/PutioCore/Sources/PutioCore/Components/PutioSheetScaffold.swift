import SwiftUI

// On iOS and watchOS sheets are the system presentation: the scaffold only
// arranges a title bar and content and lets the platform provide the sheet
// surface. tvOS paints the contract's centered solid modal over a scrim,
// because TV menus are centered modals with no translucent materials.
public struct PutioSheetScaffold<Content: View>: View {
  private let title: String
  private let content: Content

  public init(title: String, @ViewBuilder content: () -> Content) {
    self.title = title
    self.content = content()
  }

  public var body: some View {
    #if os(tvOS)
      VStack(spacing: 0) {
        titleRow
        Rectangle()
          .fill(PutioTheme.Components.Sheet.border)
          .frame(height: PutioTheme.Border.width)
        content
          .frame(maxWidth: .infinity, alignment: .leading)
          .padding(PutioSheetLayout.contentPadding)
      }
      .background(
        PutioTheme.Components.Sheet.background,
        in: RoundedRectangle(cornerRadius: PutioTheme.TV.radius)
      )
    #else
      VStack(spacing: 0) {
        titleRow
        Divider()
        content
          .frame(maxWidth: .infinity, alignment: .leading)
          .padding(PutioSheetLayout.contentPadding)
        Spacer(minLength: 0)
      }
    #endif
  }

  // Centred on the system sheet (ios-e12); the TV modal keeps its leading
  // title per the TV contract.
  private var titleRow: some View {
    Text(title)
      .putioFont(PutioSheetLayout.titleFont)
      .foregroundStyle(PutioTheme.Colors.textPrimary)
      .frame(maxWidth: .infinity, alignment: PutioSheetLayout.titleAlignment)
      .padding(PutioSheetLayout.contentPadding)
  }
}

extension View {
  // System sheet on iOS and watchOS; centered solid modal on tvOS.
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
    #if os(tvOS)
      content.overlay {
        if isPresented {
          ZStack {
            PutioTheme.Components.Sheet.scrim.ignoresSafeArea()
            PutioSheetScaffold(title: title) { modal() }
              .padding(PutioTheme.TV.Spacing.xl)
          }
          .transition(.opacity)
          .zIndex(PutioTheme.TV.ZIndex.modal)
        }
      }
      .animation(
        PutioTheme.Motion.easingInOut.animation(duration: PutioTheme.Motion.durationBase),
        value: isPresented
      )
    #else
      content.sheet(isPresented: $isPresented) {
        PutioSheetScaffold(title: title) { modal() }
      }
    #endif
  }
}

enum PutioSheetLayout {
  #if os(tvOS)
    static let titleFont = PutioTheme.TV.Typography.label
    static let contentPadding = PutioTheme.TV.Spacing.medium
    static let titleAlignment = Alignment.leading
  #else
    static let titleFont = PutioTheme.Typography.subheading
    static let contentPadding = PutioTheme.Spacing.space3
    static let titleAlignment = Alignment.center
  #endif
}
