#if canImport(CoreImage)
  import CoreImage
  import CoreImage.CIFilterBuiltins
  import SwiftUI

  public enum PutioQRCode {
    public static let correctionLevel = "M"

    public static func image(for text: String) -> CGImage? {
      let filter = CIFilter.qrCodeGenerator()
      filter.message = Data(text.utf8)
      filter.correctionLevel = correctionLevel
      guard let output = filter.outputImage else { return nil }
      return CIContext(options: [.useSoftwareRenderer: true])
        .createCGImage(output, from: output.extent)
    }
  }

  public struct PutioQRCodeView: View {
    private let text: String
    private let size: CGFloat

    public init(_ text: String, size: CGFloat = 300) {
      self.text = text
      self.size = size
    }

    public var body: some View {
      Group {
        if let image = PutioQRCode.image(for: text) {
          Image(decorative: image, scale: 1)
            .interpolation(.none)
            .resizable()
            .scaledToFit()
        }
      }
      .padding(size * PutioQRCodeLayout.paddingRatio)
      .frame(width: size, height: size)
      .background(
        PutioQRCodeLayout.background,
        in: RoundedRectangle(cornerRadius: size * PutioQRCodeLayout.cornerRatio)
      )
      .accessibilityHidden(true)
    }
  }

  enum PutioQRCodeLayout {
    static let paddingRatio: CGFloat = 22 / 300
    static let cornerRatio: CGFloat = 36 / 300
    static let background = Color(.sRGB, red: 0.925, green: 0.925, blue: 0.925, opacity: 1)
  }
#endif
