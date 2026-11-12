import PutioCore
import SwiftUI

struct PutioPreviewFileActions {
  let actions: PutioFileActions
  let load: PutioFolderLoad
  let continueLoad: PutioFolderContinue
  let lookUp: @MainActor (PutioFileID) async throws -> PutioFileItem
  let restore: @MainActor (PutioFileID) async throws -> Void
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
    self.trashEnabled = trashEnabled
    self.refreshRequests = refreshRequests
  }
}

struct PutioPreviewMoreMenu: View {
  let menu: PutioItemMenu
  let isDisabled: Bool

  var body: some View {
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
  }
}
