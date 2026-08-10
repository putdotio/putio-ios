#if os(macOS)
  import CoreText
  import XCTest

  @testable import PutioCore

  final class BrandTypographyTests: XCTestCase {
    private var fontDirectory: URL {
      URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appending(path: "Resources/BrandFonts")
    }

    func testDownloadedFilesExposeEverySemanticNativeFace() throws {
      let names = try fontDescriptors().compactMap { descriptor in
        CTFontDescriptorCopyAttribute(descriptor, kCTFontNameAttribute) as? String
      }

      for role in [
        PutioTheme.Typography.caption,
        PutioTheme.Typography.subheading,
        PutioTheme.Typography.heading,
        PutioTheme.Typography.display,
        PutioTheme.Typography.mono,
      ] {
        XCTAssertTrue(names.contains(role.fontName), "missing native face \(role.fontName)")
      }
    }

    func testHostileFilenamesShapeWithoutMissingGlyphsUsingSystemFallback() throws {
      let primary = try XCTUnwrap(
        fontDescriptors().first { descriptor in
          (CTFontDescriptorCopyAttribute(descriptor, kCTFontNameAttribute) as? String)
            == PutioTheme.Typography.body.fontName
        }
      )
      let font = CTFontCreateWithFontDescriptor(primary, PutioTheme.Typography.body.size, nil)

      for filename in BrandTypographyProof.hostileFilenames {
        let line = CTLineCreateWithAttributedString(
          NSAttributedString(
            string: filename,
            attributes: [
              NSAttributedString.Key(kCTFontAttributeName as String): font
            ]
          )
        )
        let runs = CTLineGetGlyphRuns(line) as? [CTRun] ?? []
        XCTAssertFalse(runs.isEmpty, filename)

        let glyphs = runs.flatMap { run -> [CGGlyph] in
          var values = Array(repeating: CGGlyph(), count: CTRunGetGlyphCount(run))
          CTRunGetGlyphs(run, CFRange(), &values)
          return values
        }
        XCTAssertFalse(glyphs.contains(0), "missing glyph in \(filename)")
      }
    }

    private func fontDescriptors() throws -> [CTFontDescriptor] {
      let urls = try FileManager.default.contentsOfDirectory(
        at: fontDirectory,
        includingPropertiesForKeys: nil
      ).filter { $0.pathExtension == "otf" }
      XCTAssertEqual(urls.count, 5, "run mise run fonts-setup")
      return urls.flatMap { url in
        CTFontManagerCreateFontDescriptorsFromURL(url as CFURL) as? [CTFontDescriptor] ?? []
      }
    }
  }
#endif
