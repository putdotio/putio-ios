import SwiftUI

public struct PutioSelection<ID: Hashable & Sendable>: Equatable, Sendable {
  public enum Coverage: Equatable, Sendable {
    case none
    case some
    case all
  }

  public private(set) var isActive: Bool
  public private(set) var selectedIDs: Set<ID>

  public init(isActive: Bool = false, selectedIDs: Set<ID> = []) {
    self.isActive = isActive
    self.selectedIDs = isActive ? selectedIDs : []
  }

  public var count: Int { selectedIDs.count }

  public func contains(_ id: ID) -> Bool {
    selectedIDs.contains(id)
  }

  public func coverage(among ids: some Collection<ID>) -> Coverage {
    let selected = ids.filter(selectedIDs.contains).count
    if selected == 0 { return .none }
    return selected == ids.count ? .all : .some
  }

  public mutating func begin() {
    isActive = true
  }

  public mutating func end() {
    isActive = false
    selectedIDs = []
  }

  public mutating func toggle(_ id: ID) {
    guard isActive else { return }
    if selectedIDs.remove(id) == nil { selectedIDs.insert(id) }
  }

  public mutating func selectAll(among ids: some Collection<ID>) {
    guard isActive else { return }
    selectedIDs = Set(ids)
  }

  public mutating func retain(_ ids: some Collection<ID>) {
    selectedIDs.formIntersection(ids)
  }
}

public struct PutioSelectionAction: Identifiable {
  public let id: String
  public let title: String
  public let icon: PutioIcon
  public let isDestructive: Bool
  public let isDisabled: Bool
  let perform: @MainActor () -> Void

  public init(
    id: String,
    title: String,
    icon: PutioIcon,
    isDestructive: Bool = false,
    isDisabled: Bool = false,
    perform: @escaping @MainActor () -> Void
  ) {
    self.id = id
    self.title = title
    self.icon = icon
    self.isDestructive = isDestructive
    self.isDisabled = isDisabled
    self.perform = perform
  }
}

public struct PutioSelectionBarLayout<Action> {
  public let visible: [Action]
  public let overflow: [Action]

  public init(_ actions: [Action], limit: Int = 4) {
    guard actions.count > limit, limit > 0 else {
      visible = actions
      overflow = []
      return
    }
    visible = Array(actions.prefix(limit - 1))
    overflow = Array(actions.dropFirst(limit - 1))
  }
}

extension EnvironmentValues {
  @Entry public var putioIsSelecting = false
}

extension View {
  public func putioRowActions<Swipe: View, Menu: View>(
    @ViewBuilder swipe: () -> Swipe,
    @ViewBuilder menu: () -> Menu
  ) -> some View {
    modifier(PutioRowActions(swipe: swipe(), menu: menu()))
  }
}

private struct PutioRowActions<Swipe: View, Menu: View>: ViewModifier {
  let swipe: Swipe
  let menu: Menu
  @Environment(\.putioIsSelecting) private var isSelecting

  @ViewBuilder func body(content: Content) -> some View {
    if isSelecting {
      content
    } else {
      #if os(tvOS)
        content.contextMenu { menu }
      #else
        content
          .swipeActions(edge: .trailing) { swipe }
          .contextMenu { menu }
      #endif
    }
  }
}

