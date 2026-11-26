import PutioCore
import SwiftUI

enum TVMoveResult: Equatable {
  case closed
  case nameTaken(String)
}

/// Where the Move sheet lists folders from.
struct TVMoveSource {
  let load: PutioFolderLoad
  let continueLoad: PutioFolderContinue?

  init(load: @escaping PutioFolderLoad, continueLoad: PutioFolderContinue?) {
    self.load = load
    self.continueLoad = continueLoad
  }

  init(runtime: PutioRuntime) {
    self.init(
      load: { try await runtime.listFolders(parentID: $0) },
      continueLoad: { try await runtime.continueFolders(cursor: $0) })
  }
}

extension View {
  /// Presents the Move sheet over the screen for `item`; it closes when the
  /// binding clears, and `dismissed` hands focus back to the screen.
  func tvMoveSheet(
    _ item: Binding<PutioFileItem?>, source: TVMoveSource?,
    move: @escaping @MainActor (PutioFileItem, PutioFolderRoute) async -> TVMoveResult,
    dismissed: @escaping () -> Void
  ) -> some View {
    fullScreenCover(item: item, onDismiss: dismissed) { moving in
      if let source {
        TVMoveSheet(
          item: moving, load: source.load, continueLoad: source.continueLoad,
          move: { await move(moving, $0) },
          close: { item.wrappedValue = nil })
      }
    }
  }
}

/// Chooses a destination folder for one item, from Your files down. Back
/// goes up one folder and closes the sheet at Your files.
struct TVMoveSheet: View {
  let item: PutioFileItem
  let move: @MainActor (PutioFolderRoute) async -> TVMoveResult
  let close: () -> Void

  @State private var levels: [Level]
  @State private var isMoving = false
  @State private var takenName: String?
  @FocusState private var focus: Target?
  private let load: PutioFolderLoad
  private let continueLoad: PutioFolderContinue?
  private let loadsOnAppear: Bool

  init(
    item: PutioFileItem, load: @escaping PutioFolderLoad, continueLoad: PutioFolderContinue?,
    move: @escaping @MainActor (PutioFolderRoute) async -> TVMoveResult,
    close: @escaping () -> Void
  ) {
    self.init(
      item: item, levels: [Level(route: .root, load: load, continueLoad: continueLoad)],
      load: load, continueLoad: continueLoad, loadsOnAppear: true, move: move, close: close)
  }

  /// `loadsOnAppear: false` keeps already loaded levels as they are, for
  /// rendering a fixed state.
  init(
    item: PutioFileItem, levels: [Level], load: @escaping PutioFolderLoad,
    continueLoad: PutioFolderContinue?, loadsOnAppear: Bool,
    move: @escaping @MainActor (PutioFolderRoute) async -> TVMoveResult,
    close: @escaping () -> Void
  ) {
    self.item = item
    self.load = load
    self.continueLoad = continueLoad
    self.loadsOnAppear = loadsOnAppear
    self.move = move
    self.close = close
    _levels = State(initialValue: levels)
  }

  @MainActor
  struct Level {
    let route: PutioFolderRoute
    let model: PutioFolderModel
    /// The folder row to focus when this level shows again.
    var remembered: PutioFileID?

    var id: PutioFileID { route.id }

    init(route: PutioFolderRoute, model: PutioFolderModel) {
      self.route = route
      self.model = model
    }

    init(
      route: PutioFolderRoute, load: @escaping PutioFolderLoad, continueLoad: PutioFolderContinue?
    ) {
      self.init(
        route: route,
        model: PutioFolderModel(folderID: route.id, load: load, continueLoad: continueLoad))
    }
  }

  enum Target: Hashable {
    case folder(PutioFileID)
    case moveHere
    case more
    case anchor
  }

  private var level: Level { levels[levels.count - 1] }
  private var model: PutioFolderModel { level.model }
  private var policy: PutioMovePickerPolicy { PutioMovePickerPolicy(items: [item]) }
  private var path: [PutioFolderRoute] { levels.dropFirst().map(\.route) }

  private var canMove: Bool {
    !isMoving && model.isLoaded && policy.state(along: path) == .available
  }

