import XCTest

@testable import PutioCore

#if os(macOS)
  import AppKit
#endif

final class ComponentKitTests: XCTestCase {
  func testHarnessScenarioParsing() {
    XCTAssertEqual(HarnessScenario.parse(arguments: []), .signedOut)
    XCTAssertEqual(
      HarnessScenario.parse(arguments: ["--putio-harness-scenario"]), .signedOut)
    XCTAssertEqual(
      HarnessScenario.parse(arguments: ["--putio-harness-scenario", "unknown"]), .signedOut)
    XCTAssertEqual(
      HarnessScenario.parse(arguments: ["--putio-harness-scenario", "exercised"]), .exercised)
    XCTAssertEqual(
      HarnessScenario.parse(arguments: ["app", "--putio-harness-scenario", "gallery"]), .gallery)
    XCTAssertTrue(
      SignedOutPresentation.isHarnessExercise(arguments: [
        "--putio-harness-scenario", "exercised",
      ])
    )
  }

  func testSizeTextFormatsWithExplicitLocale() {
    XCTAssertEqual(
      PutioFileRowModel.sizeText(bytes: 4_682_500_000, locale: Locale(identifier: "en_US")),
      "4.68 GB"
    )
    XCTAssertEqual(
      PutioFileRowModel.sizeText(bytes: 1024, locale: Locale(identifier: "en_US")),
      "1 kB"
    )
  }

  func testButtonSizesReadTokenGeometry() {
    XCTAssertEqual(PutioButtonSize.regular.metrics.height.value, 36)
    XCTAssertEqual(PutioButtonSize.medium.metrics.height.value, 32)
    XCTAssertEqual(PutioButtonSize.small.metrics.height.value, 28)
    XCTAssertEqual(PutioButtonSize.extraSmall.metrics.height.value, 24)
    XCTAssertEqual(PutioButtonSize.regular.metrics.paddingX.value, 12)
    XCTAssertEqual(PutioButtonSize.extraSmall.metrics.paddingX.value, 8)
    XCTAssertEqual(PutioButtonSize.regular.metrics.tracking, 1)
    XCTAssertEqual(PutioButtonSize.medium.metrics.tracking, 0.8)
    XCTAssertEqual(PutioButtonSize.small.metrics.tracking, 0.6)
    XCTAssertEqual(PutioButtonSize.extraSmall.metrics.tracking, 0.3)
    XCTAssertEqual(PutioButtonSize.regular.metrics.label.fontName, "GTAmerica-Md")
    XCTAssertEqual(PutioButtonSize.regular.metrics.label.size, 14)
    XCTAssertEqual(PutioButtonSize.extraSmall.metrics.label.size, 12)
  }

  func testEveryButtonTierResolvesAPalette() {
    for tier in PutioButtonTier.allCases {
      _ = tier.palette
    }
  }

  func testFileRowIconsCoverEveryKind() {
    let icons = Set(
      PutioFileRowModel.Kind.allCases.map { kind in
        PutioFileRowModel(name: "fixture", kind: kind).icon
      })
    XCTAssertEqual(icons.count, PutioFileRowModel.Kind.allCases.count)
  }

  func testGalleryFixturesCoverEveryVariantAxis() {
    XCTAssertEqual(
      Set(GalleryFixtures.fileRows.map(\.kind)).count,
      PutioFileRowModel.Kind.allCases.count
    )
    XCTAssertEqual(
      Set(GalleryFixtures.toasts.map(\.variant)).count,
      PutioToast.Variant.allCases.count
    )
    XCTAssertTrue(GalleryFixtures.fileRows.contains(where: \.isWatched))
  }

  #if os(macOS)
    func testComponentColorsResolveDuringDirectSwiftPackageTests() throws {
      let color = try XCTUnwrap(
        NSColor(PutioTheme.Components.Button.secondaryBackground).usingColorSpace(.sRGB)
      )
      XCTAssertEqual(color.redComponent, 0.136, accuracy: 0.000_001)

      let scrim = try XCTUnwrap(
        NSColor(PutioTheme.Components.Sheet.scrim).usingColorSpace(.sRGB)
      )
      XCTAssertEqual(scrim.alphaComponent, 0.565, accuracy: 0.000_001)
    }
  #endif
}
