#if os(iOS)
  import SwiftUI

  public struct PutioListDetail<Item: Hashable, ListContent: View, DetailContent: View>: View {
    @Binding private var selection: Item?
    private let columns: PutioListDetailColumns
    private let emptyState: (title: String, message: String)?
    private let list: (Binding<Item?>) -> ListContent
    private let detail: (Item) -> DetailContent

    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @State private var retainedSelection: Item?
    @State private var columnVisibility = NavigationSplitViewVisibility.all

    public init(
      selection: Binding<Item?>,
      columns: PutioListDetailColumns = .standard,
      emptyTitle: String,
      emptyMessage: String,
      @ViewBuilder list: @escaping (Binding<Item?>) -> ListContent,
      @ViewBuilder detail: @escaping (Item) -> DetailContent
    ) {
      _selection = selection
      self.columns = columns
      self.emptyState = (emptyTitle, emptyMessage)
      self.list = list
      self.detail = detail
    }

    public init(
      selection: Binding<Item?>,
      columns: PutioListDetailColumns = .standard,
      @ViewBuilder list: @escaping (Binding<Item?>) -> ListContent,
      @ViewBuilder detail: @escaping (Item) -> DetailContent
    ) {
      _selection = selection
      self.columns = columns
      self.emptyState = nil
      self.list = list
      self.detail = detail
    }

    public var body: some View {
      NavigationSplitView(columnVisibility: $columnVisibility) {
        list(listSelection)
          .environment(\.putioListDetailSelection, selection.map(AnyHashable.init))
          .environment(\.putioListDetailShowsOpenRow, horizontalSizeClass == .regular)
          .environment(\.putioListDetailOpen, openAction)
          .overlay(alignment: .trailing) { divider }
          .background(PutioListColumnWidth(columns: columns))
          .toolbar(removing: .sidebarToggle)
      } detail: {
        detailColumn
          .background(PutioListColumnWidth(columns: columns))
      }
      .navigationSplitViewStyle(.balanced)
      .onChange(of: selection) { _, current in
        if let current {
          retainedSelection = current
        } else if horizontalSizeClass == .compact {
          retainedSelection = nil
        }
      }
      .onChange(of: horizontalSizeClass) { _, sizeClass in
        guard sizeClass == .regular else { return }
        columnVisibility = .all
        if selection == nil, let retainedSelection { selection = retainedSelection }
      }
    }

    @ViewBuilder private var divider: some View {
      if columns.showsDivider {
        PutioTheme.Colors.separator
          .frame(width: PutioListDetailLayout.dividerWidth)
          .ignoresSafeArea()
          .accessibilityHidden(true)
      }
    }

    @ViewBuilder private var detailColumn: some View {
      if let selection {
        NavigationStack {
          detail(selection)
        }
        .toolbar(.hidden, for: .navigationBar)
        .id(selection)
        .modifier(PutioListDetailReadableWidth(maxWidth: columns.detailMaxWidth))
      } else if let emptyState {
        PutioEmptyStateView.textOnly(
          title: emptyState.title, message: emptyState.message
        )
        .putioContentBackground()
        .accessibilityIdentifier("putio.list-detail.empty")
      } else {
        PutioTheme.Colors.background
          .ignoresSafeArea()
          .accessibilityIdentifier("putio.list-detail.empty")
      }
    }

    private var openAction: PutioListDetailOpenAction {
      let selection = listSelection
      return PutioListDetailOpenAction { item in
        guard let item = item.base as? Item else { return }
        selection.wrappedValue = item
      }
    }

    private var listSelection: Binding<Item?> {
      Binding(
        get: { selection },
        set: { newValue in
          if newValue == nil, horizontalSizeClass == .regular { return }
          selection = newValue
        })
    }
  }

  public enum PutioListDetailRowStyle: Sendable {
    case plain
    case grouped
  }

  extension View {
    public func putioListDetailRow<Item: Hashable>(
      _ item: Item, style: PutioListDetailRowStyle = .plain
    ) -> some View {
      modifier(PutioListDetailRow(item: AnyHashable(item), style: style))
        .tag(item)
    }
  }

  extension View {
    /// Marks `item` open for rows below a navigation push in the list column,
    /// which the environment set by `PutioListDetail` does not reach.
    public func putioListDetailOpenRow<Item: Hashable>(_ item: Item?) -> some View {
      environment(\.putioListDetailSelection, item.map(AnyHashable.init))
        .environment(\.putioListDetailShowsOpenRow, true)
    }
  }

  private struct PutioListDetailRow: ViewModifier {
    let item: AnyHashable
    let style: PutioListDetailRowStyle

    @Environment(\.putioListDetailSelection) private var selection
    @Environment(\.putioListDetailShowsOpenRow) private var showsOpenRow

    private var isOpen: Bool { selection == item }
    private var highlightsOpen: Bool { isOpen && showsOpenRow }

    func body(content: Content) -> some View {
      content
        .listRowBackground(background)
        .focusEffectDisabled(style == .grouped)
        .accessibilityAddTraits(isOpen ? .isSelected : [])
    }

    @ViewBuilder private var background: some View {
      switch style {
      case .plain: plainBackground
      case .grouped:
        highlightsOpen ? PutioTheme.Colors.surfaceActive : PutioTheme.Colors.surface
      }
    }

    @ViewBuilder private var plainBackground: some View {
      if highlightsOpen {
        RoundedRectangle(cornerRadius: PutioListDetailLayout.selectedRowRadius)
          .fill(PutioListDetailLayout.selectedRowTint)
          .padding(.horizontal, PutioListDetailLayout.selectedRowInset)
      } else {
        PutioTheme.Colors.background
      }
    }
  }

  extension EnvironmentValues {
    @Entry var putioListDetailSelection: AnyHashable? = nil
    @Entry var putioListDetailShowsOpenRow = false
  }

  public struct PutioListDetailColumns: Sendable {
    let listMinimumWidth: CGFloat
    let listIdealWidth: CGFloat
    let detailMaxWidth: CGFloat?
    let showsDivider: Bool

    public static let standard = PutioListDetailColumns(
      listMinimumWidth: PutioTheme.Spacing.space7 + PutioTheme.Spacing.space6,
      listIdealWidth: PutioTheme.Spacing.space7 + PutioTheme.Spacing.space6
        + PutioTheme.Spacing.space5,
      detailMaxWidth: nil,
      showsDivider: false)

    public static let readable = PutioListDetailColumns(
      listMinimumWidth: PutioTheme.Spacing.space7 + PutioTheme.Spacing.space6,
      listIdealWidth: PutioTheme.Spacing.space7 + PutioTheme.Spacing.space6
        + PutioTheme.Spacing.space4 + PutioTheme.Spacing.space1,
      detailMaxWidth: PutioTheme.Spacing.space8 + PutioTheme.Spacing.space5
        + PutioTheme.Spacing.space3 + PutioTheme.Spacing.space2,
      showsDivider: true)
  }

  private struct PutioListDetailReadableWidth: ViewModifier {
    let maxWidth: CGFloat?

    func body(content: Content) -> some View {
      if let maxWidth {
        content
          .background(PutioReadableColumnInsets(maxWidth: maxWidth))
          .background(PutioTheme.Colors.background)
      } else {
        content
      }
    }
  }

  private struct PutioReadableColumnInsets: UIViewControllerRepresentable {
    let maxWidth: CGFloat

    func makeUIViewController(context: Context) -> Controller { Controller(maxWidth: maxWidth) }
    func updateUIViewController(_ controller: Controller, context: Context) {}

    final class Controller: UIViewController {
      private let maxWidth: CGFloat

      init(maxWidth: CGFloat) {
        self.maxWidth = maxWidth
        super.init(nibName: nil, bundle: nil)
      }

      @available(*, unavailable)
      required init?(coder: NSCoder) { nil }

      override func viewWillLayoutSubviews() {
        super.viewWillLayoutSubviews()
        guard let column = navigationController else { return }
        let added = column.additionalSafeAreaInsets
        let safeArea = column.view.safeAreaInsets
        let width =
          column.view.bounds.width - (safeArea.left - added.left) - (safeArea.right - added.right)
        let inset = max(0, (width - maxWidth) / 2)
        guard
          column.additionalSafeAreaInsets.left != inset
            || column.additionalSafeAreaInsets.right != inset
        else { return }
        column.additionalSafeAreaInsets.left = inset
        column.additionalSafeAreaInsets.right = inset
      }
    }
  }

  private struct PutioListColumnWidth: UIViewControllerRepresentable {
    let columns: PutioListDetailColumns

    func makeUIViewController(context: Context) -> Controller { Controller(columns: columns) }
    func updateUIViewController(_ controller: Controller, context: Context) {}

    final class Controller: UIViewController {
      private let columns: PutioListDetailColumns

      init(columns: PutioListDetailColumns) {
        self.columns = columns
        super.init(nibName: nil, bundle: nil)
      }

      @available(*, unavailable)
      required init?(coder: NSCoder) { nil }

      override func viewWillLayoutSubviews() {
        super.viewWillLayoutSubviews()
        guard let split = splitViewController,
          split.minimumPrimaryColumnWidth != columns.listMinimumWidth
            || split.preferredPrimaryColumnWidth != columns.listIdealWidth
        else { return }
        split.minimumPrimaryColumnWidth = columns.listMinimumWidth
        split.preferredPrimaryColumnWidth = columns.listIdealWidth
      }
    }
  }

  enum PutioListDetailLayout {
    static let dividerWidth: CGFloat = 0.5
    static let selectedRowTint = PutioTheme.Colors.accent.opacity(0.14)
    static let selectedRowRadius = PutioTheme.Radius.large
    static let selectedRowInset = PutioTheme.Spacing.space2
  }
#endif