  var body: some View {
    ZStack(alignment: .trailing) {
      Color.black.opacity(TVMoveSheetLayout.scrimOpacity)
        .accessibilityHidden(true)
      // Holds focus while nothing in the sheet can, so Back still reaches
      // the sheet instead of dismissing it mid-move.
      Color.clear
        .frame(width: 1, height: 1)
        .tvFocusAnchor(isMoving || settledTarget == .anchor)
        .focused($focus, equals: .anchor)
        .accessibilityHidden(true)
      sheet
    }
    .ignoresSafeArea()
    .presentationBackground(.clear)
    .onExitCommand(perform: back)
    .task(id: FocusRequest(level: level.id, phase: phase)) {
      await Task.yield()
      if let target = settledTarget { focus = target }
    }
    .task(id: level.id) {
      guard loadsOnAppear else { return }
      await model.loadIfNeeded()
    }
  }

  private var sheet: some View {
    VStack(alignment: .leading, spacing: 0) {
      header
      location
        .padding(.top, TVMoveSheetLayout.locationGap)
      content
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .padding(.top, TVMoveSheetLayout.listGap)
      if let takenName {
        Text(TVMoveCopy.nameTaken(takenName))
          .putioFont(PutioTVTypeScale.caption)
          .foregroundStyle(PutioTheme.Colors.destructiveText)
          .fixedSize(horizontal: false, vertical: true)
          .accessibilityIdentifier("files.move-name-taken")
      }
      Button(action: moveHere) {
        Text(TVMoveCopy.moveHere)
      }
      .buttonStyle(TVMoveHereButtonStyle())
      .disabled(!canMove)
      .focused($focus, equals: .moveHere)
      .padding(.top, TVMoveSheetLayout.moveHereGap)
      .accessibilityIdentifier("files.move-here")
    }
    .padding(.top, TVMoveSheetLayout.topPadding)
    .padding(.leading, TVMoveSheetLayout.leadingPadding)
    .padding(.trailing, TVMoveSheetLayout.trailingPadding)
    .padding(.bottom, TVMoveSheetLayout.bottomPadding)
    .frame(width: TVMoveSheetLayout.width)
    .frame(maxHeight: .infinity)
    .background {
      UnevenRoundedRectangle(
        topLeadingRadius: TVMoveSheetLayout.radius, bottomLeadingRadius: TVMoveSheetLayout.radius,
        style: .continuous
      )
      .fill(PutioTheme.Components.Sheet.background)
      .shadow(
        color: .black.opacity(TVMoveSheetLayout.shadowOpacity),
        radius: TVMoveSheetLayout.shadowRadius, x: -TVMoveSheetLayout.shadowOffset
      )
    }
    .focusSection()
    .disabled(isMoving)
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("files.move-sheet")
  }

  private var header: some View {
    HStack(spacing: TVMoveSheetLayout.contentGap) {
      Image(putioIcon: PutioBrowserItemPresentation(item: item).row.kind.icon)
        .resizable()
        .scaledToFit()
        .frame(width: TVDetailPanelLayout.tileIconSize, height: TVDetailPanelLayout.tileIconSize)
        .foregroundStyle(PutioTheme.Colors.accent)
        .frame(width: TVDetailPanelLayout.tileWidth, height: TVDetailPanelLayout.tileHeight)
        .background(
          PutioTheme.Colors.surfaceActive,
          in: RoundedRectangle(cornerRadius: PutioTheme.TV.radius, style: .continuous)
        )
        .accessibilityHidden(true)
      VStack(alignment: .leading, spacing: PutioTheme.TV.Spacing.xxs) {
        Text(TVMoveCopy.title)
          .putioFont(PutioTVTypeScale.panelTitle)
          .foregroundStyle(PutioTheme.TV.Colors.textPrimary)
          .accessibilityAddTraits(.isHeader)
        Text(item.name)
          .putioFont(PutioTVTypeScale.caption)
          .foregroundStyle(PutioTheme.TV.Colors.textSecondary)
          .lineLimit(1)
          .truncationMode(.middle)
      }
    }
  }

  private var location: some View {
    HStack(spacing: PutioTheme.TV.Spacing.xs) {
      Image(putioIcon: .folder)
        .resizable()
        .scaledToFit()
        .frame(width: TVRowLayout.disclosureSize, height: TVRowLayout.disclosureSize)
        .accessibilityHidden(true)
      TVMovePath(titles: levels.map { $0.route.title(root: TVFolderCopy.yourFiles) })
    }
    .putioFont(PutioTVTypeScale.caption)
    .foregroundStyle(PutioTheme.TV.Colors.textSecondary)
    .lineLimit(1)
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(
      levels.map { $0.route.title(root: TVFolderCopy.yourFiles) }.joined(separator: " / ")
    )
    .accessibilityIdentifier("files.move-path")
  }

