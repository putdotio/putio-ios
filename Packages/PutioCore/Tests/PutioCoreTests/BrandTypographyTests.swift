#if os(macOS)
  import CoreText
  import XCTest

  @testable import PutioCore

  final class BrandTypographyTests: XCTestCase {
    private let mobileMonoFontName = "BerkeleyMonoVariable-Regular"

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
      ] {
        XCTAssertTrue(names.contains(role.fontName), "missing native face \(role.fontName)")
      }
      XCTAssertTrue(names.contains(mobileMonoFontName), "missing native face \(mobileMonoFontName)")
    }

    func testHostileFilenamesShapeWithoutMissingGlyphsUsingMobileAndTVFallbacks() throws {
      let roles = [
        (fontName: mobileMonoFontName, size: PutioTheme.Typography.sizeSm),
        (fontName: PutioTheme.Typography.body.fontName, size: PutioTheme.Typography.body.size),
      ]
      for role in roles {
        let primary = try XCTUnwrap(
          fontDescriptors().first { descriptor in
            (CTFontDescriptorCopyAttribute(descriptor, kCTFontNameAttribute) as? String)
              == role.fontName
          }
        )
        let font = CTFontCreateWithFontDescriptor(primary, role.size, nil)

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
          XCTAssertFalse(runs.isEmpty, "\(role.fontName): \(filename)")

          let glyphs = runs.flatMap { run -> [CGGlyph] in
            var values = Array(repeating: CGGlyph(), count: CTRunGetGlyphCount(run))
            CTRunGetGlyphs(run, CFRange(), &values)
            return values
          }
          XCTAssertFalse(glyphs.contains(0), "missing glyph in \(role.fontName): \(filename)")
        }
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
