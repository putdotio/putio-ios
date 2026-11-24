import Foundation
import ImageIO

enum PutioQRCodeImage {
  /// True when `data` decodes as an image with pixels.
  static func isReadable(_ data: Data) -> Bool {
    guard let source = CGImageSourceCreateWithData(data as CFData, nil),
      let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
    else { return false }
    return image.width > 0 && image.height > 0
  }
}