  @ViewBuilder
  private var content: some View {
    switch model.state {
    case .loading:
      PutioLoadingStateView(title: TVMoveCopy.loading, titleVisibility: .hidden)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    case .failed:
      PutioEmptyStateView(
        kaomoji: .uneasy, title: TVMoveCopy.loadFailed,
        message: String(
          localized: "Check your internet connection and try again.", bundle: .putioCore),
        actionTitle: String(localized: "Try again", bundle: .putioCore),
        actionIcon: .arrowsClockwise, actionIdentifier: "files.move-retry"
      ) {
        Task { await model.retry() }
      }
      .compact()
      .frame(maxWidth: .infinity, maxHeight: .infinity)
    case .loaded(let contents):
      let folders = PutioMovePickerPolicy.folders(in: contents)
      if folders.isEmpty, contents.nextCursor == nil {
        PutioEmptyStateView(
          kaomoji: .emptyFolder, title: TVMoveCopy.emptyTitle, message: TVMoveCopy.emptyMessage
        )
        .compact()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityIdentifier("files.move-empty")
      } else {
        list(folders, hasMore: contents.nextCursor != nil)
      }
    }
  }

  private func list(_ folders: [PutioFileItem], hasMore: Bool) -> some View {
    ScrollView {
      LazyVStack(alignment: .leading, spacing: PutioTheme.TV.Spacing.xxs) {
        ForEach(folders) { folder in
          switch policy.row(for: folder) {
          case .destination:
            Button {
              open(folder)
            } label: {
              TVMoveFolderLabel(name: folder.name, opens: true)
            }
            .focused($focus, equals: .folder(folder.id))
            .accessibilityIdentifier("files.move-folder.\(folder.id.rawValue)")
          case .currentFolder:
            Button {
              open(folder)
            } label: {
              TVMoveFolderLabel(name: folder.name, opens: true, note: TVMoveCopy.hereNow)
            }
            .focused($focus, equals: .folder(folder.id))
            .accessibilityIdentifier("files.move-current.\(folder.id.rawValue)")
          case .movedItem:
            TVMoveFolderLabel(name: folder.name)
              .accessibilityElement(children: .combine)
              .accessibilityIdentifier("files.move-moving.\(folder.id.rawValue)")
          }
        }
        if hasMore { more(after: folders.last?.id) }
      }
      .padding(.vertical, PutioTheme.TV.Spacing.xs)
    }
    .padding(.horizontal, -TVMoveSheetLayout.rowOutset)
    .scrollClipDisabled()
    .buttonStyle(TVRowButtonStyle())
  }

  @ViewBuilder
  private func more(after last: PutioFileID?) -> some View {
    HStack {
      Spacer()
      if model.isLoadingMore {
        ProgressView()
          .accessibilityLabel(TVMoveCopy.loadingMore)
      } else {
        PutioButton(
          model.loadMoreFailure == nil
            ? TVMoveCopy.more : String(localized: "Try again", bundle: .putioCore),
          tier: .secondary
        ) {
          Task { await loadMore(after: last) }
        }
        .fixedSize()
        .focused($focus, equals: .more)
        .accessibilityIdentifier("files.move-more")
      }
      Spacer()
    }
    .padding(.vertical, PutioTheme.TV.Spacing.xs)
    .focusSection()
  }

  private enum Phase: Hashable {
    case loading
    case failed
    case loaded
  }

  private struct FocusRequest: Hashable {
    let level: PutioFileID
    let phase: Phase
  }

  private var phase: Phase {
    switch model.state {
    case .loading: .loading
    case .failed: .failed
    case .loaded: .loaded
    }
  }

  private var openableFolders: [PutioFileID] {
    guard case .loaded(let contents) = model.state else { return [] }
    let folders = PutioMovePickerPolicy.folders(in: contents)
    let rows = folders.map { ($0.id, policy.row(for: $0)) }
    return rows.filter { $0.1 == .destination }.map(\.0)
      + rows.filter { $0.1 == .currentFolder }.map(\.0)
  }