#if os(iOS)
  public struct PutioSelectableRow<Content: View>: View {
    private let isSelected: Bool
    private let toggle: () -> Void
    private let content: Content

    @PutioScaledMetric private var checkSize: CGFloat
    @PutioScaledMetric private var contentGap: CGFloat

    public init(
      isSelected: Bool,
      toggle: @escaping () -> Void,
      @ViewBuilder content: () -> Content
    ) {
      self.isSelected = isSelected
      self.toggle = toggle
      self.content = content()
      _checkSize = PutioScaledMetric(PutioSelectionLayout.checkSize)
      _contentGap = PutioScaledMetric(PutioTheme.ScaledMetrics.contentGap)
    }

    public var body: some View {
      Button(action: toggle) {
        HStack(spacing: contentGap) {
          Image(putioIcon: isSelected ? .checkCircleFill : .circle)
            .resizable()
            .scaledToFit()
            .frame(width: checkSize, height: checkSize)
            .foregroundStyle(
              isSelected ? PutioTheme.Colors.accent : PutioSelectionLayout.uncheckedColor
            )
            .accessibilityHidden(true)
          content
        }
        .contentShape(.rect)
      }
      .buttonStyle(.plain)
      .environment(\.putioIsSelecting, true)
      .listRowBackground(
        isSelected ? PutioSelectionLayout.selectedRowBackground : PutioTheme.Colors.background
      )
      .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
  }

  extension View {
    public func putioSelectionMode<ID: Hashable & Sendable>(
      _ selection: Binding<PutioSelection<ID>>,
      among ids: [ID],
      actions: [PutioSelectionAction],
      isBusy: Bool = false
    ) -> some View {
      modifier(
        PutioSelectionMode(selection: selection, ids: ids, actions: actions, isBusy: isBusy))
    }
  }

  private struct PutioSelectionMode<ID: Hashable & Sendable>: ViewModifier {
    @Binding var selection: PutioSelection<ID>
    let ids: [ID]
    let actions: [PutioSelectionAction]
    let isBusy: Bool
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    func body(content: Content) -> some View {
      content
        .environment(\.putioIsSelecting, selection.isActive)
        .navigationBarBackButtonHidden(selection.isActive)
        .toolbar {
          if selection.isActive {
            PutioSelectionHeader(selection: $selection, ids: ids, isBusy: isBusy)
          }
        }
        .toolbarVisibility(hidesTabBar ? .hidden : .automatic, for: .tabBar)
        .safeAreaInset(edge: .bottom) {
          if selection.isActive {
            PutioSelectionBar(actions: actions)
              .disabled(selection.count == 0 || isBusy)
          }
        }
        .onChange(of: ids) { _, current in
          guard !isBusy else { return }
          selection.retain(current)
        }
        .onDisappear {
          selection.end()
        }
    }

    private var hidesTabBar: Bool {
      selection.isActive && horizontalSizeClass == .compact
    }
  }

  private struct PutioSelectionHeader<ID: Hashable & Sendable>: ToolbarContent {
    @Binding var selection: PutioSelection<ID>
    let ids: [ID]
    let isBusy: Bool

    var body: some ToolbarContent {
      ToolbarItem(placement: .topBarLeading) {
        Button {
          selection.end()
        } label: {
          Image(putioIcon: .x)
        }
        .disabled(isBusy)
        .accessibilityLabel(Text("Done selecting", bundle: .module))
        .tint(PutioTheme.Colors.textPrimary)
        .accessibilityIdentifier("selection.close")
      }
      ToolbarItem(placement: .principal) {
        Text("\(selection.count) selected", bundle: .module)
          .putioFont(PutioSelectionLayout.titleFont)
          .foregroundStyle(PutioTheme.Colors.textPrimary)
          .accessibilityIdentifier("selection.count")
      }
      ToolbarItem(placement: .topBarTrailing) {
        Button {
          selection.selectAll(among: ids)
        } label: {
          Text("Select all", bundle: .module)
        }
        .disabled(ids.isEmpty || isBusy)
        .tint(PutioTheme.Colors.textPrimary)
        .accessibilityIdentifier("selection.toggle-all")
      }
    }
  }

  private struct PutioSelectionBar: View {
    let actions: [PutioSelectionAction]

    var body: some View {
      let layout = PutioSelectionBarLayout(actions)
      HStack(spacing: 0) {
        ForEach(layout.visible) { action in
          Button(action: action.perform) {
            PutioSelectionBarItem(
              title: action.title, icon: action.icon, isDestructive: action.isDestructive)
          }
          .buttonStyle(.plain)
          .disabled(action.isDisabled)
          .accessibilityIdentifier("selection.action.\(action.id)")
        }
        if !layout.overflow.isEmpty {
          Menu {
            ForEach(layout.overflow) { action in
              Button(role: action.isDestructive ? .destructive : nil, action: action.perform) {
                Label {
                  Text(action.title)
                } icon: {
                  Image(putioIcon: action.icon)
                }
              }
              .disabled(action.isDisabled)
            }
          } label: {
            PutioSelectionBarItem(
              title: String(localized: "More", bundle: .module), icon: .dotsThreeCircle,
              isDestructive: false)
          }
          .accessibilityIdentifier("selection.action.more")
        }
      }
      .padding(.vertical, PutioSelectionLayout.barVerticalPadding)
      .padding(.horizontal, PutioSelectionLayout.barHorizontalPadding)
      .modifier(PutioSelectionBarSurface())
      .padding(.horizontal, PutioSelectionLayout.barInset)
      .padding(.bottom, PutioSelectionLayout.barBottomInset)
      .accessibilityElement(children: .contain)
      .accessibilityIdentifier("selection.bar")
    }
  }

  private struct PutioSelectionBarItem: View {
    let title: String
    let icon: PutioIcon
    let isDestructive: Bool
    @Environment(\.isEnabled) private var isEnabled
    @PutioScaledMetric private var iconSize: CGFloat
    @PutioScaledMetric private var gap: CGFloat

    init(title: String, icon: PutioIcon, isDestructive: Bool) {
      self.title = title
      self.icon = icon
      self.isDestructive = isDestructive
      _iconSize = PutioScaledMetric(PutioSelectionLayout.barIconSize)
      _gap = PutioScaledMetric(PutioTheme.ScaledMetrics.compactContentGap)
    }

    var body: some View {
      VStack(spacing: gap) {
        Image(putioIcon: icon)
          .resizable()
          .scaledToFit()
          .frame(width: iconSize, height: iconSize)
        Text(title)
          .putioFont(PutioSelectionLayout.barLabelFont)
          .lineLimit(1)
          .minimumScaleFactor(PutioSelectionLayout.barLabelMinimumScale)
      }
      .foregroundStyle(isDestructive ? Color.red : PutioTheme.Colors.textPrimary)
      .opacity(isEnabled ? 1 : PutioSelectionLayout.disabledOpacity)
      .frame(maxWidth: .infinity, minHeight: PutioSelectionLayout.barItemMinHeight)
      .contentShape(.rect)
    }
  }

  private struct PutioSelectionBarSurface: ViewModifier {
    @ViewBuilder func body(content: Content) -> some View {
      if HarnessRendering.usesRasterFallback {
        content.background(.regularMaterial, in: .capsule)
      } else {
        content.glassEffect(.regular, in: .capsule)
      }
    }
  }

  enum PutioSelectionLayout {
    static let checkSize = PutioMetricRole(value: PutioTheme.Typography.sizeLg, relativeTo: .body)
    static let uncheckedColor = PutioTheme.Colors.textSecondary
    static let selectedRowBackground = PutioTheme.Colors.accent.opacity(0.12)
    static let titleFont = PutioTheme.Typography.subheading
    static let barIconSize = PutioMetricRole(
      value: PutioTheme.Typography.sizeLg, relativeTo: .caption)
    static let barLabelFont = PutioTheme.Typography.caption
    static let barLabelMinimumScale = 0.8
    static let barItemMinHeight: CGFloat = 44
    static let barVerticalPadding = PutioTheme.Spacing.space2
    static let barHorizontalPadding = PutioTheme.Spacing.space2
    static let barInset = PutioTheme.Spacing.space3
    static let barBottomInset = PutioTheme.Spacing.space2
    static let disabledOpacity = 0.4
  }
#endif
