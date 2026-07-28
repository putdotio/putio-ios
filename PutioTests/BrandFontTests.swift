import XCTest
@testable import Putio

// Verification builds bundle the licensed faces
// (PUTIO_BUNDLE_BRAND_FONTS = YES in Config/Verify.xcconfig) so the visual
// suite can see typography regressions — it could not while they were
// excluded, which is why #37, #42, and #43 all moved zero baselines. These
// tests pin that contract: a build that loses the faces becomes a named
// failure here instead of 23 mysterious pixel diffs.
//
// Recording therefore requires the fonts. Run `make fonts-setup` before
// `make screenshots-record`.
final class BrandFontTests: XCTestCase {
    private static let sansFamily = "GT America"
    private static let monoFamily = "Berkeley Mono Variable"

    func testVerifyBuildsBundleBrandFonts() {
        let bundled = (Bundle.main.urls(forResourcesWithExtension: "otf", subdirectory: nil) ?? [])
            .map(\.lastPathComponent)
            .filter { $0.hasPrefix("gt-america-") || $0.hasPrefix("berkeley-mono-") }
            .sorted()

        XCTAssertFalse(
            bundled.isEmpty,
            """
            verification builds must bundle the brand fonts; baselines are recorded with them. \
            Run `make fonts-setup`, and check PUTIO_BUNDLE_BRAND_FONTS in Config/Verify.xcconfig.
            """
        )
        XCTAssertTrue(
            bundled.contains { $0.hasPrefix("berkeley-mono-") },
            "the mono face is the code/numeric role and must be bundled too"
        )
    }

    func testOptionalAccessorsResolveToBrandFaces() {
        BrandFont.registerIfAvailable()

        let sans = BrandFont.sansIfAvailable(size: 17, weight: .bold)
        let mono = BrandFont.monoIfAvailable(size: 13)

        XCTAssertEqual(sans?.familyName, Self.sansFamily)
        XCTAssertEqual(mono?.familyName, Self.monoFamily)
    }

    func testNonOptionalAccessorsReturnBrandFacesRatherThanSystem() {
        BrandFont.registerIfAvailable()

        let sans = BrandFont.sans(size: 17, weight: .bold)
        let mono = BrandFont.mono(size: 13)

        XCTAssertEqual(sans.familyName, Self.sansFamily)
        XCTAssertEqual(mono.familyName, Self.monoFamily)
        XCTAssertNotEqual(sans, .systemFont(ofSize: 17, weight: .bold))
        XCTAssertNotEqual(mono, .monospacedSystemFont(ofSize: 13, weight: .regular))
    }

    // Pins the wiring of the system-font fallback without depending on the
    // faces being absent: `sans` is `sansIfAvailable` plus a fallback, so when
    // a face resolves the two must agree. The absent-fonts branch itself is
    // only reachable in builds without the licensed fonts — a contributor
    // without font access, or any non-Verify build that skipped the sync — and
    // is covered there by the app simply rendering in system fonts.
    func testNonOptionalAccessorsDeferToTheOptionalOnesWhenFacesResolve() {
        BrandFont.registerIfAvailable()

        XCTAssertEqual(BrandFont.sans(size: 17, weight: .bold), BrandFont.sansIfAvailable(size: 17, weight: .bold))
        XCTAssertEqual(BrandFont.mono(size: 13), BrandFont.monoIfAvailable(size: 13))
    }

    // Pins the fixed-size-label weight fix: the descriptor's weight trait is
    // an NSNumber, so a direct `as? CGFloat` cast fails and silently drops the
    // label to regular. Pure descriptor math — independent of bundled fonts.
    func testFixedSizeWeightIsRecoveredFromNSNumberTrait() {
        let semibold = UIFont.systemFont(ofSize: 14, weight: .semibold)
        let recovered = UILabel.brandWeight(from: semibold.fontDescriptor)
        XCTAssertEqual(recovered.rawValue, UIFont.Weight.semibold.rawValue, accuracy: 0.001,
                       "weight must be read via NSNumber, not dropped to regular")
        XCTAssertNotEqual(recovered.rawValue, UIFont.Weight.regular.rawValue,
                          "a semibold font must not silently resolve to regular")

        let regular = UIFont.systemFont(ofSize: 14, weight: .regular)
        XCTAssertEqual(UILabel.brandWeight(from: regular.fontDescriptor).rawValue,
                       UIFont.Weight.regular.rawValue, accuracy: 0.001)
    }

    // The full-style application (font + tracking + line height + uppercasing)
    // must actually take effect now that the faces ship in Verify.
    func testApplyBrandStyleAppliesTheBrandFace() {
        BrandFont.registerIfAvailable()
        let label = UILabel()
        label.text = "Restore Your Downloads"
        label.font = UIFont.preferredFont(forTextStyle: .title1)

        label.applyBrandStyle(.h2)

        XCTAssertEqual(label.font.familyName, Self.sansFamily, "h2 must resolve to the brand sans face")
        XCTAssertEqual(label.text, "Restore Your Downloads", "h2 does not uppercase")
    }

    // `.label` is the one role that uppercases, so it pins that the style is
    // applied whole rather than just the font being swapped.
    func testApplyBrandStyleUppercasesTheLabelRole() {
        BrandFont.registerIfAvailable()
        let label = UILabel()
        label.text = "Restore Your Downloads"

        label.applyBrandStyle(.label)

        XCTAssertEqual(label.text, "RESTORE YOUR DOWNLOADS")
    }

    func testTypographyRolesResolveWithBundledFonts() {
        BrandFont.registerIfAvailable()

        let roles: [BrandTypography.Role] = [
            .display, .h1, .h2, .h3, .h4, .body, .small, .label, .numeric, .code
        ]
        for role in roles {
            XCTAssertNotNil(BrandTypography.styleIfAvailable(role), "\(role) must resolve with bundled fonts")
        }
    }

    // The two mono roles must use the mono face and everything else the sans
    // face — the split #42 and #43 established.
    func testMonoRolesUseTheMonoFaceAndTheRestUseSans() {
        BrandFont.registerIfAvailable()

        for role in [BrandTypography.Role.numeric, .code] {
            XCTAssertEqual(BrandTypography.styleIfAvailable(role)?.font.familyName, Self.monoFamily,
                           "\(role) must use the mono face")
        }

        for role in [BrandTypography.Role.display, .h1, .h2, .h3, .h4, .body, .small, .label] {
            XCTAssertEqual(BrandTypography.styleIfAvailable(role)?.font.familyName, Self.sansFamily,
                           "\(role) must use the sans face")
        }
    }
}
