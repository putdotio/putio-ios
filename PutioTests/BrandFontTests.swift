import XCTest
@testable import Putio

// Pins the contract that verification builds bundle the licensed faces
// (PUTIO_BUNDLE_BRAND_FONTS in Config/Verify.xcconfig). Without it a build that
// loses the fonts shows up as a spread of unexplained pixel diffs rather than a
// named failure — and the visual suite stops seeing typography regressions at
// all. Run `mise run fonts-setup` before recording.
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
            Run `mise run fonts-setup`, and check PUTIO_BUNDLE_BRAND_FONTS in Config/Verify.xcconfig.
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

    // Checks the fallback wiring without needing the faces to be absent: when a
    // face resolves, the two accessors must agree. The absent branch is only
    // reachable in builds without the licensed fonts.
    func testNonOptionalAccessorsDeferToTheOptionalOnesWhenFacesResolve() {
        BrandFont.registerIfAvailable()

        XCTAssertEqual(BrandFont.sans(size: 17, weight: .bold), BrandFont.sansIfAvailable(size: 17, weight: .bold))
        XCTAssertEqual(BrandFont.mono(size: 13), BrandFont.monoIfAvailable(size: 13))
    }

    // Pure descriptor math, so this holds whether or not the fonts are bundled.
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

    func testApplyBrandStyleAppliesTheBrandFace() {
        BrandFont.registerIfAvailable()
        let label = UILabel()
        label.text = "Restore Your Downloads"
        label.font = UIFont.preferredFont(forTextStyle: .title1)

        label.applyBrandStyle(.h2)

        XCTAssertEqual(label.font.familyName, Self.sansFamily, "h2 must resolve to the brand sans face")
        XCTAssertEqual(label.text, "Restore Your Downloads", "h2 does not uppercase")
    }

    // `.label` is the only uppercasing role, so it proves the whole style is
    // applied rather than just the font being swapped.
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

    // Berkeley Mono is the only mono face; every other role is sans.
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
