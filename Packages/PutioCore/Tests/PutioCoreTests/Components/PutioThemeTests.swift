import XCTest

@testable import PutioCore

#if os(macOS)
  import AppKit
#endif

final class PutioThemeTests: XCTestCase {
  func testFontRoleLineSpacingClampsNegativeLeading() {
    let role = PutioFontRole(
      fontName: "Helvetica",
      size: 20,
      lineHeight: 0.8,
      textStyle: .body
    )

    XCTAssertEqual(role.baseLineSpacing, 0)
  }

  func testTypographyRolesMapToBundledBrandFaces() {
    XCTAssertEqual(PutioTheme.Typography.caption.fontName, "GTAmerica-Rg")
    XCTAssertEqual(PutioTheme.Typography.subheading.fontName, "GTAmerica-Md")
    XCTAssertEqual(PutioTheme.Typography.heading.fontName, "GTAmerica-Bd")
    XCTAssertEqual(PutioTheme.Typography.display.fontName, "GTAmerica-Bl")
  }

  #if os(macOS)
    func testSemanticColorsResolveDuringDirectSwiftPackageTests() throws {
      let color = try XCTUnwrap(
        NSColor(PutioTheme.Colors.background).usingColorSpace(.sRGB)
      )

      XCTAssertEqual(color.redComponent, 0.085, accuracy: 0.000_001)
      XCTAssertEqual(color.greenComponent, 0.085, accuracy: 0.000_001)
      XCTAssertEqual(color.blueComponent, 0.085, accuracy: 0.000_001)
      XCTAssertEqual(color.alphaComponent, 1, accuracy: 0.000_001)
    }
  #endif
}
