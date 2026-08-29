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
    XCTAssertEqual(
      HarnessScenario.parse(arguments: [
        "app", "--putio-harness-scenario", "files-browser",
      ]),
      .filesBrowser
    )
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

  func testButtonTokensPreservePublishedGeometry() {
    XCTAssertEqual(PutioTheme.Components.Button.height.value, 36)
    XCTAssertEqual(PutioTheme.Components.Button.heightMedium.value, 32)
    XCTAssertEqual(PutioTheme.Components.Button.heightSmall.value, 28)
    XCTAssertEqual(PutioTheme.Components.Button.heightXSmall.value, 24)
    XCTAssertEqual(PutioTheme.Components.Button.paddingX.value, 12)
    XCTAssertEqual(PutioTheme.Components.Button.paddingXXSmall.value, 8)
    XCTAssertEqual(PutioTheme.Components.Button.tracking, 1)
    XCTAssertEqual(PutioTheme.Components.Button.trackingXSmall, 0.3)
    XCTAssertEqual(PutioTheme.Components.Button.label.fontName, "GTAmerica-Md")
    XCTAssertEqual(PutioTheme.Components.Button.label.size, 14)
    XCTAssertEqual(PutioTheme.Components.Button.labelXSmall.size, 12)
  }

  #if !os(tvOS)
    func testButtonSizesMapToNativeControlSizes() {
      XCTAssertEqual(PutioButtonSize.regular.controlSize, .large)
      XCTAssertEqual(PutioButtonSize.medium.controlSize, .regular)
      XCTAssertEqual(PutioButtonSize.small.controlSize, .small)
      XCTAssertEqual(PutioButtonSize.extraSmall.controlSize, .mini)
    }
  #endif

  func testFileRowIconsCoverEveryKind() {
    let icons = Set(
      PutioFileRowModel.Kind.allCases.map { kind in
        PutioFileRowModel(name: "fixture", kind: kind).icon
      })
    XCTAssertEqual(icons.count, PutioFileRowModel.Kind.allCases.count)
  }

  @MainActor
  func testFileRowCanDeferFolderDisclosureToNavigationLink() {
    let folder = PutioFileRowModel(name: "Folder", kind: .folder)
    let defaultFolderDisclosure = PutioFileRow(folder).rendersFolderDisclosure
    let deferredFolderDisclosure =
      PutioFileRow(folder, showsFolderDisclosure: false).rendersFolderDisclosure
    XCTAssertTrue(defaultFolderDisclosure)
    XCTAssertFalse(deferredFolderDisclosure)

    let file = PutioFileRowModel(name: "File", kind: .file)
    let fileDisclosure = PutioFileRow(file).rendersFolderDisclosure
    XCTAssertFalse(fileDisclosure)
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