  /// The row this level was left from, the first destination, the items'
  /// own folder, or Move here. A
  /// failed level leaves focus to its one control, Try again.
  private var settledTarget: Target? {
    switch phase {
    case .loading: return .anchor
    case .failed: return nil
    case .loaded:
      let folders = openableFolders
      if let remembered = level.remembered, folders.contains(remembered) {
        return .folder(remembered)
      }
      if let first = folders.first { return .folder(first) }
      if case .loaded(let contents) = model.state, contents.nextCursor != nil { return .more }
      return canMove ? .moveHere : .anchor
    }
  }

  private func open(_ folder: PutioFileItem) {
    guard !isMoving else { return }
    levels[levels.count - 1].remembered = folder.id
    takenName = nil
    levels.append(
      Level(
        route: PutioFolderRoute(id: folder.id, title: folder.name), load: load,
        continueLoad: continueLoad))
  }

  private func back() {
    guard !isMoving else { return }
    takenName = nil
    guard levels.count > 1 else { return close() }
    levels.removeLast()
    if let target = settledTarget { focus = target }
  }

  /// The next page's first folder takes focus from the button it replaced,
  /// or the last listed folder when the page added none.
  private func loadMore(after last: PutioFileID?) async {
    let loading = model
    let before = Set(openableFolders)
    guard await loading.loadMore(), loading === model else { return }
    guard case .loaded(let contents) = model.state, contents.nextCursor == nil || focus == nil
    else { return }
    if let next = openableFolders.first(where: { !before.contains($0) }) {
      focus = .folder(next)
    } else if let last {
      focus = .folder(last)
    }
  }

  private func moveHere() {
    guard canMove else { return }
    let destination = level.route.titled(root: TVFolderCopy.yourFiles)
    takenName = nil
    isMoving = true
    focus = .anchor
    Task {
      let result = await move(destination)
      isMoving = false
      if case .nameTaken(let name) = result {
        takenName = name
        focus = .moveHere
      }
    }
  }
}

extension PutioFolderRoute {
  fileprivate func title(root: String) -> String {
    id == .root ? root : title
  }

  fileprivate func titled(root: String) -> PutioFolderRoute {
    PutioFolderRoute(id: id, title: title(root: root))
  }
}

private struct TVMovePath: View {
  let titles: [String]

  private var ancestors: [String] { Array(titles.dropLast()) }

  var body: some View {
    ViewThatFits(in: .horizontal) {
      ForEach(0..<max(ancestors.count, 1), id: \.self) { dropped in
        line(dropping: dropped)
      }
    }
  }

  private func line(dropping dropped: Int) -> some View {
    HStack(spacing: 0) {
      if dropped > 0 {
        Text(verbatim: "… / ")
          .fixedSize()
      }
      ForEach(Array(ancestors.enumerated().dropFirst(dropped)), id: \.offset) { index, title in
        ZStack(alignment: .leading) {
          Text(verbatim: "…")
            .fixedSize()
            .hidden()
          Text(title)
            .truncationMode(.tail)
        }
        .layoutPriority(Double(index))
        Text(verbatim: " / ")
          .fixedSize()
      }
      Text(titles.last ?? "")
        .fontWeight(.medium)
        .foregroundStyle(PutioTheme.TV.Colors.textPrimary)
        .truncationMode(.tail)
        .layoutPriority(Double(titles.count))
    }
  }
}

private struct TVMoveFolderLabel: View {
  let name: String
  var opens = false
  var note: String?

  @Environment(\.putioTVRowState) private var state

  private var isDimmed: Bool { !opens || note != nil }

