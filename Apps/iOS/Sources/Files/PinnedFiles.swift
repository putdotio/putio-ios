import Foundation
import PutioCore
import SwiftUI

extension PutioFolderRoute {
  static let pinnedList = PutioFolderRoute(
    id: PutioFileID(rawValue: -1), title: String(localized: "Pinned"))
}

struct PutioPinnedFilesContext {
  let model: PutioPinnedFilesModel
  let showAll: @MainActor () -> Void
}

extension EnvironmentValues {
  @Entry var putioPinnedFiles: PutioPinnedFilesContext? = nil
}

enum PutioPinnedCopy {
  static func location(_ folder: String) -> String {
    String(localized: "in \(folder)")
  }
}

struct PutioPinnedSection: View {
  let context: PutioPinnedFilesContext
  let canEdit: Bool
  let isDisabled: Bool
  let onOpen: PutioFileSelection
  let onMove: @MainActor @Sendable (PutioFileItem) -> Void
  var onLink: (@MainActor @Sendable (PutioFileItem) -> Void)? = nil

  var body: some View {
    let pins = context.model.sectionItems
    if !pins.isEmpty {
      header
      PutioPinnedRows(
        pins: pins, model: context.model, canEdit: canEdit, isDisabled: isDisabled,
        onOpen: onOpen, onMove: onMove, onLink: onLink)
    }
  }

  private static let iconSize = PutioMetricRole(
    value: PutioTheme.Typography.sizeSm, relativeTo: .caption)

  private var header: some View {
    HStack(alignment: .firstTextBaseline) {
      Label {
        Text("Pinned")
      } icon: {
        PutioIconView(.pushPin, size: Self.iconSize)
      }
      .labelStyle(PutioPinnedHeaderLabelStyle())
      .putioFont(PutioTheme.Typography.caption)
      .foregroundStyle(PutioTheme.Colors.textSecondary)
      .accessibilityAddTraits(.isHeader)
      .accessibilityIdentifier("files.pinned")
      Spacer(minLength: PutioTheme.Spacing.space2)
      if context.model.showsSeeAll {
        Button("See all") { context.showAll() }
          .buttonStyle(.borderless)
          .putioFont(PutioTheme.Components.Button.label)
          .foregroundStyle(PutioTheme.Colors.textPrimary)
          .disabled(isDisabled)
          .accessibilityIdentifier("files.pinned.see-all")
      }
    }
    .listRowInsets(
      EdgeInsets(
        top: PutioTheme.Spacing.space3, leading: PutioTheme.Spacing.space3,
        bottom: 0, trailing: PutioTheme.Spacing.space3)
    )
    .listRowSeparator(.hidden)
    .listRowBackground(PutioTheme.Colors.background)
    .selectionDisabled()
  }
}

private struct PutioPinnedHeaderLabelStyle: LabelStyle {
  func makeBody(configuration: Configuration) -> some View {
    HStack(spacing: PutioTheme.Spacing.space1) {
      configuration.icon
      configuration.title
    }
  }
}

struct PutioPinnedRows: View {
  let pins: [PutioPinnedFile]
  let model: PutioPinnedFilesModel
  let canEdit: Bool
  let isDisabled: Bool
  let onOpen: PutioFileSelection
  let onMove: @MainActor @Sendable (PutioFileItem) -> Void
  var onLink: (@MainActor @Sendable (PutioFileItem) -> Void)? = nil

  var body: some View {
    ForEach(pins) { pin in
      row(pin)
        .frame(maxWidth: .infinity, alignment: .leading)
        .putioItemActions(menu(for: pin.item))
        .putioListDetailRow(pin.id)
        .selectionDisabled()
    }
  }

