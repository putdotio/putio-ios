import XCTest

@testable import PutioCore

#if os(macOS)
  import AppKit
#endif

final class PutioThemeTests: XCTestCase {
  func testGeneratedThemeIdentifiesItsPinnedSource() {
    XCTAssertEqual(PutioTheme.sourcePackage, "@putdotio/design")
    XCTAssertEqual(PutioTheme.sourceVersion, "2.0.1")
    XCTAssertEqual(PutioTheme.sourceTokenCount, 449)
  }

  func testGeneratedScalesPreservePublishedValues() {
    XCTAssertEqual(PutioTheme.Spacing.space3, 16)
    XCTAssertEqual(PutioTheme.Radius.standard, 6)
    XCTAssertEqual(PutioTheme.Border.width, 1)
    XCTAssertEqual(PutioTheme.Motion.durationBase, 0.2)
    XCTAssertEqual(PutioTheme.ScaledMetrics.contentGap.value, 16)
    XCTAssertEqual(PutioTheme.ScaledMetrics.contentGap.textStyle, .body)
    XCTAssertEqual(PutioTheme.ScaledMetrics.buttonIconSize.value, 14)
    XCTAssertEqual(PutioTheme.Icons.button.size.value, 14)
    XCTAssertEqual(
      PutioTheme.Motion.easingOut,
      PutioCubicBezier(x1: 0.22, y1: 1, x2: 0.36, y2: 1)
    )
  }

  func testFontRoleLineSpacingClampsNegativeLeading() {
    let role = PutioFontRole(
      family: "System",
      fontName: "Helvetica",
      size: 20,
      weight: .regular,
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
    XCTAssertEqual(PutioTheme.Typography.mono.fontName, "BerkeleyMonoVariable-Regular")
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