  var body: some View {
    HStack(spacing: TVMoveSheetLayout.contentGap) {
      Image(putioIcon: .folderFill)
        .resizable()
        .scaledToFit()
        .frame(width: TVMoveSheetLayout.folderIconSize, height: TVMoveSheetLayout.folderIconSize)
        .foregroundStyle(
          isDimmed ? AnyShapeStyle(.putioRowSecondary) : AnyShapeStyle(.putioRowIcon)
        )
        .accessibilityHidden(true)
      Text(name)
        .putioFont(PutioTVTypeScale.rowTitle)
        .foregroundStyle(
          isDimmed ? AnyShapeStyle(.putioRowSecondary) : AnyShapeStyle(.putioRowPrimary)
        )
        .lineLimit(1)
        .truncationMode(.middle)
      Spacer(minLength: PutioTheme.TV.Spacing.small)
      if let note {
        Text(note)
          .putioFont(PutioTheme.TV.Typography.small)
          .foregroundStyle(.putioRowSecondary)
          .fixedSize()
          .layoutPriority(1)
      }
      if opens { TVDisclosure().layoutPriority(1) }
    }
    .padding(.horizontal, TVMoveSheetLayout.rowOutset)
    .padding(.vertical, PutioTheme.TV.Spacing.small)
    .frame(maxWidth: .infinity, alignment: .leading)
    .opacity(isDimmed && state != .focused ? TVMoveSheetLayout.unavailableOpacity : 1)
    .accessibilityElement(children: .combine)
  }
}

/// The sheet's one primary action: a full-width capsule that fills white
/// and lifts while focused.
private struct TVMoveHereButtonStyle: ButtonStyle {
  func makeBody(configuration: Configuration) -> some View {
    TVMoveHereButtonBody(configuration: configuration)
  }
}

private struct TVMoveHereButtonBody: View {
  let configuration: ButtonStyleConfiguration
  @Environment(\.isFocused) private var isFocused
  @Environment(\.isEnabled) private var isEnabled

  var body: some View {
    configuration.label
      .putioFont(PutioTVTypeScale.button)
      .foregroundStyle(isFocused ? PutioTVRowFocus.foreground : PutioTheme.TV.Colors.textPrimary)
      .frame(maxWidth: .infinity)
      .frame(height: TVMoveSheetLayout.moveHereHeight)
      .background(
        Capsule().fill(
          isFocused ? PutioTVRowFocus.fill : .white.opacity(TVMoveSheetLayout.moveHereRestingFill))
      )
      .shadow(
        color: .black.opacity(isFocused ? TVRowLayout.shadowOpacity : 0),
        radius: TVRowLayout.shadowRadius, y: TVRowLayout.shadowOffset
      )
      .scaleEffect(isFocused ? TVMoveSheetLayout.moveHereLift : 1)
      .opacity(isEnabled ? (configuration.isPressed ? TVRowLayout.pressedOpacity : 1) : 0.4)
      .animation(.easeOut(duration: TVRowLayout.focusDuration), value: isFocused)
  }
}

enum TVMoveSheetLayout {
  static let width: CGFloat = 720
  static let radius: CGFloat = 36
  static let scrimOpacity = 0.72
  static let topPadding: CGFloat = 64
  static let leadingPadding: CGFloat = 56
  static let trailingPadding: CGFloat = 80
  static let bottomPadding: CGFloat = 60
  static let locationGap: CGFloat = 28
  static let listGap: CGFloat = 16
  static let moveHereGap: CGFloat = 20
  static let moveHereHeight: CGFloat = 80
  static let moveHereRestingFill = 0.12
  static let moveHereLift = 1.04
  static let rowOutset: CGFloat = 24
  static let contentGap: CGFloat = 24
  static let folderIconSize: CGFloat = 36
  static let unavailableOpacity = 0.5
  static let shadowOpacity = 0.5
  static let shadowRadius: CGFloat = 40
  static let shadowOffset: CGFloat = 30
}

enum TVMoveCopy {
  static var title: String { String(localized: "Move", bundle: .putioCore) }
  static var moveHere: String { String(localized: "Move here", bundle: .putioCore) }
  static var hereNow: String { String(localized: "Here now", bundle: .putioCore) }
  static var loading: String { String(localized: "Loading folders", bundle: .putioCore) }
  static var loadingMore: String { String(localized: "Loading more folders", bundle: .putioCore) }
  static var more: String { String(localized: "More folders", bundle: .putioCore) }
  static var loadFailed: String {
    String(localized: "Couldn’t load folders.", bundle: .putioCore)
  }
  static var emptyTitle: String { String(localized: "No folders here.", bundle: .putioCore) }
  static var emptyMessage: String {
    String(localized: "Move here, or press Back.", bundle: .putioCore)
  }
  static func nameTaken(_ name: String) -> String {
    String(
      localized: "A file or folder named “\(name)” already exists there. Choose another folder.",
      bundle: .putioCore)
  }
}
