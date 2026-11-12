import PutioCore
import SwiftUI

struct PublicLinksView: View {
  @State private var model: PutioPublicLinksModel
  @State private var confirmAlert: PutioConfirmAlert?
  @State private var toast: PutioToast?

  init(runtime: PutioRuntime) {
    _model = State(initialValue: PutioPublicLinksModel(actions: .init(runtime: runtime)))
  }

  var body: some View {
    content
      .navigationTitle(String(localized: "Exclusive links"))
      .navigationBarTitleDisplayMode(.inline)
      .putioFont(PutioTheme.Typography.body)
      .putioContentBackground()
      .putioConfirmAlert($confirmAlert)
      .putioToast($toast)
      .task { await model.loadOnOpen() }
  }

  @ViewBuilder private var content: some View {
    switch model.state {
    case .loading:
      PutioLoadingStateView(title: String(localized: "Loading links…"))
        .accessibilityIdentifier("public-links.loading")
    case .failed:
      PutioErrorStateView(kind: .failed, retryIdentifier: "public-links.retry") {
        Task { await model.load() }
      }
    case .loaded(let links) where links.isEmpty:
      ScrollView {
        PutioEmptyStateView(
          kaomoji: .nothingYet,
          title: String(localized: "No exclusive links"),
          message: String(localized: "Links you make with Exclusive access show up here.")
        )
        .containerRelativeFrame([.horizontal, .vertical])
        .accessibilityIdentifier("public-links.empty")
      }
      .refreshable { await model.load() }
    case .loaded(let links):
      List {
        PutioSettingsSection(String(localized: "Anyone with a link can open the file for 72 hours"))
        {
          ForEach(links) { link in
            row(link)
          }
        }
        .listRowBackground(PutioTheme.Colors.surface)
      }
      .refreshable { await model.load() }
      .accessibilityIdentifier("public-links.list")
    }
  }

  private func row(_ link: PutioPublicLink) -> some View {
    Menu {
      Section {
        Button {
          copy(link)
        } label: {
          Label {
            Text(String(localized: "Copy link"))
          } icon: {
            Image(putioIcon: .copy)
          }
        }
        .tint(PutioTheme.Colors.textPrimary)
        .accessibilityIdentifier("public-links.copy")
        ShareLink(item: link.url, preview: SharePreview(link.fileName)) {
          Label {
            Text(String(localized: "Share"))
          } icon: {
            Image(putioIcon: .export)
          }
        }
        .tint(PutioTheme.Colors.textPrimary)
        .accessibilityIdentifier("public-links.share")
      }
      Section {
        Button(role: .destructive) {
          askToRevoke(link)
        } label: {
          Label {
            Text(String(localized: "Revoke"))
          } icon: {
            Image(putioIcon: .linkBreak)
          }
        }
        .tint(PutioTheme.Colors.destructive)
        .accessibilityIdentifier("public-links.revoke")
      }
    } label: {
      PutioFileRow(
        PutioFileRowModel(
          name: link.fileName,
          kind: PutioBrowserItemPresentation.rowKind(for: link.kind),
          dateText: link.expiryText(at: .now)
        )
      )
      .contentShape(Rectangle())
    }
    .menuOrder(.fixed)
    .disabled(model.revokingID == link.id)
    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
      Button(String(localized: "Revoke")) {
        askToRevoke(link)
      }
      .tint(PutioTheme.Colors.destructive)
      .disabled(model.revokingID != nil)
      .accessibilityIdentifier("public-links.swipe-revoke")
    }
    .accessibilityIdentifier("public-links.item.\(link.id)")
  }

  private func copy(_ link: PutioPublicLink) {
    UIPasteboard.general.string = link.url.absoluteString
    toast = PutioToast(String(localized: "Copied to clipboard"))
  }

  private func askToRevoke(_ link: PutioPublicLink) {
    let model = model
    confirmAlert = PutioConfirmAlert(
      title: String(localized: "Revoke this link?"),
      message: String(localized: "Anyone who has the link to “\(link.fileName)” loses access."),
      confirmTitle: String(localized: "Revoke")
    ) {
      Task {
        if case .failed(let message) = await model.revoke(link) {
          toast = PutioToast(message, icon: .warning)
        }
      }
    }
  }
}