  @ViewBuilder
  private func row(_ pin: PutioPinnedFile) -> some View {
    let label = PutioFileRow(
      PutioFileRowModel(
        name: pin.item.name,
        kind: PutioBrowserItemPresentation.rowKind(for: pin.item.kind),
        dateText: pin.location.map(PutioPinnedCopy.location)))
    if pin.item.kind == .folder {
      NavigationLink(value: PutioFolderRoute(id: pin.item.id, title: pin.item.name)) {
        label
      }
      .disabled(isDisabled)
      .accessibilityIdentifier("files.pinned.item.\(pin.id.rawValue)")
    } else {
      Button {
        onOpen(PutioFileRoute(item: pin.item))
      } label: {
        label.contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .disabled(isDisabled)
      .accessibilityIdentifier("files.pinned.item.\(pin.id.rawValue)")
    }
  }

  private func menu(for item: PutioFileItem) -> PutioItemMenu {
    let rows = PutioFileMenu.pinnedRow(item: item, canEdit: canEdit, canLink: onLink != nil)
    return PutioItemMenu(
      rows.sections.map { section in
        section.compactMap { row -> PutioItemAction? in
          switch row {
          case .unpin:
            PutioItemAction(
              id: "unpin", title: String(localized: "Unpin"), icon: .pushPinSlash,
              isDisabled: isDisabled
            ) { Task { await model.unpin(item) } }
          case .move:
            PutioItemAction(
              id: "move", title: String(localized: "Move"), icon: .folderSimpleDashed,
              isDisabled: isDisabled
            ) { onMove(item) }
          case .exclusiveLink:
            PutioItemAction(
              id: "exclusive-link", title: String(localized: "Exclusive link"), icon: .link,
              isDisabled: isDisabled
            ) { onLink?(item) }
          default:
            nil
          }
        }
      })
  }
}

struct PutioPinnedMoveHost: ViewModifier {
  @Binding var request: PutioFileItemActionRequest?
  let itemActions: PutioFileItemActionModel?
  let actions: PutioFileActions?
  let load: PutioFolderLoad
  let continueLoad: PutioFolderContinue?
  let trashEnabled: Bool
  let refreshRequests: PutioFolderRefreshRequests
  let pins: PutioPinnedFilesModel?

  func body(content: Content) -> some View {
    if let itemActions, let actions {
      content
        .modifier(
          PutioFileItemActionsHost(
            request: $request, model: itemActions, actions: actions, load: load,
            continueLoad: continueLoad ?? { _ in throw PutioRuntimeError.invalidResponse },
            trashEnabled: trashEnabled, refreshRequests: refreshRequests)
        )
        .onChange(of: itemActions.canStartAction) { _, idle in
          guard idle, let pins else { return }
          Task { await pins.load() }
        }
    } else {
      content
    }
  }
}

struct PutioPinnedListScreen: View {
  let model: PutioPinnedFilesModel
  let actions: PutioFileActions?
  let load: PutioFolderLoad
  let continueLoad: PutioFolderContinue?
  let trashEnabled: Bool
  let refreshRequests: PutioFolderRefreshRequests
  let onFileSelected: PutioFileSelection

  @State private var moveRequest: PutioFileItemActionRequest?
  @State private var itemActions: PutioFileItemActionModel?
  @State private var linkItem: PutioFileItem?
  @Environment(\.putioExclusiveLink) private var exclusiveLink

  init(
    model: PutioPinnedFilesModel,
    actions: PutioFileActions?,
    load: @escaping PutioFolderLoad,
    continueLoad: PutioFolderContinue?,
    trashEnabled: Bool,
    refreshRequests: PutioFolderRefreshRequests,
    onFileSelected: @escaping PutioFileSelection
  ) {
    self.model = model
    self.actions = actions
    self.load = load
    self.continueLoad = continueLoad
    self.trashEnabled = trashEnabled
    self.refreshRequests = refreshRequests
    self.onFileSelected = onFileSelected
    _itemActions = State(
      initialValue: actions.map {
        PutioFileItemActionModel(actions: $0, refreshRequests: refreshRequests)
      })
  }

  private var linkAction: (@MainActor @Sendable (PutioFileItem) -> Void)? {
    guard exclusiveLink != nil else { return nil }
    return { linkItem = $0 }
  }

  var body: some View {
    List {
      Text("\(model.items.count) items")
        .putioFont(PutioTheme.Typography.numeric)
        .foregroundStyle(PutioTheme.Colors.textSecondary)
        .accessibilityIdentifier("files.pinned-list.count")
        .listRowSeparator(.hidden)
        .listRowBackground(PutioTheme.Colors.background)
      PutioPinnedRows(
        pins: model.items, model: model, canEdit: actions != nil,
        isDisabled: itemActions?.canStartAction == false,
        onOpen: onFileSelected, onMove: { moveRequest = .move($0) },
        onLink: linkAction)
    }
    .listStyle(.plain)
    .refreshable { await model.load() }
    .navigationTitle(PutioFolderRoute.pinnedList.title)
    .navigationBarTitleDisplayMode(.inline)
    .putioContentBackground()
    .accessibilityIdentifier("files.pinned-list")
    .putioExclusiveLinkSheet($linkItem)
    .modifier(
      PutioPinnedMoveHost(
        request: $moveRequest, itemActions: itemActions, actions: actions, load: load,
        continueLoad: continueLoad, trashEnabled: trashEnabled,
        refreshRequests: refreshRequests, pins: model))
  }
}
