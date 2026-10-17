#if DEBUG
import UIKit

// Image and PDF bytes for the large fixture's previews, generated on first
// request and cached, so nothing binary is committed.
extension PutioE2ELargeFixture {
    static func download(fileID id: Int) -> Response? {
        switch kind(of: id) {
        case .image:
            let isLarge = id == Anchor.largeImage
            let size = isLarge ? CGSize(width: 8_064, height: 6_048) : CGSize(width: 4_032, height: 3_024)
            let body = cached("photo-\(Int(size.width))x\(Int(size.height)).jpg") { jpeg(size: size) }
            return Response(statusCode: 200, contentType: "image/jpeg", body: body)
        case .pdf:
            let body = cached("document-300.pdf") { pdf(pages: 300) }
            return Response(statusCode: 200, contentType: "application/pdf", body: body)
        default:
            return nil
        }
    }

    // Busy enough that JPEG cannot compress it to nothing; decode cost follows
    // pixel count either way.
    private static func jpeg(size: CGSize) -> Data {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        var random = SeededRandom(state: UInt64(size.width))

        return UIGraphicsImageRenderer(size: size, format: format).jpegData(withCompressionQuality: 0.85) { context in
            let colors = [UIColor.systemTeal.cgColor, UIColor.systemIndigo.cgColor, UIColor.systemOrange.cgColor] as CFArray
            if let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: nil) {
                context.cgContext.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: size.width, y: size.height), options: [])
            }
            for _ in 0..<600 {
                UIColor(
                    hue: random.double(in: 0...1),
                    saturation: 0.7,
                    brightness: random.double(in: 0.4...1),
                    alpha: 0.6
                ).setFill()
                let side = random.double(in: 40...900)
                let rect = CGRect(
                    x: random.double(in: 0...Double(size.width)),
                    y: random.double(in: 0...Double(size.height)),
                    width: side,
                    height: side * random.double(in: 0.3...1.5)
                )
                UIBezierPath(ovalIn: rect).fill()
            }
        }
    }

    private static func pdf(pages: Int) -> Data {
        let bounds = CGRect(x: 0, y: 0, width: 595, height: 842)
        let attributes: [NSAttributedString.Key: Any] = [.font: UIFont.systemFont(ofSize: 11)]
        let paragraph = String(repeating: "Large fixture page body text for layout and rendering. ", count: 40)

        return UIGraphicsPDFRenderer(bounds: bounds).pdfData { context in
            for page in 1...pages {
                context.beginPage()
                ("Page \(page)" as NSString).draw(at: CGPoint(x: 48, y: 40), withAttributes: [.font: UIFont.boldSystemFont(ofSize: 18)])
                (paragraph as NSString).draw(in: bounds.insetBy(dx: 48, dy: 80), withAttributes: attributes)
                UIColor.systemGray.setStroke()
                for line in 0..<12 {
                    let y = 560 + CGFloat(line) * 20
                    UIBezierPath(rect: CGRect(x: 48, y: y, width: CGFloat(80 + (page * 37 + line * 53) % 420), height: 12)).stroke()
                }
            }
        }
    }
}
#endif
