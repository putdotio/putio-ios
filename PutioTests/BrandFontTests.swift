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
