import Foundation
import XCTest

@testable import PutioCore

final class QRCodeImageTests: XCTestCase {
  func testAOnePixelPNGIsReadableAndTextIsNot() throws {
    let png = try XCTUnwrap(
      Data(
        base64Encoded:
          "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg=="
      ))
    XCTAssertTrue(PutioQRCodeImage.isReadable(png))
    XCTAssertFalse(PutioQRCodeImage.isReadable(Data("not an image".utf8)))
  }
}
