#if os(macOS)
  import CoreText
  import XCTest

  @testable import PutioCore

  final class BrandTypographyTests: XCTestCase {
    private let mobileMonoFontName = "BerkeleyMonoVariable-Regular"
    private let tvFilenameFontName = "GTAmerica-Md"
    private let tvFilenameFontSize: CGFloat = 48
    private let hostileFilenames = [
      "Résumé – été.pdf",
      "東京の映画 🎬.mkv",
      "Семейное видео.mp4",
      "👩🏽‍🚀 archive.zip",
    ]

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
        (fontName: tvFilenameFontName, size: tvFilenameFontSize),
      ]
      let descriptors = try fontDescriptors()
      for role in roles {
        let primary = try XCTUnwrap(
          descriptors.first { descriptor in
            (CTFontDescriptorCopyAttribute(descriptor, kCTFontNameAttribute) as? String)
              == role.fontName
          }
        )
        let font = CTFontCreateWithFontDescriptor(primary, role.size, nil)

        for filename in hostileFilenames {
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
      try XCTSkipUnless(
        FileManager.default.fileExists(atPath: fontDirectory.path),
        "optional brand fonts are absent; run mise run fonts-setup to test native faces"
      )
      let urls = try FileManager.default.contentsOfDirectory(
        at: fontDirectory,
        includingPropertiesForKeys: nil
      ).filter { $0.pathExtension == "otf" }
      try XCTSkipUnless(urls.count == 5, "complete brand font set required for native-face tests")
      return urls.flatMap { url in
        CTFontManagerCreateFontDescriptorsFromURL(url as CFURL) as? [CTFontDescriptor] ?? []
      }
    }
  }
#endif
