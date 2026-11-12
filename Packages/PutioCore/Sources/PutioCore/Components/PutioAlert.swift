import SwiftUI

public struct PutioAlertAction: Identifiable, Sendable {
  public enum Tier: Sendable {
    case cancel
    case neutral
    case primary
    case destructive
  }

  public let id: String
  public let title: String
  public let tier: Tier
  let accessibilityIdentifier: String
  let perform: @MainActor @Sendable () -> Void

  public init(
    _ title: String,
    tier: Tier,
    id: String? = nil,
    perform: @escaping @MainActor @Sendable () -> Void = {}
  ) {
    self.id = id ?? "\(tier).\(title)"
    accessibilityIdentifier = id ?? "putio-alert.\(tier)"
    self.title = title
    self.tier = tier
    self.perform = perform
  }
}

#if os(iOS)
  extension View {
    public func putioAlert(
      _ title: String,
      isPresented: Binding<Bool>,
      message: String? = nil,
      actions: [PutioAlertAction]
    ) -> some View {
      modifier(
        PutioAlertPresenter(
          title: title, message: message, actions: actions, isPresented: isPresented))
    }
  }

  private struct PutioAlertPresenter: ViewModifier {
    let title: String
    let message: String?
    let actions: [PutioAlertAction]
    @Binding var isPresented: Bool
    @State private var shown = false
    @State private var chosen: PutioAlertAction?

    func body(content: Content) -> some View {
      content
        .fullScreenCover(isPresented: $shown, onDismiss: finish) {
          PutioAlertCard(title: title, message: message, actions: actions) { action in
            chosen = action
            isPresented = false
          }
          .presentationBackground(.clear)
          .preferredColorScheme(.dark)
        }
        .onChange(of: isPresented, initial: true) { _, presented in
          var transaction = Transaction()
          transaction.disablesAnimations = true
          withTransaction(transaction) { shown = presented }
        }
    }

    private func finish() {
      let action = chosen
      chosen = nil
      if isPresented { isPresented = false }
      action?.perform()
    }
  }

  private struct PutioAlertCard: View {
    let title: String
    let message: String?
    let actions: [PutioAlertAction]
    let choose: (PutioAlertAction) -> Void

    @State private var appeared = false
    @PutioScaledMetric private var width: CGFloat

    init(
      title: String, message: String?, actions: [PutioAlertAction],
      choose: @escaping (PutioAlertAction) -> Void
    ) {
      self.title = title
      self.message = message
      self.actions = actions
      self.choose = choose
      _width = PutioScaledMetric(PutioAlertMetrics.width)
    }

    var body: some View {
      ZStack {
        PutioTheme.Components.Sheet.scrim
          .ignoresSafeArea()
          .opacity(appeared ? 1 : 0)
          .accessibilityHidden(true)
        ViewThatFits(in: .vertical) {
          card
          ScrollView { card }
            .scrollBounceBehavior(.basedOnSize)
        }
        .frame(maxWidth: width)
        .padding(PutioTheme.Spacing.space3)
        .opacity(appeared ? 1 : 0)
        .scaleEffect(appeared ? 1 : 1.05)
      }
      .onAppear {
        withAnimation(.easeOut(duration: PutioTheme.Motion.durationBase)) { appeared = true }
      }
    }

    private var card: some View {
      VStack(spacing: PutioTheme.Spacing.space3) {
        VStack(alignment: .leading, spacing: PutioTheme.Spacing.space1) {
          Text(title)
            .putioFont(PutioAlertMetrics.title)
            .foregroundStyle(PutioTheme.Colors.textPrimary)
            .accessibilityAddTraits(.isHeader)
          if let message {
            Text(message)
              .putioFont(PutioTheme.Typography.caption)
              .foregroundStyle(PutioTheme.Colors.textSecondary)
          }
        }
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, PutioTheme.Spacing.space2)
        PutioAlertButtonsLayout(spacing: PutioTheme.Spacing.space2) {
          ForEach(ordered) { action in
            Button(action.title) { dismiss(choosing: action) }
              .buttonStyle(PutioAlertButtonStyle(tier: action.tier))
              .accessibilityIdentifier(action.accessibilityIdentifier)
          }
        }
      }
      .padding(.top, PutioTheme.Spacing.space3 + PutioTheme.Spacing.space1)
      .padding([.horizontal, .bottom], PutioTheme.Spacing.space3)
      .background(
        PutioTheme.Colors.surfaceActive,
        in: RoundedRectangle(cornerRadius: PutioAlertMetrics.cornerRadius)
      )
      .overlay(
        RoundedRectangle(cornerRadius: PutioAlertMetrics.cornerRadius)
          .strokeBorder(PutioTheme.Components.Sheet.border, lineWidth: PutioTheme.Border.width)
      )
      .accessibilityElement(children: .contain)
      .accessibilityLabel(title)
      .accessibilityIdentifier("putio-alert")
      .accessibilityAddTraits(.isModal)
      .accessibilityAction(.escape) {
        if let escape { dismiss(choosing: escape) }
      }
    }

    private var escape: PutioAlertAction? {
      actions.first { $0.tier == .cancel } ?? (actions.count == 1 ? actions.first : nil)
    }

    private var ordered: [PutioAlertAction] {
      actions.filter { $0.tier == .cancel } + actions.filter { $0.tier != .cancel }
    }

    private func dismiss(choosing action: PutioAlertAction) {
      withAnimation(.easeIn(duration: PutioTheme.Motion.durationFast)) {
        appeared = false
      } completion: {
        choose(action)
      }
    }
  }

  enum PutioAlertMetrics {
    static let width = PutioMetricRole(value: 302, relativeTo: .body)
    static let buttonHeight = PutioMetricRole(value: 48, relativeTo: .body)
    static let cornerRadius = PutioTheme.Spacing.space4
    static let title = PutioFontRole(
      fontName: PutioTheme.Typography.heading.fontName,
      size: PutioTheme.Typography.sizeMd,
      lineHeight: PutioTheme.Typography.subheading.lineHeight,
      textStyle: .headline
    )
    static let label = PutioFontRole(
      fontName: PutioTheme.Typography.heading.fontName,
      size: PutioTheme.Typography.sizeBase,
      lineHeight: PutioTheme.Components.Button.label.lineHeight,
      textStyle: .body
    )
  }

  struct PutioAlertButtonStyle: ButtonStyle {
    let tier: PutioAlertAction.Tier
    @PutioScaledMetric private var height: CGFloat

    init(tier: PutioAlertAction.Tier) {
      self.tier = tier
      _height = PutioScaledMetric(PutioAlertMetrics.buttonHeight)
    }

    func makeBody(configuration: Configuration) -> some View {
      configuration.label
        .putioFont(PutioAlertMetrics.label)
        .multilineTextAlignment(.center)
        .foregroundStyle(foreground)
        .padding(.horizontal, PutioTheme.Spacing.space3)
        .padding(.vertical, PutioTheme.Spacing.space2)
        .frame(maxWidth: .infinity, minHeight: height)
        .background(configuration.isPressed ? pressedFill : fill, in: Capsule())
        .contentShape(Capsule())
    }

    var foreground: Color {
      switch tier {
      case .cancel, .neutral: PutioTheme.Colors.textPrimary
      case .primary: PutioTheme.Components.Button.primaryForeground
      case .destructive: PutioTheme.Colors.background
      }
    }

    var fill: Color {
      switch tier {
      case .cancel, .neutral: PutioTheme.Colors.textPrimary.opacity(0.1)
      case .primary: PutioTheme.Components.Button.primaryBackground
      case .destructive: PutioTheme.Components.Button.dangerBackground
      }
    }

    private var pressedFill: Color {
      switch tier {
      case .cancel, .neutral: PutioTheme.Colors.textPrimary.opacity(0.2)
      case .primary: PutioTheme.Components.Button.primaryBackgroundPressed
      case .destructive: PutioTheme.Components.Button.dangerBackgroundPressed
      }
    }
  }

  struct PutioAlertButtonsLayout: Layout {
    let spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
      let width = proposal.width ?? idealRowWidth(subviews)
      if fitsRow(width: width, subviews: subviews) {
        let column = columnWidth(width, count: subviews.count)
        let proposal = ProposedViewSize(width: column, height: nil)
        let height = subviews.map { $0.sizeThatFits(proposal).height }.max() ?? 0
        return CGSize(width: width, height: height)
      }
      let proposal = ProposedViewSize(width: width, height: nil)
      let heights = subviews.map { $0.sizeThatFits(proposal).height }
      return CGSize(
        width: width,
        height: heights.reduce(0, +) + spacing * CGFloat(max(subviews.count - 1, 0)))
    }

    func placeSubviews(
      in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()
    ) {
      if fitsRow(width: bounds.width, subviews: subviews) {
        let column = columnWidth(bounds.width, count: subviews.count)
        var x = bounds.minX
        for subview in subviews {
          subview.place(
            at: CGPoint(x: x, y: bounds.minY), anchor: .topLeading,
            proposal: ProposedViewSize(width: column, height: bounds.height))
          x += column + spacing
        }
        return
      }
      var y = bounds.minY
      for subview in subviews.reversed() {
        let proposal = ProposedViewSize(width: bounds.width, height: nil)
        let height = subview.sizeThatFits(proposal).height
        subview.place(at: CGPoint(x: bounds.minX, y: y), anchor: .topLeading, proposal: proposal)
        y += height + spacing
      }
    }

    private func columnWidth(_ width: CGFloat, count: Int) -> CGFloat {
      guard count > 0 else { return width }
      return (width - spacing * CGFloat(count - 1)) / CGFloat(count)
    }

    private func fitsRow(width: CGFloat, subviews: Subviews) -> Bool {
      let column = columnWidth(width, count: subviews.count)
      return subviews.allSatisfy { $0.sizeThatFits(.unspecified).width <= column }
    }

    private func idealRowWidth(_ subviews: Subviews) -> CGFloat {
      let widest = subviews.map { $0.sizeThatFits(.unspecified).width }.max() ?? 0
      return widest * CGFloat(subviews.count) + spacing * CGFloat(max(subviews.count - 1, 0))
    }
  }
#endif
