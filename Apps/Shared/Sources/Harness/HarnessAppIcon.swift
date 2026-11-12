#if DEBUG
  import PutioCore
  import SwiftUI

  @MainActor
  enum HarnessAppIcon {
    private static var cached: Data?

    static func png() -> Data {
      if let cached { return cached }
      let tile = ZStack {
        PutioTheme.Colors.background
        Image.putioWordmark
          .resizable()
          .scaledToFit()
          .padding(PutioTheme.Spacing.space3)
      }
      .frame(width: 120, height: 120)
      let renderer = ImageRenderer(content: tile)
      renderer.scale = 1
      #if canImport(UIKit)
        let data = renderer.uiImage?.pngData() ?? Data()
      #else
        let data = Data()
      #endif
      cached = data
      return data
    }
  }
#endif
