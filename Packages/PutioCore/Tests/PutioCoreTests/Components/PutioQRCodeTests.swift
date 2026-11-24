#if os(macOS)
  import CoreImage
  import XCTest

  @testable import PutioCore

  final class PutioQRCodeTests: XCTestCase {
    func testCodeDecodesToItsTextAtCorrectionLevelM() throws {
      let text = "https://put.io/link?code=ABC123"
      let image = try XCTUnwrap(PutioQRCode.image(for: text))
      let scaled = CIImage(cgImage: image)
        .transformed(by: CGAffineTransform(scaleX: 12, y: 12))
        .samplingNearest()
      let detector = try XCTUnwrap(
        CIDetector(
          ofType: CIDetectorTypeQRCode, context: nil,
          options: [CIDetectorAccuracy: CIDetectorAccuracyHigh]))
      let features = detector.features(in: scaled).compactMap { $0 as? CIQRCodeFeature }
      XCTAssertEqual(features.map(\.messageString), [text])
      let descriptor = try XCTUnwrap(features.first?.symbolDescriptor)
      XCTAssertEqual(descriptor.errorCorrectionLevel, .levelM)
    }

    func testTVTextNeverDropsBelowTheMinimumSize() {
      for role in PutioTVTypeScale.roles {
        XCTAssertGreaterThanOrEqual(role.size, PutioTVTypeScale.minimumSize, role.fontName)
      }
    }
  }
#endif
