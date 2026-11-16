import PutioCore
import SwiftUI

struct PutioDownloadWithOtherMethod {
  let method: PutioPlaybackMethod
  let download: @MainActor @Sendable (PutioFileRoute, PutioPlaybackMethod) -> Void

  @MainActor
  func action(for route: PutioFileRoute, isDisabled: Bool = false) -> PutioItemAction {
    let method = method
    let download = download
    return PutioItemAction(
      id: "download-with-other-method", title: method.downloadWithTitle, icon: .downloadSimple,
      isDisabled: isDisabled
    ) { download(route, method) }
  }
}

extension PutioPlaybackMethod {
  var downloadWithTitle: String {
    switch self {
    case .standard: String(localized: "Download with Standard")
    case .directPlay: String(localized: "Download with Direct play")
    }
  }
}

extension EnvironmentValues {
  @Entry var putioDownloadWithOtherMethod: PutioDownloadWithOtherMethod? = nil
}
