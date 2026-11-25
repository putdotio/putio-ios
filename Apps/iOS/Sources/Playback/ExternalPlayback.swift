import Foundation
import PutioCore
import SwiftUI
import UIKit

extension PutioFileRoute {
  init(video route: PutioVideoRoute) {
    self.init(
      item: PutioFileItem(
        id: route.id, parentID: route.parentID, name: route.title, kind: .video, sizeBytes: 0,
        createdAt: .distantPast, updatedAt: .distantPast, resumePositionSeconds: 0))
  }
}

struct PutioSystemURLOpener: PutioExternalURLOpening {
  @MainActor func canOpen(_ url: URL) -> Bool {
    UIApplication.shared.canOpenURL(url)
  }

  @MainActor func open(_ url: URL) async -> Bool {
    await UIApplication.shared.open(url)
  }
}

struct PutioExternalPlaybackPresentation: ViewModifier {
  let model: PutioExternalPlaybackModel

  func body(content: Content) -> some View {
    content.putioAlert(
      PutioVLCHandoff.missingTitle,
      isPresented: Binding(
        get: { model.missingVLCRoute != nil },
        set: { if !$0 { model.dismissMissingVLC() } }
      ),
      message: String(
        localized: "Install VLC for iOS from the App Store to stream this file there."),
      actions: [
        PutioAlertAction(String(localized: "Cancel"), tier: .cancel),
        PutioAlertAction(String(localized: "Get VLC"), tier: .primary, id: "vlc.get") {
          Task { await model.openAppStore() }
        },
      ]
    )
  }
}
