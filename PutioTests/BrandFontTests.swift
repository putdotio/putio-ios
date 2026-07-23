import XCTest
@testable import Putio

// Verification builds never bundle the licensed fonts
// (PUTIO_BUNDLE_BRAND_FONTS = NO in Config/Verify.xcconfig), so every snapshot
// baseline is recorded and compared on system fonts. These tests pin that
// contract: a font leak into the Verify configuration becomes a named failure
// here instead of a mysterious pixel diff — and if you run them from Xcode
// with fonts synced (a configuration without the exclusion), the first test
// failing is the signal that snapshot work needs `make screenshots-record`.
final class BrandFontTests: XCTestCase {
    func testVerifyBuildsBundleNoBrandFonts() {
        let bundled = (Bundle.main.urls(forResourcesWithExtension: "otf", subdirectory: nil) ?? [])
            .filter { $0.lastPathComponent.hasPrefix("gt-america-") }

        XCTAssertEqual(
            bundled, [],
            "brand fonts must never be bundled into verification builds; baselines depend on system fonts"
        )
    }

    func testOptionalAccessorsResolveToNilWithoutBundledFonts() {
        BrandFont.registerIfAvailable()

        XCTAssertNil(BrandFont.sansIfAvailable(size: 17, weight: .bold))
        XCTAssertNil(BrandFont.monoIfAvailable(size: 13))
    }

    func testNonOptionalAccessorsFallBackToSystemFonts() {
        XCTAssertEqual(BrandFont.sans(size: 17, weight: .bold), .systemFont(ofSize: 17, weight: .bold))
        XCTAssertEqual(BrandFont.mono(size: 13), .monospacedSystemFont(ofSize: 13, weight: .regular))
    }

    // Pins the fixed-size-label weight fix: the descriptor's weight trait is
    // an NSNumber, so a direct `as? CGFloat` cast fails and silently drops the
    // label to regular. This runs without bundled fonts (pure descriptor math).
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
    // must also degrade to nothing without the faces: text unchanged (not
    // uppercased) and the caller's system font intact, so baselines never move.
    func testApplyBrandStyleIsNoOpWithoutBundledFonts() {
        BrandFont.registerIfAvailable()
        let label = UILabel()
        label.text = "Restore Your Downloads"
        let systemFont = UIFont.preferredFont(forTextStyle: .title1)
        label.font = systemFont

        label.applyBrandStyle(.h2)

        XCTAssertEqual(label.text, "Restore Your Downloads", "text must be untouched without bundled fonts")
        XCTAssertEqual(label.font, systemFont, "font must stay the caller's system font without bundled fonts")
    }

    func testTypographyRolesResolveToNilWithoutBundledFonts() {
        BrandFont.registerIfAvailable()
        // Verify builds bundle no faces, so every design-system role must
        // resolve to nil and let callers fall back to their original font —
        // which is exactly what keeps snapshot baselines on system fonts.
        let roles: [BrandTypography.Role] = [.display, .h1, .h2, .h3, .h4, .body, .small, .label, .numeric, .code]
        for role in roles {
            XCTAssertNil(BrandTypography.styleIfAvailable(role), "\(role) must be nil without bundled fonts")
        }
    }
}
