import XCTest

extension XCUIApplication {
  func showsAccent(in rect: CGRect) -> Bool {
    accentPixelCount(in: rect) >= 4
  }

  func showsAccent(on element: XCUIElement) -> Bool {
    showsAccent(in: element.frame)
  }

  func accentPixelCount(in rect: CGRect) -> Int {
    guard let image = XCUIScreen.main.screenshot().image.cgImage else { return 0 }
    let scale = CGFloat(image.width) / windows.firstMatch.frame.width
    let pixels = CGRect(
      x: rect.minX * scale, y: rect.minY * scale, width: rect.width * scale,
      height: rect.height * scale
    ).integral.intersection(CGRect(x: 0, y: 0, width: image.width, height: image.height))
    guard !pixels.isEmpty, let patch = image.cropping(to: pixels) else { return 0 }
    let width = patch.width
    let height = patch.height
    var bytes = [UInt8](repeating: 0, count: width * height * 4)
    let drawn = bytes.withUnsafeMutableBytes { buffer -> Bool in
      guard
        let context = CGContext(
          data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
          bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            | CGBitmapInfo.byteOrder32Big.rawValue)
      else { return false }
      context.draw(patch, in: CGRect(x: 0, y: 0, width: width, height: height))
      return true
    }
    guard drawn else { return 0 }
    var count = 0
    for offset in stride(from: 0, to: bytes.count, by: 4) {
      let red = Int(bytes[offset])
      let green = Int(bytes[offset + 1])
      let blue = Int(bytes[offset + 2])
      if red >= 200, (150...235).contains(green), red - blue >= 110, red - green <= 70 {
        count += 1
      }
    }
    return count
  }
}
