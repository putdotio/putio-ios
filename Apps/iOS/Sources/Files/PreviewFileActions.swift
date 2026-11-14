import PutioCore
import SwiftUI

struct PutioPreviewFileActions {
  let actions: PutioFileActions
  let load: PutioFolderLoad
  let continueLoad: PutioFolderContinue
  let lookUp: @MainActor (PutioFileID) async throws -> PutioFileItem
  let restore: @MainActor (PutioFileID) async throws -> Void
  let createLink: PutioPublicLinkCreate
  let trashEnabled: Bool
  let refreshRequests: PutioFolderRefreshRequests

  init(runtime: PutioRuntime, trashEnabled: Bool, refreshRequests: PutioFolderRefreshRequests) {
    actions = PutioFileActions(runtime: runtime)
    load = { try await runtime.listFiles(parentID: $0, perPage: PutioRuntime.folderPageSize) }
    continueLoad = { try await runtime.continueFiles(cursor: $0) }
    lookUp = { try await runtime.getFile(fileID: $0) }
    restore = { fileID in
      defer { refreshRequests.requestAllLoadedFolders() }
      try await runtime.restoreTrashItems(fileIDs: [fileID])
    }
    createLink = { try await runtime.createPublicLink(fileID: $0) }
    self.trashEnabled = trashEnabled
    self.refreshRequests = refreshRequests
  }
}

struct PutioPreviewMoreMenu: View {
  enum Style {
    case bar
    case rail
  }

  let menu: PutioItemMenu
  let isDisabled: Bool
  var style = Style.bar

  var body: some View {
    switch style {
    case .bar:
      Menu {
        PutioItemMenuContent(menu)
      } label: {
        PutioPreviewToolbarIcon(icon: .dotsThree)
      }
      .accessibilityLabel(Text("More"))
      .menuOrder(.fixed)
      .menuStyle(.button)
      .buttonStyle(.plain)
      .foregroundStyle(PutioTheme.Colors.textPrimary)
      .disabled(isDisabled || menu.sections.isEmpty)
      .accessibilityIdentifier("preview.more")
    case .rail:
      Menu {
        PutioItemMenuContent(menu)
      } label: {
        Label(String(localized: "More"), systemImage: "ellipsis")
      }
      .menuOrder(.fixed)
      .tint(PutioTheme.Colors.textPrimary)
      .disabled(isDisabled || menu.sections.isEmpty)
      .accessibilityIdentifier("preview.more")
    }
  }
}
