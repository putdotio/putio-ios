#if os(iOS)
  import SwiftUI

  public struct PutioListDetail<Item: Hashable, ListContent: View, DetailContent: View>: View {
    @Binding private var selection: Item?
    private let emptyTitle: String
    private let emptyMessage: String
    private let list: (Binding<Item?>) -> ListContent
    private let detail: (Item) -> DetailContent

    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @State private var retainedSelection: Item?
    @State private var columnVisibility = NavigationSplitViewVisibility.all

    public init(
      selection: Binding<Item?>,
      emptyTitle: String,
      emptyMessage: String,
      @ViewBuilder list: @escaping (Binding<Item?>) -> ListContent,
      @ViewBuilder detail: @escaping (Item) -> DetailContent
    ) {
      _selection = selection
      self.emptyTitle = emptyTitle
      self.emptyMessage = emptyMessage
      self.list = list
      self.detail = detail
    }

    public var body: some View {
      NavigationSplitView(columnVisibility: $columnVisibility) {
        list(listSelection)
          .environment(\.putioListDetailSelection, selection.map(AnyHashable.init))
          .navigationSplitViewColumnWidth(
            min: PutioListDetailLayout.listMinimumWidth,
            ideal: PutioListDetailLayout.listIdealWidth)
          .toolbar(removing: .sidebarToggle)
      } detail: {
        if let selection {
          NavigationStack {
            detail(selection)
          }
          .id(selection)
        } else {
          PutioEmptyStateView.detailPlaceholder(title: emptyTitle, message: emptyMessage)
            .putioContentBackground()
            .accessibilityIdentifier("putio.list-detail.empty")
        }
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

    private var listSelection: Binding<Item?> {
      Binding(
        get: { selection },
        set: { newValue in
          if newValue == nil, horizontalSizeClass == .regular { return }
          selection = newValue
        })
    }
  }

  extension View {
    public func putioListDetailRow<Item: Hashable>(_ item: Item) -> some View {
      modifier(PutioListDetailRow(item: AnyHashable(item)))
        .tag(item)
    }
  }

  private struct PutioListDetailRow: ViewModifier {
    let item: AnyHashable

    @Environment(\.putioListDetailSelection) private var selection
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    private var isOpen: Bool { selection == item }

    func body(content: Content) -> some View {
      content
        .listRowBackground(background)
        .accessibilityAddTraits(isOpen ? .isSelected : [])
    }

    @ViewBuilder private var background: some View {
      if isOpen, horizontalSizeClass == .regular {
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
  }

  enum PutioListDetailLayout {
    static let listMinimumWidth = PutioTheme.Spacing.space7 + PutioTheme.Spacing.space5
    static let listIdealWidth = PutioTheme.Spacing.space7 + PutioTheme.Spacing.space6
    static let selectedRowTint = PutioTheme.Colors.accent.opacity(0.14)
    static let selectedRowRadius = PutioTheme.Radius.large
    static let selectedRowInset = PutioTheme.Spacing.space2
  }
#endif
