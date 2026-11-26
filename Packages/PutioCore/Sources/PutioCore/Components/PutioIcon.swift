import SwiftUI

extension Image {
  public init(putioIcon: PutioIcon) {
    self.init(putioIcon.rawValue, bundle: .module)
  }
}

#if canImport(UIKit)
  extension Image {
    public init(putioIcon: PutioIcon, fixed color: Color) {
      guard let image = UIImage(named: putioIcon.rawValue, in: .module, with: nil)?.fixed(color)
      else {
        self.init(putioIcon: putioIcon)
        return
      }
      self.init(uiImage: image)
    }

    public init(systemName: String, fixed color: Color) {
      guard let image = UIImage(systemName: systemName)?.fixed(color) else {
        self.init(systemName: systemName)
        return
      }
      self.init(uiImage: image)
    }
  }

  extension UIImage {
    public convenience init?(putioIcon: PutioIcon) {
      self.init(named: putioIcon.rawValue, in: .module, with: nil)
    }

    public func fixed(_ color: Color) -> UIImage {
      withTintColor(UIColor(color), renderingMode: .alwaysOriginal)
    }
  }
#endif

extension Image {
  /// The retro put.io wordmark from the design package's `logo-retro-dark.svg`.
  public static var putioWordmark: Image {
    Image("PutioLogoRetroDark", bundle: .module)
  }
}

public struct PutioIconView: View {
  private let icon: PutioIcon
  @PutioScaledMetric private var size: CGFloat

  public init(_ icon: PutioIcon, size: PutioMetricRole) {
    self.icon = icon
    _size = PutioScaledMetric(size)
  }

  public var body: some View {
    Image(putioIcon: icon)
      .resizable()
      .scaledToFit()
      .frame(width: size, height: size)
  }
}
